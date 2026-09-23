#!/usr/bin/env python3
"""Offline acceptance tests: format interoperability, edits and restore rollback."""
import asyncio
from contextlib import asynccontextmanager
import datetime
import io
import json
from contextlib import redirect_stdout
import os
from pathlib import Path
import plistlib
import posixpath
import shutil
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch, AsyncMock, MagicMock

sys.dont_write_bytecode = True
SANDBOX = tempfile.TemporaryDirectory(prefix="airlift-tests-")
os.environ["AIRLIFT_LIBRARY"] = SANDBOX.name
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Sources/AppManagement"))

import common
import manager
import storage
import transport


class AppIconTests(unittest.TestCase):
    def run_batch(self, root, results):
        service = MagicMock()
        service.__aenter__ = AsyncMock(return_value=service)
        service.__aexit__ = AsyncMock(return_value=False)
        service.get_icon_pngdata = AsyncMock(side_effect=results)
        lockdown = MagicMock()
        lockdown.__aenter__ = AsyncMock(return_value=lockdown)
        lockdown.__aexit__ = AsyncMock(return_value=False)
        create = AsyncMock(return_value=lockdown)
        factory = MagicMock(return_value=service)
        modules = {
            "pymobiledevice3.lockdown": MagicMock(create_using_usbmux=create),
            "pymobiledevice3.services.springboard": MagicMock(SpringBoardServicesService=factory),
        }
        request = {"action": "icons", "device": "test-device", "icons": {
            name: str(Path(root) / (name + ".png")) for name in ("first", "second", "third")
        }}
        output = io.StringIO()
        with patch.dict(sys.modules, modules), patch.object(manager, "ensure_python"), redirect_stdout(output):
            try:
                asyncio.run(manager.dispatch(request, None))
            finally:
                self.events = [json.loads(line) for line in output.getvalue().splitlines()]
                self.service = service
        create.assert_awaited_once_with(serial="test-device")
        factory.assert_called_once_with(lockdown)

    def test_batch_reuses_connection_and_preserves_partial_success(self):
        with tempfile.TemporaryDirectory() as root:
            self.run_batch(root, [b"first-png", ValueError("missing icon"), b"third-png"])
            self.assertEqual(Path(root, "first.png").read_bytes(), b"first-png")
            self.assertFalse(Path(root, "second.png").exists())
            self.assertEqual(Path(root, "third.png").read_bytes(), b"third-png")
        self.assertEqual([event["appID"] for event in self.events], ["first", "second", "third"])
        self.assertEqual(self.events[1]["error"], "missing icon")
        self.assertTrue(all(event["event"] == "progress" for event in self.events))

    def test_timeout_stops_using_connection_and_keeps_delivered_icons(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(asyncio.TimeoutError):
                self.run_batch(root, [b"first-png", asyncio.TimeoutError(), b"third-png"])
            self.assertEqual(Path(root, "first.png").read_bytes(), b"first-png")
            self.assertFalse(Path(root, "third.png").exists())
        self.assertEqual(self.service.get_icon_pngdata.await_count, 2)
        self.assertEqual([event["appID"] for event in self.events], ["first"])


class QuietReporter(common.Reporter):
    def progress(self, *args, **kwargs):
        if kwargs.get("cancellable", True):
            self.check()


class LocalAFC:
    """Filesystem-backed protocol double with real streaming and injected faults."""
    def __init__(self, root):
        self.root = Path(root)
        self.max_read = 0
        self.max_write = 0
        self.bytes_read = 0
        self.fail_rename = None

    def path(self, remote):
        return self.root / remote.lstrip("/")

    async def stat(self, remote):
        path = self.path(remote)
        info = path.lstat()
        return {"st_ifmt": "S_IFLNK" if path.is_symlink() else "S_IFDIR" if path.is_dir() else "S_IFREG",
                "st_size": info.st_size, "st_mtime": datetime.datetime.fromtimestamp(info.st_mtime),
                "LinkTarget": os.readlink(path) if path.is_symlink() else None}

    async def exists(self, remote):
        path = self.path(remote)
        return path.exists() or path.is_symlink()

    async def listdir(self, remote):
        return [p.name for p in self.path(remote).iterdir()]

    async def makedirs(self, remote):
        self.path(remote).mkdir(parents=True, exist_ok=True)

    async def rename(self, source, target):
        if self.fail_rename and self.fail_rename(source, target):
            raise IOError("injected disconnect after original was staged")
        self.path(source).rename(self.path(target))

    async def rm_single(self, remote):
        path = self.path(remote)
        if path.is_symlink() or not path.is_dir():
            path.unlink()
        else:
            path.rmdir()

    async def link(self, target, source):
        self.path(source).symlink_to(target)

    async def fopen(self, remote, mode="r"):
        return self.path(remote).open(mode + "b")

    async def fread(self, handle, size):
        self.max_read = max(size, self.max_read)
        data = handle.read(size)
        self.bytes_read += len(data)
        return data

    async def fwrite(self, handle, data, chunk_size=None):
        self.max_write = max(len(data), self.max_write)
        handle.write(data)

    async def fclose(self, handle):
        handle.close()


class AFCOpenError(OSError):
    def __init__(self, status):
        super().__init__(status, f"Opcode: FILE_OPEN failed with status: {status}")
        self.status = status


class Acceptance(unittest.TestCase):
    def test_selected_export_moves_only_requested_item_and_recovers_lost_reply(self):
        async def run(copied, directory, lose_reply):
            with tempfile.TemporaryDirectory() as device:
                afc = LocalAFC(device)
                container = Path(device) / "target"
                (container / "nested").mkdir(parents=True)
                selected = container / "nested/selected"
                if directory:
                    selected.mkdir()
                    (selected / "child").write_bytes(b"selected payload")
                else:
                    selected.write_bytes(b"selected payload")
                sibling = container / "unrelated"
                sibling.write_bytes(b"must not move or read")
                moves = []

                async def relocate(device_id, identifier, destination):
                    if "/p0/p1/p2/" in identifier:
                        member = "p0/p1/p2/" + identifier.rsplit("/", 1)[1]
                        with zipfile.ZipFile(lease.work / "payload.zip") as archive:
                            parent = archive.read(member).decode().removeprefix("../../../")
                        afc.path(destination).symlink_to(Path(device) / parent, target_is_directory=True)
                        return
                    if identifier.startswith("../../airlift-recovered-"):
                        source = afc.path(identifier.removeprefix("../../"))
                    else:
                        source = afc.path(posixpath.normpath(posixpath.join(transport.airlift.AIRLOCK_ROOT, identifier)))
                    moves.append((source, afc.path(destination)))
                    self.assertNotEqual(source, container)
                    self.assertTrue(sibling.is_file())
                    if copied and source == selected:
                        if directory:
                            shutil.copytree(source, afc.path(destination))
                        else:
                            shutil.copy2(source, afc.path(destination))
                    else:
                        source.rename(afc.path(destination))
                    if lose_reply and len(moves) == 1:
                        raise OSError("lost move reply")

                async def cleanup(command):
                    # The real bridge checks Books restoration and absence too.
                    for path in command[3:6]:
                        if await afc.exists(path):
                            await transport.remove_tree(afc, path)
                    return {"ok": True}

                saved_stat = selected.stat()
                copy_file = {"id": "nested/selected", "kind": "directory" if directory else "file",
                             "size": saved_stat.st_size, "modified": datetime.datetime.fromtimestamp(saved_stat.st_mtime).timestamp()}
                identity = json.dumps(transport.root_fingerprint(await afc.stat("/target")), sort_keys=True)
                lease = transport.Lease("test", "/target", self.reporter, afc, selection="nested/selected",
                                        copy_file=copy_file if copied else None, source_identity=identity if copied else None)
                real_stat = afc.stat
                async def guarded_stat(path):
                    if copied and path.startswith("/airlift-link-") and "/target/" in path:
                        raise AFCOpenError(10)
                    return await real_stat(path)
                try:
                    with patch.object(transport, "native", AsyncMock()), patch.object(transport, "relocate", relocate), \
                            patch.object(transport, "run_json", cleanup), patch.object(afc, "stat", guarded_stat):
                        if lose_reply:
                            with self.assertRaisesRegex(OSError, "lost move reply"):
                                await lease.__aenter__()
                        else:
                            async with lease:
                                self.assertEqual(lease.state["copiedSource"], copied)
                                await transport.pull(afc, lease.root, self.root / "selected-download", self.reporter)
                                self.assertTrue(sibling.is_file())
                    self.assertEqual(selected.stat().st_size, saved_stat.st_size)
                    self.assertEqual(selected.stat().st_mtime_ns, saved_stat.st_mtime_ns)
                    payload = selected / "child" if directory else selected
                    self.assertEqual(payload.read_bytes(), b"selected payload")
                    self.assertEqual(sibling.read_bytes(), b"must not move or read")
                    self.assertEqual(afc.bytes_read, 0 if lose_reply else len(b"selected payload"))
                    self.assertEqual(moves[0][0], selected)
                    self.assertEqual(len(moves), 1 if copied else 2)
                    self.assertFalse(lease.work.exists())
                    self.assertFalse(await afc.exists(lease.root))
                finally:
                    if lease.work.exists():
                        shutil.rmtree(lease.work)
                    download = self.root / "selected-download"
                    if download.is_dir():
                        shutil.rmtree(download)
                    elif download.exists():
                        download.unlink()
        for copied in (False, True):
            for directory in (False, True):
                for lose_reply in (False, True):
                    with self.subTest(copied=copied, directory=directory, lose_reply=lose_reply):
                        asyncio.run(run(copied, directory, lose_reply))

    def test_bundle_export_rejects_stale_snapshot_before_copy(self):
        async def run():
            afc = LocalAFC(self.root)
            (self.root / "target").mkdir()
            metadata = {"id": "file", "kind": "file", "size": 1, "modified": 1}
            lease = transport.Lease("test", "/target", self.reporter, afc, selection="file",
                                    copy_file=metadata, source_identity="stale installation")
            async def link(device, identifier, destination):
                afc.path(destination).symlink_to(self.root, target_is_directory=True)
            try:
                with patch.object(transport, "native", AsyncMock()), patch.object(transport, "relocate", AsyncMock(side_effect=link)) as relocate:
                    with self.assertRaisesRegex(ValueError, "一覧の取得後"):
                        await lease.open()
                    self.assertEqual(relocate.await_count, 1)
                    self.assertNotIn("copiedSource", lease.state)
            finally:
                shutil.rmtree(lease.work)
        asyncio.run(run())

    def test_selected_export_rejects_symlink_traversal_before_relocation(self):
        async def run():
            afc = LocalAFC(self.root)
            (self.root / "target").mkdir()
            (self.root / "outside").mkdir()
            (self.root / "outside/file").write_bytes(b"outside")
            (self.root / "target/link").symlink_to(self.root / "outside", target_is_directory=True)
            lease = transport.Lease("test", "/target", self.reporter, afc, selection="link/file")
            async def link(device, identifier, destination):
                member = "p0/p1/p2/" + identifier.rsplit("/", 1)[1]
                with zipfile.ZipFile(lease.work / "payload.zip") as archive:
                    parent = archive.read(member).decode().removeprefix("../../../")
                afc.path(destination).symlink_to(self.root / parent, target_is_directory=True)
            try:
                with patch.object(transport, "native", AsyncMock()), patch.object(transport, "relocate", AsyncMock(side_effect=link)) as relocate:
                    with self.assertRaisesRegex(ValueError, "リンク先"):
                        await lease.open()
                    self.assertEqual(relocate.await_count, 1)
                    self.assertEqual(lease.state["phase"], "linking")
            finally:
                shutil.rmtree(lease.work)
        asyncio.run(run())

    def test_listing_tree_reads_metadata_only_and_does_not_follow_links(self):
        async def run():
            root = self.root / "container"
            (root / "Library/空フォルダ").mkdir(parents=True)
            large = root / "Library/large.bin"
            with large.open("wb") as stream:
                stream.truncate(5 * 1024**3 + 1)
            outside = self.root / "outside"
            outside.mkdir()
            (outside / "hidden").write_text("not in container")
            (root / "alias").symlink_to(outside, target_is_directory=True)
            afc = LocalAFC(self.root)
            lease = transport.Lease("device", "/container", self.reporter, afc)
            lease.root = "/container"
            try:
                with patch.object(afc, "fopen", AsyncMock(side_effect=AssertionError("payload opened"))):
                    result = await manager.listing_tree(lease)
                rows = {row["id"]: row for row in result["tree"]}
                self.assertEqual(set(rows), {"Library", "Library/空フォルダ", "Library/large.bin", "alias"})
                self.assertEqual(rows["Library/large.bin"]["size"], 5 * 1024**3 + 1)
                self.assertEqual(rows["alias"]["kind"], "link")
                self.assertEqual(rows["alias"]["target"], str(outside))
                self.assertEqual(afc.bytes_read, 0)
                # A copied bundle uses the tree from its completed readiness scan.
                lease.copy_tree = await transport.tree_fingerprint(afc, lease.root)
                with patch.object(afc, "listdir", AsyncMock(side_effect=AssertionError("rescanned"))):
                    self.assertEqual(await manager.listing_tree(lease), result)
                lease.copy_tree = []
                self.assertEqual(await manager.listing_tree(lease), {"tree": []})
            finally:
                shutil.rmtree(lease.work)
        asyncio.run(run())

    def test_listing_tree_does_not_return_partial_scan_after_failure(self):
        async def run():
            afc = LocalAFC(self.root)
            (self.root / "folder").mkdir()
            lease = transport.Lease("device", "/", self.reporter, afc)
            lease.root = "/"
            try:
                with patch.object(afc, "stat", AsyncMock(side_effect=OSError("disconnected"))):
                    with self.assertRaisesRegex(OSError, "disconnected"):
                        await manager.listing_tree(lease)
                self.assertIsNone(lease.copy_tree)
            finally:
                shutil.rmtree(lease.work)
        asyncio.run(run())

    def test_pull_skips_open_refusal_without_retry_and_keeps_fatal_errors(self):
        async def run():
            afc = LocalAFC(self.root)
            (self.root / "source").write_bytes(b"payload")
            for status in (1, 10):
                issues = []
                destination = self.root / f"skipped-{status}"
                error = AFCOpenError(status)
                output = io.StringIO()
                with patch.object(afc, "fopen", AsyncMock(side_effect=error)) as fopen, redirect_stdout(output):
                    await transport.pull(afc, "/source", destination, common.Reporter(), issues=issues)
                self.assertEqual(fopen.await_count, 1)
                self.assertEqual(issues, [{"path": "source", "error": str(error)}])
                self.assertFalse(destination.exists())
                events = [json.loads(line) for line in output.getvalue().splitlines()]
                self.assertEqual(len(events), 1)
                self.assertIn("スキップ（未取得）: source", events[0]["message"])
                self.assertIn(str(error), events[0]["message"])

            for status, tolerated in ((1, False), (10, False), (11, True), (12, True), (30, True)):
                destination = self.root / f"failure-{status}"
                with patch.object(afc, "fopen", AsyncMock(side_effect=AFCOpenError(status))) as fopen:
                    with self.assertRaisesRegex(OSError, "source"):
                        await transport.pull(afc, "/source", destination, self.reporter,
                                             issues=[] if tolerated else None)
                    self.assertEqual(fopen.await_count, 1)
                    self.assertFalse(destination.exists())

            with patch.object(afc, "fread", AsyncMock(side_effect=OSError("read failed"))):
                with self.assertRaisesRegex(OSError, "read failed"):
                    await transport.pull(afc, "/source", self.root / "read-failure", self.reporter, issues=[])
        asyncio.run(run())

    def test_cleanup_reports_progress_without_following_links_or_honoring_cancel(self):
        async def run():
            afc = LocalAFC(self.root)
            outside = self.root / "original"
            outside.mkdir()
            (outside / "keep.txt").write_text("keep")
            temporary = self.root / "undo"
            (temporary / "nested").mkdir(parents=True)
            (temporary / "nested/deleted.txt").write_text("delete")
            (temporary / "link").symlink_to(outside, target_is_directory=True)
            cancel = self.root / "cancel"
            cancel.touch()
            output = io.StringIO()
            with redirect_stdout(output):
                await transport.remove_tree(afc, "/undo", common.Reporter(cancel))
            self.assertFalse(temporary.exists())
            self.assertEqual((outside / "keep.txt").read_text(), "keep")
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(events[-1]["phase"], "cleanup")
            self.assertIn("4 項目", events[-1]["message"])
        asyncio.run(run())

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=SANDBOX.name)
        self.root = Path(self.temp.name)
        self.reporter = QuietReporter()

    def tearDown(self):
        self.temp.cleanup()

    def package(self):
        package = self.root / "Sample.xcappdata"
        (package / "AppData/Documents/empty").mkdir(parents=True)
        (package / "AppData/Library/Preferences").mkdir(parents=True)
        (package / "AppData/Documents/日本語.txt").write_text("original\n", encoding="utf-8")
        (package / "AppData/Documents/link").symlink_to("日本語.txt")
        preferences = package / "AppData/Library/Preferences/sample.plist"
        preferences.write_bytes(plistlib.dumps({"enabled": True, "count": 42, "bytes": b"\x00\xff"}, fmt=plistlib.FMT_BINARY))
        (package / "AppData/.com.apple.mobile_container_manager.metadata.plist").write_bytes(b"source identity")
        (package / "AppDataInfo.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "test.source", "CFBundleName": "Sample",
                                                                  "CFBundleShortVersionString": "1.2.3"}))
        return package

    def test_xcappdata_round_trip_preserves_payload(self):
        source = self.package()
        backup = storage.import_backup(source, self.reporter)
        self.assertEqual(backup["name"], "Sample")
        self.assertEqual(backup["version"], "1.2.3")
        destination = self.root / "RoundTrip.xcappdata"
        storage.export_backup(backup["path"], destination, True, self.reporter)
        self.assertEqual(storage.signature(storage.inventory(source / "AppData")),
                         storage.signature(storage.inventory(destination / "AppData")))
        self.assertEqual(plistlib.loads((destination / "AppDataInfo.plist").read_bytes())["CFBundleIdentifier"], "test.source")

    def test_upload_creates_independent_history(self):
        backup = storage.import_backup(self.package(), self.reporter)
        old = Path(backup["path"]) / "Payload/Data/Documents/日本語.txt"
        replacement = self.root / "replacement.txt"
        replacement.write_text("edited", encoding="utf-8")
        request = {"backupPath": backup["path"], "regionID": "data:test.source", "relative": "Documents/日本語.txt",
                   "operation": "upload", "local": str(replacement), "overwrite": True}
        result = manager.local_mutation(request, self.reporter)["backup"]
        self.assertEqual(old.read_text(), "original\n")
        self.assertEqual((Path(result["path"]) / "Payload/Data/Documents/日本語.txt").read_text(), "edited")

    def test_manifest_tampering_and_symlink_traversal_are_rejected(self):
        backup = storage.import_backup(self.package(), self.reporter)
        base = Path(backup["path"])
        (base / "Payload/Data/Documents/日本語.txt").write_text("corrupted")
        with self.assertRaisesRegex(ValueError, "一致しません"):
            storage.load(base, verify=True)
        with self.assertRaises(ValueError):
            common.child(base, "../outside")
        with self.assertRaises(ValueError):
            common.child(base, "Payload/Data/Documents/link/child")

    def test_incomplete_download_is_not_published(self):
        destination = self.root / "download.bin"
        with self.assertRaises(IOError):
            with common.download_destination(destination) as temporary:
                temporary.write_bytes(b"incomplete")
                raise IOError("disconnected")
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.glob(".airlift-download-*")), [])
        destination.write_bytes(b"existing")
        with self.assertRaises(ValueError):
            with common.download_destination(destination):
                self.fail("existing file must not be replaced")
        self.assertEqual(destination.read_bytes(), b"existing")

    def test_streaming_exceeds_old_limit_without_large_buffers(self):
        async def run():
            afc = LocalAFC(self.root)
            local = self.root / "large-source"
            with local.open("wb") as stream:
                stream.truncate(int(os.environ.get("AIRLIFT_TEST_BYTES", 129 * 1024**2 + 17)))
                stream.seek(128 * 1024**2)
                stream.write(b"not-truncated")
            await transport.push(afc, local, "/remote", self.reporter)
            result = self.root / "download"
            await transport.pull(afc, "/remote", result, self.reporter)
            self.assertEqual(common.sha256(result), common.sha256(local))
            self.assertLessEqual(afc.max_write, common.CHUNK)
            self.assertLessEqual(afc.max_read, common.CHUNK)
        asyncio.run(run())

    def test_transaction_recovers_after_failure_between_renames(self):
        async def run():
            afc = LocalAFC(self.root)
            lease = transport.Lease("test", "/target", self.reporter, afc)
            await afc.makedirs(lease.root)
            old = afc.path(lease.root + "/document")
            old.write_bytes(b"original")
            new = self.root / "new-content"
            new.write_bytes(b"replacement")
            afc.fail_rename = lambda src, dst: "/new/" in src
            with self.assertRaisesRegex(IOError, "injected"):
                await lease.upload(new, "document", overwrite=True)
            # Simulate process restart: reload journal, do not rely on in-memory undo.
            recovered = transport.Lease("test", "/target", self.reporter, afc, lease.work)
            afc.fail_rename = None
            await recovered.rollback()
            self.assertEqual(old.read_bytes(), b"original")
            await recovered.rollback()
            self.assertEqual(old.read_bytes(), b"original")
            shutil.rmtree(lease.work)
        asyncio.run(run())

    def test_copy_detection_refuses_recreated_original(self):
        async def run():
            afc = LocalAFC(self.root)
            lease = transport.Lease("test", "/target", self.reporter, afc)
            lease.state["leaf"] = "container"
            await afc.makedirs(lease.original_alias)
            info = await afc.stat(lease.original_alias)
            lease.state["originalRoot"] = transport.root_fingerprint(info)
            await lease.identify_copy()
            self.assertTrue(lease.state["copiedSource"])
            # Same path, different root metadata must not be treated as a copy.
            afc.path(lease.original_alias + "/new-item").write_bytes(b"changed")
            with self.assertRaisesRegex(RuntimeError, "取得元の状態"):
                await lease.identify_copy()
            shutil.rmtree(lease.work)
        asyncio.run(run())

    def test_copy_waits_for_completion_before_exposing_listing(self):
        async def run():
            afc = LocalAFC(self.root)
            lease = transport.Lease("test", "/target", self.reporter, afc)
            lease.state["leaf"] = "App.app"
            await afc.makedirs(lease.original_alias)
            await afc.makedirs(lease.root)
            original = afc.path(lease.original_alias)
            copied = afc.path(lease.root)
            (original / "first").write_bytes(b"first")
            (original / "last").write_bytes(b"last")
            (copied / "first").write_bytes(b"first")
            os.utime(original, (1_700_000_000, 1_700_000_000))
            lease.state["originalRoot"] = transport.root_fingerprint(await afc.stat(lease.original_alias))
            await lease.identify_copy()

            async def finish_copy():
                # Partial tree stays stable for several polls. Stability alone
                # must not make it visible before the root timestamp is restored.
                await asyncio.sleep(0.03)
                (copied / "last").write_bytes(b"last")
                shutil.copystat(original, copied)

            copy_task = asyncio.create_task(finish_copy())
            await lease.wait_for_copy(timeout=1, interval=0.001)
            self.assertTrue(copy_task.done())
            self.assertEqual(sorted(await afc.listdir(lease.root)), ["first", "last"])
            await copy_task
            shutil.rmtree(lease.work)
        asyncio.run(run())

    def test_copy_wait_detects_nested_file_still_growing(self):
        async def run():
            afc = LocalAFC(self.root)
            lease = transport.Lease("test", "/target", self.reporter, afc)
            lease.state["leaf"] = "App.app"
            for root in (lease.original_alias, lease.root):
                await afc.makedirs(root + "/Frameworks")
                afc.path(root + "/Frameworks/library").write_bytes(b"partial")
            shutil.copystat(afc.path(lease.original_alias), afc.path(lease.root))
            lease.state["originalRoot"] = transport.root_fingerprint(await afc.stat(lease.original_alias))
            scan = transport.tree_fingerprint
            scans = 0
            async def growing_tree(service, root):
                nonlocal scans
                result = await scan(service, root)
                scans += 1
                if scans == 1:
                    afc.path(root + "/Frameworks/library").write_bytes(b"complete library payload")
                return result
            with patch.object(transport, "tree_fingerprint", growing_tree):
                await lease.wait_for_copy(timeout=1, interval=0.001)
            self.assertEqual(scans, 3)
            shutil.rmtree(lease.work)
        asyncio.run(run())

    def test_recovery_keeps_unfinished_copy_on_timeout(self):
        async def run():
            afc = LocalAFC(self.root)
            lease = transport.Lease("test", "/target", self.reporter, afc)
            lease.state.update(leaf="App.app", phase="returning", copiedSource=True)
            await afc.makedirs(lease.original_alias)
            await afc.makedirs(lease.root)
            os.utime(afc.path(lease.original_alias), (1_700_000_000, 1_700_000_000))
            lease.state["originalRoot"] = transport.root_fingerprint(await afc.stat(lease.original_alias))
            lease.save()
            real_wait = lease.wait_for_copy
            async def short_wait(**kwargs):
                await real_wait(timeout=0, interval=0, **kwargs)
            with patch.object(lease, "wait_for_copy", short_wait):
                with self.assertRaisesRegex(RuntimeError, "時間内に完了"):
                    await lease.close()
            self.assertTrue(afc.path(lease.root).is_dir())
            self.assertTrue(afc.path(lease.original_alias).is_dir())
            self.assertTrue((lease.work / "State.json").is_file())
            shutil.rmtree(lease.work)
        asyncio.run(run())

    def test_copy_cancellation_still_allows_recovery_wait(self):
        async def run():
            afc = LocalAFC(self.root)
            cancel = self.root / "cancel"
            reporter = QuietReporter(cancel)
            lease = transport.Lease("test", "/target", reporter, afc)
            lease.state["leaf"] = "App.app"
            await afc.makedirs(lease.original_alias)
            await afc.makedirs(lease.root)
            shutil.copystat(afc.path(lease.original_alias), afc.path(lease.root))
            lease.state["originalRoot"] = transport.root_fingerprint(await afc.stat(lease.original_alias))
            cancel.touch()
            with self.assertRaises(common.Cancelled):
                await lease.wait_for_copy(timeout=1, interval=0.001)
            # Returning/cleanup must finish even with the cancel file present.
            await lease.wait_for_copy(timeout=1, interval=0.001, cancellable=False)
            shutil.rmtree(lease.work)
        asyncio.run(run())

    def test_merge_and_replace_keep_destination_identity(self):
        async def run(mode):
            afc = LocalAFC(self.root)
            lease = transport.Lease("test", "/target", self.reporter, afc)
            await afc.makedirs(lease.root + "/Documents")
            root = afc.path(lease.root)
            (root / "Documents/keep.txt").write_text("existing")
            (root / ".com.apple.mobile_container_manager.metadata.plist").write_text("destination identity")
            source = self.package() / "AppData"
            await manager.restore_children(lease, source, "", mode)
            await manager.verify_restore(lease, source, "", mode)
            self.assertEqual((root / ".com.apple.mobile_container_manager.metadata.plist").read_text(), "destination identity")
            self.assertEqual((root / "Documents/keep.txt").exists(), mode == "merge")
            self.assertTrue((root / "Documents/empty").is_dir())
            self.assertTrue((root / "Documents/link").is_symlink())
            await lease.rollback()
            self.assertEqual((root / "Documents/keep.txt").read_text(), "existing")
            self.assertFalse((root / "Documents/日本語.txt").exists())
            shutil.rmtree(lease.work)
        asyncio.run(run("merge"))
        shutil.rmtree(self.root / "Sample.xcappdata")
        asyncio.run(run("replace"))

    def test_cancellation_restores_original_after_partial_transaction(self):
        async def run():
            afc = LocalAFC(self.root)
            cancel = self.root / "cancel"
            reporter = QuietReporter(cancel)
            lease = transport.Lease("test", "/target", reporter, afc)
            await afc.makedirs(lease.root)
            old = afc.path(lease.root + "/file")
            old.write_text("before")
            new = self.root / "replacement"
            new.write_text("after")
            await lease.upload(new, "file", overwrite=True)
            cancel.touch()
            with self.assertRaises(common.Cancelled):
                await lease.upload(new, "another")
            await lease.rollback()
            self.assertEqual(old.read_text(), "before")
            self.assertFalse(afc.path(lease.root + "/another").exists())
            shutil.rmtree(lease.work)
        asyncio.run(run())

    def test_deferred_restore_verification_detects_corruption_and_rolls_back(self):
        async def run():
            afc = LocalAFC(self.root)
            lease = transport.Lease("test", "/target", self.reporter, afc)
            await afc.makedirs(lease.root)
            source = self.root / "restore-input"
            source.mkdir()
            (source / "file").write_bytes(b"backup contents")
            old = afc.path(lease.root + "/file")
            old.write_bytes(b"original contents")
            expected = {"file": common.sha256(source / "file")}
            await manager.restore_children(lease, source, "", "replace", defer_verification=True)
            self.assertEqual(afc.bytes_read, 0)
            await manager.verify_restore(lease, source, "", "replace", expected)
            self.assertEqual(afc.bytes_read, len(b"backup contents"))
            old.write_bytes(b"corrupted contents")
            with self.assertRaisesRegex(IOError, "内容が一致"):
                await manager.verify_restore(lease, source, "", "replace", expected)
            await lease.rollback()
            self.assertEqual(old.read_bytes(), b"original contents")
            shutil.rmtree(lease.work)
        asyncio.run(run())

    def test_verified_download_inventory_matches_full_rehash(self):
        async def run():
            afc = LocalAFC(self.root)
            await afc.makedirs("/remote")
            afc.path("/remote/file").write_bytes(b"streamed data")
            destination = self.root / "downloaded"
            hashes = {}
            await transport.pull(afc, "/remote", destination, self.reporter, hashes)
            full = storage.inventory(destination)
            with patch.object(storage, "sha256", side_effect=AssertionError("redundant read")):
                cached = storage.inventory(destination, self.reporter, hashes)
            self.assertEqual(storage.signature(cached), storage.signature(full))
            (destination / "file").write_bytes(b"changed after download")
            changed = storage.inventory(destination, self.reporter, hashes)
            self.assertNotEqual(storage.signature(changed), storage.signature(full))
        asyncio.run(run())

    def test_progress_reports_chunk_counts_and_region(self):
        reporter = common.Reporter()
        reporter.set_region("データ", 1, 3)
        output = io.StringIO()
        with redirect_stdout(output):
            reporter.progress("分割受信", common.CHUNK + 1, common.CHUNK * 3 + 1,
                              force=True, phase="receive", chunk_size=common.CHUNK)
        event = json.loads(output.getvalue())
        self.assertEqual(event["chunkIndex"], 2)
        self.assertEqual(event["chunkCount"], 4)
        self.assertEqual(event["phase"], "receive")
        self.assertEqual(event["regionCount"], 3)

    def test_backup_restore_verification_options_and_step_totals(self):
        async def run():
            afc = LocalAFC(self.root)
            live = self.root / "live"
            live.mkdir()
            (live / "document").write_bytes(b"backup payload")
            app = {"id": "test.source", "bundleID": "test.source", "name": "Test", "version": "1",
                   "regions": [{"id": "data:test.source", "kind": "data", "identifier": "test.source",
                                "name": "データ", "path": "/live"}]}

            @asynccontextmanager
            async def connection(device):
                yield afc

            class LocalLease(transport.Lease):
                async def __aenter__(self):
                    self.root = "/live"
                    return self

                async def __aexit__(self, error_type, error, traceback):
                    if error_type is not None:
                        self.reporter.end("failed")
                        await self.rollback()
                    self.step("return")
                    self.step("cleanup")
                    self.reporter.end()
                    shutil.rmtree(self.work)

            with patch.object(manager.catalog, "resolve", AsyncMock(return_value=(app, {}))), \
                    patch.object(transport, "quiesce", AsyncMock()), \
                    patch.object(transport, "connection", connection), \
                    patch.object(transport, "Lease", LocalLease):
                reporter = QuietReporter()
                with patch.object(transport, "sha256", side_effect=AssertionError("verification should be skipped")), \
                        patch.object(storage, "sha256", side_effect=AssertionError("unexpected reread")):
                    result = await manager.backup({"device": "test", "appID": app["id"], "verify": False}, reporter)
                path = result["backup"]["path"]
                manifest = storage.load(path, verify=True)
                self.assertEqual(manifest["verification"], "skipped")
                self.assertEqual(next(s for s in reporter.steps if s["id"] == "1:verify")["state"], "skipped")
                transfer = next(s for s in reporter.steps if s["id"] == "1:transfer")
                self.assertEqual(transfer["completed"], transfer["total"])
                self.assertTrue(all(s["state"] in ("complete", "skipped") for s in reporter.steps))

                verified_reporter = QuietReporter()
                with patch.object(storage, "sha256", wraps=storage.sha256) as hash_file:
                    checked = await manager.backup({"device": "test", "appID": app["id"]}, verified_reporter)
                self.assertTrue(hash_file.called)
                self.assertEqual(storage.load(checked["backup"]["path"])["verification"], "sha256")
                self.assertTrue(all(s["state"] == "complete" for s in verified_reporter.steps))
                for step in verified_reporter.steps:
                    if step["total"] is not None:
                        self.assertEqual(step["completed"], step["total"])

                # Unselected containers must never be opened, and intentionally
                # excluding them must not mark the snapshot as partial.
                app["regions"].append({"id": "group:test", "kind": "group", "identifier": "group.test",
                                       "name": "App Group", "path": "/unselected"})
                selected_reporter = QuietReporter()
                selected = await manager.backup({"device": "test", "appID": app["id"],
                                                 "regionKinds": ["data"]}, selected_reporter)
                self.assertEqual(selected["backup"]["status"], "complete")
                self.assertEqual([r["kind"] for r in selected["backup"]["regions"]], ["data"])
                self.assertEqual(len(selected_reporter.steps), 8)
                self.assertEqual(storage.load(selected["backup"]["path"], verify=True)["selectedRegionKinds"], ["data"])
                for kinds in ([], ["unknown"], "data", ["bundle"]):
                    with self.assertRaises(ValueError), patch.object(storage, "create", side_effect=AssertionError("must not create backup")):
                        await manager.backup({"device": "test", "appID": app["id"], "regionKinds": kinds}, QuietReporter())
                app["regions"].pop()

                request = {"device": "test", "appID": app["id"], "backupPath": path,
                           "mappings": {"data:test.source": "data:test.source"}, "verify": False}
                (live / "document").write_bytes(b"changed")
                afc.bytes_read = 0
                reporter = QuietReporter()
                with patch.object(afc, "get_device_info", AsyncMock(return_value={"FSFreeBytes": 1024**3}), create=True), \
                        patch.object(transport, "file_hash", side_effect=AssertionError("unexpected verification")), \
                        patch.object(storage, "sha256", side_effect=AssertionError("unexpected preflight verification")):
                    restored = await manager.restore(request, reporter)
                self.assertIn("内容検証なし", restored["message"])
                self.assertEqual(afc.bytes_read, 0)
                self.assertEqual((live / "document").read_bytes(), b"backup payload")
                self.assertEqual([s["id"] for s in reporter.steps if s["state"] == "skipped"], ["validate", "1:verify"])

                request.pop("verify")  # Verification is on by default.
                reporter = QuietReporter()
                with patch.object(afc, "get_device_info", AsyncMock(return_value={"FSFreeBytes": 1024**3}), create=True):
                    await manager.restore(request, reporter)
                self.assertEqual(afc.bytes_read, len(b"backup payload"))
                self.assertTrue(all(s["state"] == "complete" for s in reporter.steps))
                for step in reporter.steps:
                    if step["total"] is not None:
                        self.assertEqual(step["completed"], step["total"])

                # A protected WebKit blob used to abort the entire data region,
                # dropping later Preferences/Documents from the manifest.
                blocked = live / "Library/Caches/WebKit/NetworkCache/Version 17/Blobs/protected"
                blocked.parent.mkdir(parents=True)
                blocked.write_bytes(b"protected cache")
                original_open = afc.fopen

                async def refuse_blob(remote, mode):
                    if remote.endswith("/protected"):
                        raise AFCOpenError(1)
                    return await original_open(remote, mode)

                for verify in (False, True):
                    with patch.object(afc, "fopen", refuse_blob):
                        partial = await manager.backup({"device": "test", "appID": app["id"], "verify": verify}, QuietReporter())
                    saved = storage.load(partial["backup"]["path"], verify=True)
                    self.assertEqual(saved["status"], "partial")
                    self.assertEqual(len(saved["regions"]), 1)
                    region = saved["regions"][0]
                    self.assertEqual(region["issues"][0]["path"], str(blocked.relative_to(live)))
                    self.assertIn(str(blocked.relative_to(live)), saved["issues"][0])
                    self.assertEqual([e["path"] for e in region["entries"] if e["kind"] == "file"], ["document"])
                    self.assertEqual(saved["totalBytes"], len(b"backup payload"))
                    destination = Path(partial["backup"]["path"]) / region["folder"]
                    self.assertFalse((destination / blocked.relative_to(live)).exists())
                    self.assertEqual((destination / "document").read_bytes(), b"backup payload")
                    partial_request = {**request, "backupPath": partial["backup"]["path"]}
                    with self.assertRaisesRegex(ValueError, "マージ復元"):
                        await manager.restore(partial_request, QuietReporter())
                    with patch.object(afc, "get_device_info", AsyncMock(return_value={"FSFreeBytes": 1024**3}), create=True):
                        await manager.restore({**partial_request, "mode": "merge"}, QuietReporter())
                    self.assertEqual(blocked.read_bytes(), b"protected cache")
        asyncio.run(run())


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2)
    finally:
        SANDBOX.cleanup()
