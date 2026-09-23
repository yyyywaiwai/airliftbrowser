"""Airlift container leases with persistent recovery and bounded AFC transfers.

Only the tiny link/bootstrap archive uses the original PoC. App payloads are
streamed over one AFC connection, so neither ZIP32 nor its 128 MiB limit applies.
"""
import asyncio
from datetime import datetime
from contextlib import asynccontextmanager
import hashlib
import importlib.util
import os
from pathlib import Path
import posixpath
import secrets
import shutil
from common import CHUNK, JOURNALS, MANAGED_NAMES, atomic_json, read_json, relative, sha256

RESOURCE = Path(__file__).resolve().parent.parent
POC = RESOURCE / "AirliftPoC"
if not POC.is_dir():
    POC = RESOURCE / "PoC"
UPSTREAM = POC / "airlift.py"
if not UPSTREAM.is_file():
    UPSTREAM = RESOURCE.parent / "airlift/airlift.py"
spec = importlib.util.spec_from_file_location("app_airlift", UPSTREAM)
airlift = importlib.util.module_from_spec(spec)
spec.loader.exec_module(airlift)
HELPERS = RESOURCE.parent / "Helpers"
if not HELPERS.is_dir():
    HELPERS = RESOURCE.parent / "dist/Airlift Browser.app/Contents/Helpers"
airlift.DEVICE_HELPER = HELPERS / "poc_device_helper"
airlift.AIRTRAFFIC_HOST = HELPERS / "airtraffic_host"
BRIDGE = HELPERS / "browser_bridge"


async def run_json(command, timeout=120):
    return await asyncio.to_thread(airlift.run_json, list(map(str, command)), timeout)


async def native(command, device, *args):
    result = await run_json([airlift.DEVICE_HELPER, command, device, *args])
    if not airlift.operation_ok(result):
        raise RuntimeError("Airlift " + command + ": " + str(result.get("operation", result)))
    return result


async def relocate(device, identifier, destination):
    result = await run_json([airlift.AIRTRAFFIC_HOST, device, identifier, destination])
    if result.get("exitCode") or not result.get("ok"):
        raise RuntimeError("AirTrafficの移動に失敗: " + str(result.get("error", result)))


@asynccontextmanager
async def connection(device):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    async with await create_using_usbmux(serial=device) as lockdown:
        async with AfcService(lockdown) as afc:
            yield TimedAFC(afc)


class TimedAFC:
    def __init__(self, service):
        self.service = service

    def __getattr__(self, name):
        async def operation(*args, **kwargs):
            try:
                return await asyncio.wait_for(getattr(self.service, name)(*args, **kwargs), 120)
            except asyncio.TimeoutError as error:
                raise RuntimeError(f"端末の応答が120秒間ありません: {name} {args[0] if args else ''}。再接続後に未完了操作を復旧してください。") from error
        return operation


async def quiesce(device, app, reporter):
    """Stop matching app/extension executables, including owners of shared groups."""
    from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
    import catalog
    groups = {r["identifier"] for r in app["regions"] if r["kind"] == "group"}
    owners = [app]
    if groups:
        rows, _ = await catalog.installed(device)
        owners = [row for row in rows if row["id"] == app["id"] or
                  any(r["kind"] == "group" and r["identifier"] in groups for r in row["regions"])]
    roots = {r["path"] for owner in owners for r in owner["regions"] if r["kind"] == "bundle"}
    if not roots:
        return
    reporter.progress("アプリ・関連拡張の状態を確認", force=True)
    async with UserspaceRsdTunnel(serial=device) as rsd:
        async with DvtProvider(rsd) as dvt, DeviceInfo(dvt) as info, ProcessControl(dvt) as control:
            for process in await info.proclist():
                executable = process.get("realAppName", "").removeprefix("/private")
                if any(executable.startswith(root + "/") for root in roots):
                    pid = process.get("pid")
                    if isinstance(pid, int) and pid > 1:
                        reporter.progress("終了: " + process.get("name", str(pid)), force=True)
                        await control.kill(pid)
                        for _ in range(20):
                            if not await info.is_running_pid(pid):
                                break
                            await asyncio.sleep(0.1)
                        else:
                            raise RuntimeError("対象アプリを終了できませんでした。端末で終了してから再試行してください。")


async def remote_child(afc, root, rel, leaf_link=False):
    cursor = root
    parts = relative(rel).split("/") if rel else []
    for index, part in enumerate(parts):
        cursor = posixpath.join(cursor, part)
        if await afc.exists(cursor):
            info = await afc.stat(cursor)
            if info["st_ifmt"] == "S_IFLNK" and not (leaf_link and index == len(parts) - 1):
                raise ValueError("リンク先を経由した操作はできません。")
    return cursor


async def remove_tree(afc, path, reporter=None):
    # AFC rm implementations can follow links: explicitly lstat and unlink instead.
    # Iterative postorder also handles deeply nested deleted directories.
    pending = [(path, False)]
    removed = 0
    deadline = asyncio.get_running_loop().time() + 1800
    while pending:
        if asyncio.get_running_loop().time() >= deadline:
            raise RuntimeError("一時データの削除が30分以内に完了しませんでした。再接続後に未完了操作を復旧してください。")
        current, visited = pending.pop()
        if reporter:
            reporter.progress(f"一時データを削除中: {removed} 項目完了 · {current}",
                              phase="cleanup", cancellable=False)
        if not visited and (await afc.stat(current))["st_ifmt"] == "S_IFDIR":
            pending.append((current, True))
            for name in await afc.listdir(current):
                relative(name)
                if not name or "/" in name:
                    raise ValueError("端末のファイル名が不正です。")
                pending.append((posixpath.join(current, name), False))
        else:
            await afc.rm_single(current)
            removed += 1
    if reporter:
        reporter.progress(f"一時データの削除完了: {removed} 項目 · {path}",
                          force=True, phase="cleanup", cancellable=False)


def root_fingerprint(info):
    result = {"kind": info["st_ifmt"], "size": info["st_size"],
              "modified": info["st_mtime"].isoformat(),
              "created": info["st_birthtime"].isoformat() if info.get("st_birthtime") else None}
    if info["st_ifmt"] == "S_IFLNK":
        result["target"] = info["LinkTarget"]
    return result


async def tree_fingerprint(afc, root, reporter=None):
    """Observe the entire copy, including files still growing in subdirectories."""
    result = []
    async def walk(path, prefix):
        for name in sorted(await afc.listdir(path)):
            if reporter:
                reporter.check()
            if not name or "/" in name:
                raise ValueError("端末のファイル名が不正です。")
            relative(name)
            rel = posixpath.join(prefix, name)
            remote = posixpath.join(path, name)
            info = await afc.stat(remote)
            result.append((rel, info["st_ifmt"], info["st_size"], info["st_mtime"], info.get("LinkTarget")))
            if reporter:
                reporter.progress(f"ファイル一覧・容量の集計: {len(result)} 項目 · {rel}", phase="scan")
            if info["st_ifmt"] == "S_IFDIR":
                await walk(remote, rel)
    await walk(root, "")
    return result


async def file_hash(afc, path, reporter=None):
    metadata = await afc.stat(path)
    if metadata["st_ifmt"] != "S_IFREG":
        raise ValueError("通常ファイルではありません。")
    count, digest = 0, hashlib.sha256()
    handle = await afc.fopen(path, "r")
    try:
        while count < metadata["st_size"]:
            if reporter:
                reporter.check()
            data = await afc.fread(handle, min(CHUNK, metadata["st_size"] - count))
            if not data:
                raise IOError("ファイルの読み出しが途中で終了しました。")
            count += len(data)
            digest.update(data)
            if reporter:
                reporter.advance(len(data))
                reporter.progress("端末の内容照合: " + posixpath.basename(path), count, metadata["st_size"], phase="verify-device", chunk_size=CHUNK)
    finally:
        await afc.fclose(handle)
    after = await afc.stat(path)
    if after["st_size"] != count or after["st_mtime"] != metadata["st_mtime"]:
        raise IOError("読み出し中にファイルが変更されました。")
    return digest.hexdigest()


async def pull(afc, remote, local, reporter, verified_hashes=None, verify=True, *, issues=None, _relative=""):
    # Only backups opt into retaining readable files after an AFC open refusal.
    # Downloads and the pull-before-rename path must remain all-or-nothing.
    reporter.check()
    local = Path(local)
    info = await afc.stat(remote)
    kind = info["st_ifmt"]
    if kind == "S_IFLNK":
        local.symlink_to(info["LinkTarget"])
    elif kind == "S_IFDIR":
        local.mkdir()
        names = sorted(await afc.listdir(remote))
        for name in names:
            if "/" in name or not relative(name):
                raise ValueError("端末のファイル名が不正です。")
            reporter.progress("取得: " + name)
            await pull(afc, posixpath.join(remote, name), local / name, reporter, verified_hashes, verify,
                       issues=issues, _relative=posixpath.join(_relative, name))
        if names != sorted(await afc.listdir(remote)):
            raise IOError("バックアップ中にフォルダの内容が変わりました。再試行してください。")
    elif kind == "S_IFREG":
        try:
            handle = await afc.fopen(remote, "r")
        except OSError as error:
            path = _relative or posixpath.basename(remote)
            # AFC UNKNOWN_ERROR (1) and PERM_DENIED (10) can be returned
            # for individual protected files even when stat succeeds.
            # Never swallow disconnects, timeouts, local disk errors or
            # read failures after a file has been opened.
            if issues is None or getattr(error, "status", None) not in (1, 10):
                raise IOError(f"ファイルを開けません: {path}: {error}") from error
            issues.append({"path": path, "error": str(error)})
            reporter.progress(f"スキップ（未取得）: {path}: {error}", force=True, phase="warning")
            return
        count, digest = 0, hashlib.sha256()
        try:
            with local.open("xb") as stream:
                while count < info["st_size"]:
                    reporter.check()
                    data = await afc.fread(handle, min(CHUNK, info["st_size"] - count))
                    if not data:
                        raise IOError("ファイルの読み出しが途中で終了しました。")
                    stream.write(data)
                    digest.update(data)
                    count += len(data)
                    reporter.advance(len(data))
                    reporter.progress("分割受信: " + local.name, count, info["st_size"], phase="receive", chunk_size=CHUNK)
                stream.flush()
                os.fsync(stream.fileno())
        finally:
            await afc.fclose(handle)
        after = await afc.stat(remote)
        if after["st_size"] != count or after["st_mtime"] != info["st_mtime"]:
            raise IOError("読み出し中にファイルが変更されました。")
        if verify and sha256(local, reporter) != digest.hexdigest():
            raise IOError("Macへの保存結果が一致しません。")
    else:
        raise ValueError("取得できないファイル種類: " + remote + " (" + kind + ")")
    if kind != "S_IFLNK":
        stamp = info["st_mtime"].timestamp()
        os.utime(local, (stamp, stamp))
    if kind == "S_IFREG" and verified_hashes is not None:
        saved = local.stat()
        verified_hashes[str(local)] = (saved.st_size, saved.st_mtime_ns, saved.st_ctime_ns, digest.hexdigest())


async def push(afc, local, remote, reporter, verify=True):
    local = Path(local)
    reporter.check()
    if local.is_symlink():
        await afc.link(os.readlink(local), remote)
        if (await afc.stat(remote)).get("LinkTarget") != os.readlink(local):
            raise IOError("リンクの保存結果が一致しません。")
    elif local.is_dir():
        await afc.makedirs(remote)
        for item in sorted(local.iterdir(), key=lambda p: p.name):
            await push(afc, item, posixpath.join(remote, item.name), reporter, verify=verify)
    elif local.is_file():
        expected = local.stat()
        handle = await afc.fopen(remote, "w")
        digest, count = hashlib.sha256(), 0
        try:
            with local.open("rb") as stream:
                while data := stream.read(CHUNK):
                    reporter.check()
                    await afc.fwrite(handle, data, chunk_size=CHUNK)
                    if verify:
                        digest.update(data)
                    count += len(data)
                    reporter.advance(len(data))
                    reporter.progress("分割送信: " + local.name, count, expected.st_size, phase="send", chunk_size=CHUNK)
        finally:
            await afc.fclose(handle)
        after = local.stat()
        if count != expected.st_size or after.st_mtime_ns != expected.st_mtime_ns:
            raise IOError("転送中に入力ファイルが変更されました。")
        saved = await afc.stat(remote)
        if saved["st_ifmt"] != "S_IFREG" or saved["st_size"] != count:
            raise IOError("書き戻したファイルのサイズが一致しません。")
        if verify:
            reporter.progress("照合: " + local.name, force=True, phase="verify-device")
        if verify and await file_hash(afc, remote, reporter) != digest.hexdigest():
            raise IOError("書き戻したファイルの内容が一致しません。")
    else:
        raise ValueError("送信できないファイル種類です。")


class Lease:
    def __init__(self, device, target, reporter, afc, journal=None, step_prefix=None, *, selection="", copy_file=None, source_identity=None):
        selection = relative(selection)
        if copy_file is not None:
            if not selection or copy_file.get("id") != selection or copy_file.get("kind") not in ("file", "directory", "link"):
                raise ValueError("取得対象の一覧情報が一致しません。一覧を更新してください。")
        self.device, self.target, self.reporter, self.afc = device, target, reporter, afc
        self.copy_tree = None
        self.step_prefix = step_prefix
        if journal:
            self.work = Path(journal)
            self.state = read_json(self.work / "State.json")
        else:
            token = secrets.token_hex(10)
            self.work = JOURNALS / token
            self.work.mkdir(parents=True)
            self.state = {"device": device, "target": target, "phase": "created",
                          "source": airlift.SOURCE_PREFIX + token, "link": airlift.LINK_PREFIX + token,
                          "recovered": airlift.RECOVERED_PREFIX + token, "undo": [], "mutationComplete": False,
                          "selection": selection}
            if selection:
                self.state["selectedTarget"] = posixpath.join(target, selection)
            if copy_file is not None:
                self.state["copyFile"] = copy_file
                self.state["sourceIdentity"] = source_identity
            self.save()
        self.root = "/" + self.state["recovered"]

    @property
    def container_alias(self):
        return "/" + posixpath.join(self.state["link"], self.state["leaf"])

    @property
    def original_alias(self):
        selection = self.state.get("selection", "")
        return posixpath.join(self.container_alias, selection) if selection else self.container_alias

    @property
    def download_path(self):
        return self.original_alias if self.state.get("selectedLink") else self.root

    async def source_matches(self):
        # Signed bundle contents cannot be stat'ed through AFC. Its installed
        # container identity remains visible; compare that throughout the copy.
        if self.state.get("copyFile"):
            return root_fingerprint(await self.afc.stat(self.container_alias)) == self.state["sourceContainerRoot"]
        return root_fingerprint(await self.afc.stat(self.original_alias)) == self.state["originalRoot"]

    def save(self, phase=None):
        if phase:
            self.state["phase"] = phase
        atomic_json(self.work / "State.json", self.state)

    async def __aenter__(self):
        try:
            await self.open()
            return self
        except BaseException:
            # A command may have completed on-device even when its reply was lost.
            if self.step_prefix:
                self.reporter.end("failed")
            await self.close()
            raise

    async def open(self):
        self.reporter.progress("コンテナへ接続", force=True)
        target = self.state.get("selectedTarget", self.target)
        copy_file = self.state.get("copyFile")
        parent, leaf = posixpath.split(self.target)
        self.state["parent"], self.state["leaf"] = parent, leaf
        # The target was resolved from the current installation catalog. Some
        # App Groups deny both DVT and CoreDevice; AFC stat through the staged
        # link below positively checks the actual source without listing it.
        await native("probe", self.device)
        self.reporter.progress("Books同期状態を退避", force=True, phase="prepare")
        snapshot = self.work / "books"
        snapshot.mkdir()
        await native("snapshot-books", self.device, snapshot)
        self.save("snapshotted")
        source, link, recovered = (self.state[k] for k in ("source", "link", "recovered"))
        link_id = f"../../{source}/p0/p1/p2/link"
        selection = self.state.get("selection", "")
        target_id = posixpath.relpath(target, airlift.AIRLOCK_ROOT)
        restore_id = "../../" + recovered
        (self.work / "payload.zip").write_bytes(airlift.build_archive(parent, b"container"))
        (self.work / "Books.plist").write_bytes(airlift.build_books([link_id, target_id, restore_id]))
        self.save("staging")
        self.reporter.progress("コンテナ接続用の小さなアーカイブを配置", force=True, phase="prepare")
        await native("stage", self.device, source, link, recovered,
                     self.work / "payload.zip", self.work / "Books.plist", snapshot)
        self.save("linking")
        await relocate(self.device, link_id, link)
        if copy_file:
            self.state["sourceContainerRoot"] = root_fingerprint(await self.afc.stat(self.container_alias))
            if self.state.get("sourceIdentity"):
                import json
                if json.dumps(self.state["sourceContainerRoot"], sort_keys=True) != self.state["sourceIdentity"]:
                    raise ValueError("アプリ本体が一覧の取得後に変更されました。一覧を更新してください。")
            original_info = {"st_ifmt": {"file": "S_IFREG", "directory": "S_IFDIR", "link": "S_IFLNK"}[copy_file["kind"]],
                             "st_size": copy_file["size"], "st_mtime": datetime.fromtimestamp(copy_file["modified"]),
                             "LinkTarget": copy_file.get("target")}
            # Bundle storage is copied to the data volume, never moved back.
            # Persist this before the request so a lost reply can be recovered.
            self.state["copiedSource"] = True
        else:
            if selection:
                await remote_child(self.afc, self.container_alias, selection, leaf_link=True)
            original_info = await self.afc.stat(self.original_alias)
        allowed = ("S_IFDIR", "S_IFREG", "S_IFLNK") if selection else ("S_IFDIR",)
        if original_info["st_ifmt"] not in allowed:
            raise ValueError("対象のファイル／フォルダが見つかりません。")
        self.state["originalRoot"] = root_fingerprint(original_info)
        if original_info["st_ifmt"] == "S_IFLNK":
            # A link is exported as link metadata, never by moving/following its target.
            self.state["selectedLink"] = True
            self.save("open")
            return
        self.save("moving")
        self.reporter.progress("選択項目を転送用領域へ公開" if selection else "コンテナを転送用領域へ公開", force=True, phase="prepare")
        await relocate(self.device, target_id, recovered)
        if (await self.afc.stat(self.root))["st_ifmt"] != original_info["st_ifmt"]:
            raise ValueError("取得元と転送用領域のファイル種類が一致しません。")
        # On the bundle volume AirTraffic may copy instead of rename. In that
        # case the original is still live: the recovered view is read-only.
        await self.identify_copy()
        if self.state["copiedSource"]:
            await self.wait_for_copy()
        self.save("open")

    async def identify_copy(self):
        if self.state.get("copyFile"):
            if not await self.source_matches():
                raise RuntimeError("取得中にアプリ本体が変更されました。回収データを保持しました。")
            return
        source_present = await self.afc.exists(self.original_alias)
        if source_present:
            current = root_fingerprint(await self.afc.stat(self.original_alias))
            if current != self.state.get("originalRoot"):
                raise RuntimeError("移動中に取得元の状態が変わりました。元データを一時領域に保持しています。")
        self.state["copiedSource"] = source_present
        self.save()

    async def wait_for_copy(self, *, timeout=1800, interval=0.5, cancellable=True):
        # SendAssetCompleted acknowledges the request, not completion of the
        # cross-volume recursive copy. copyfile restores the root mtime only at
        # the end. A mere existing directory (or stable partial listing) is not
        # ready. Also observe the full tree twice before exposing its contents.
        expected = self.state["originalRoot"]
        previous = None
        deadline = asyncio.get_running_loop().time() + timeout
        while True:
            self.reporter.progress("端末内コピーの完了を待っています…", phase="device-copy", cancellable=cancellable)
            if not await self.source_matches():
                raise RuntimeError("取得中に元の領域が変更されました。回収データを保持しました。")
            copied = await self.afc.stat(self.root)
            ready = (copied["st_ifmt"] == expected["kind"] and copied["st_size"] == expected["size"]
                     and copied["st_mtime"].isoformat() == expected["modified"])
            if ready:
                current = await tree_fingerprint(self.afc, self.root) if expected["kind"] == "S_IFDIR" else []
                if current == previous:
                    # Recheck both roots after traversal; scanning can take time.
                    after = await self.afc.stat(self.root)
                    if (after["st_ifmt"] == expected["kind"] and after["st_size"] == expected["size"]
                            and after["st_mtime"].isoformat() == expected["modified"]
                            and await self.source_matches()):
                        self.copy_tree = current
                        return
                previous = current
            else:
                previous = None
            if asyncio.get_running_loop().time() >= deadline:
                raise RuntimeError("端末内コピーが時間内に完了しませんでした。回収データを保持しました。再接続後に未完了操作を復旧してください。")
            await asyncio.sleep(interval)

    async def __aexit__(self, error_type, error, traceback):
        if error_type is not None and self.step_prefix:
            self.reporter.end("failed")
        if error_type is None:
            self.state["mutationComplete"] = True
            self.save("returning")
        await self.close()

    def step(self, suffix):
        if self.step_prefix:
            self.reporter.end()
            self.reporter.begin(self.step_prefix + suffix, cancellable=False)

    async def path(self, rel, leaf_link=False):
        return await remote_child(self.afc, self.root, rel, leaf_link)

    async def replace(self, rel, prepared=None):
        if self.state.get("selection"):
            raise ValueError("選択項目の取り出し中は変更できません。")
        if self.state.get("copiedSource"):
            raise ValueError("この領域は読み取り用コピーとして公開されています。閲覧・保存できます。")
        relative(rel)
        if not rel or rel.split("/")[0] in MANAGED_NAMES:
            raise ValueError("コンテナ識別情報は変更できません。")
        destination = await self.path(rel, True)
        original = await self.afc.exists(destination)
        saved = "/" + self.state["source"] + "/undo/" + secrets.token_hex(10)
        await self.afc.makedirs(posixpath.dirname(saved))
        action = {"relative": rel, "saved": saved, "original": original}
        self.state["undo"].append(action)
        self.save()
        if original:
            await self.afc.rename(destination, saved)
        if prepared:
            await self.afc.rename(prepared, destination)

    async def upload(self, local, rel, overwrite=False, verify=True):
        if self.state.get("selection"):
            raise ValueError("選択項目の取り出し中は変更できません。")
        if self.state.get("copiedSource"):
            raise ValueError("この領域は読み取り専用です。")
        if not rel or rel.split("/")[0] in MANAGED_NAMES:
            raise ValueError("コンテナ識別情報は変更できません。")
        destination = await self.path(rel, True)
        if await self.afc.exists(destination) and not overwrite:
            raise ValueError("同名の項目があります。上書きを選択してください。")
        prepared = "/" + self.state["source"] + "/new/" + secrets.token_hex(10)
        await self.afc.makedirs(posixpath.dirname(prepared))
        await push(self.afc, local, prepared, self.reporter, verify=verify)
        await self.replace(rel, prepared)

    async def rollback(self):
        while self.state["undo"]:
            action = self.state["undo"][-1]
            destination = await self.path(action["relative"], True)
            if await self.afc.exists(action["saved"]):
                if await self.afc.exists(destination):
                    await remove_tree(self.afc, destination)
                await self.afc.rename(action["saved"], destination)
            elif not action["original"] and await self.afc.exists(destination):
                await remove_tree(self.afc, destination)
            self.state["undo"].pop()
            self.save()

    async def cleanup(self):
        self.step("cleanup")
        self.reporter.progress("一時データの削除・Books状態の復旧", force=True, phase="cleanup", cancellable=False)
        self.save("cleanup")
        for suffix in ("undo", "new"):
            path = "/" + self.state["source"] + "/" + suffix
            if await self.afc.exists(path):
                await remove_tree(self.afc, path, self.reporter)
        if self.state.get("copiedSource") and await self.afc.exists(self.root):
            await remove_tree(self.afc, self.root, self.reporter)
        self.reporter.progress("一時リンクの削除・Books状態の復旧（最大120秒）", force=True,
                               phase="cleanup", cancellable=False)
        result = await run_json([BRIDGE, "finish-delete", self.device, self.state["source"],
                                 self.state["link"], self.state["recovered"], self.work / "books", "cleanup"])
        if result.get("exitCode") or not result.get("ok"):
            raise RuntimeError("一時データ・Books状態の復元が未完了です: " +
                               str(result.get("error", result)) + "。復旧記録: " + str(self.work))
        self.save("complete")
        shutil.rmtree(self.work)
        if self.step_prefix:
            self.reporter.end()

    async def close(self):
        # Never honor cancellation during rollback/return/Books restoration.
        self.step("return")
        if self.state["phase"] in ("created", "complete"):
            shutil.rmtree(self.work)
            return
        if self.state["phase"] == "cleanup":
            await self.cleanup()
            return
        present = await self.afc.exists(self.root)
        if present and self.state["phase"] == "moving" and "copiedSource" not in self.state:
            # A lost AirTraffic reply must not make a copied bundle look like a
            # conflicting replacement. Compare the source's pre-move identity.
            await self.identify_copy()
        if self.state.get("copiedSource"):
            if not await self.source_matches():
                raise RuntimeError("取得中に元の領域が変更されました。回収データを保持しました。")
            if present:
                # Also used for old journals and cancellation while copying:
                # never delete the destination while AirTraffic is filling it.
                await self.wait_for_copy(cancellable=False)
            await self.cleanup()
            return
        if present:
            self.reporter.progress("取得元へ戻しています", force=True, phase="return", cancellable=False)
            if not self.state["mutationComplete"]:
                await self.rollback()
            info = await self.afc.stat(self.root)
            self.state["expectedNames"] = sorted(await self.afc.listdir(self.root)) if info["st_ifmt"] == "S_IFDIR" else []
            self.state["expectedRootSize"] = info["st_size"]
            self.state["expectedRootKind"] = info["st_ifmt"]
            self.state["expectedMetadata"] = {}
            for name in self.state["expectedNames"]:
                info = await self.afc.stat(posixpath.join(self.root, name))
                self.state["expectedMetadata"][name] = {"kind": info["st_ifmt"], "size": info["st_size"]}
            self.save("returning")
            if await self.afc.exists(self.original_alias):
                raise RuntimeError("元の場所に別のコンテナが作られています。回収データを保持しました: " + str(self.work))
            await relocate(self.device, "../../" + self.state["recovered"],
                           self.original_alias.lstrip("/"))
        if self.state["phase"] in ("moving", "open", "returning"):
            if not await self.afc.exists(self.original_alias) or await self.afc.exists(self.root):
                raise RuntimeError("コンテナの復帰を確認できません。『未完了操作を復旧』を実行してください。")
            # AFC can stat the original root through the staged link even when
            # sandbox policy denies enumerating it. Content hashes were checked
            # in Media before the rename; independently verify the destination.
            info = await self.afc.stat(self.original_alias)
            if info["st_ifmt"] != self.state.get("expectedRootKind", self.state.get("originalRoot", {}).get("kind", "S_IFDIR")) or ("expectedRootSize" in self.state and
                    info["st_size"] != self.state["expectedRootSize"]):
                raise RuntimeError("復帰先の状態が一致しません。復旧記録を保持しました。")
            if self.state.get("selection") and root_fingerprint(info) != self.state["originalRoot"]:
                raise RuntimeError("取り出した項目の復帰先メタデータが一致しません。復旧記録を保持しました。")
        await self.cleanup()


def pending(device=None):
    rows = []
    for file in JOURNALS.glob("*/State.json"):
        state = read_json(file)
        if device is None or state["device"] == device:
            rows.append({"id": file.parent.name, "device": state["device"],
                         "target": state["target"], "phase": state["phase"]})
    return rows


async def recover(device, reporter):
    async with connection(device) as afc:
        for row in pending(device):
            reporter.progress("未完了操作を復旧: " + row["target"], force=True)
            lease = Lease(device, row["target"], reporter, afc, JOURNALS / row["id"])
            await lease.close()
    return {"pending": pending(device)}
