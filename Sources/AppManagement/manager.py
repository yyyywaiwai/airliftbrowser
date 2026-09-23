#!/usr/bin/env python3
"""JSON-lines command interface for the macOS app manager."""
import argparse
import asyncio
import fcntl
import json
import os
from pathlib import Path
import plistlib
import posixpath
import shutil
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True

from common import HOME, MANAGED_NAMES, Reporter, atomic_json, child, download_destination, read_json, relative, sha256
import catalog
import storage


def ensure_python():
    try:
        import pymobiledevice3  # noqa: F401
    except ImportError:
        for candidate in ("/opt/homebrew/bin/python3", "/usr/local/bin/python3"):
            if candidate != sys.executable and os.access(candidate, os.X_OK):
                os.execv(candidate, [candidate, "-B", *sys.argv])
        raise RuntimeError("pymobiledevice3を利用できるPython 3が必要です。")


def local_region(request):
    path = Path(request["backupPath"])
    manifest = storage.load(path)
    item = next((r for r in manifest["regions"] if r["id"] == request["regionID"]), None)
    if not item:
        raise ValueError("バックアップに指定の領域がありません。")
    return path, manifest, item, child(path, item["folder"])


def listing_local(root, rel):
    path = child(root, rel)
    entries = []
    for item in sorted(path.iterdir(), key=lambda p: p.name):
        stat = item.lstat()
        kind = "link" if item.is_symlink() else "directory" if item.is_dir() else "file"
        entries.append({"id": posixpath.join(rel, item.name), "name": item.name, "kind": kind,
                        "size": stat.st_size, "modified": stat.st_mtime,
                        "target": os.readlink(item) if kind == "link" else None})
    return {"entries": entries}


async def listing_remote(lease, rel):
    afc = lease.afc
    root = await lease.path(rel)
    entries = []
    for name in await afc.listdir(root):
        relative(name)
        if "/" in name:
            raise ValueError("ファイル名が不正です。")
        info = await afc.stat(posixpath.join(root, name))
        kind = {"S_IFDIR": "directory", "S_IFREG": "file", "S_IFLNK": "link"}.get(info["st_ifmt"], "other")
        entries.append({"id": posixpath.join(rel, name), "name": name, "kind": kind,
                        "size": info["st_size"], "modified": info["st_mtime"].timestamp(),
                        "target": info.get("LinkTarget")})
    return {"entries": entries}


def local_mutation(request, reporter):
    original, manifest, item, root = local_region(request)
    rel = relative(request.get("relative", ""))
    operation = request["operation"]
    if not rel or rel.split("/")[0] in MANAGED_NAMES:
        raise ValueError("コンテナルート・識別情報は変更できません。")
    existing = child(root, rel, allow_leaf_link=True)
    if request.get("expectedHash") and (existing.is_symlink() or sha256(existing, reporter) != request["expectedHash"]):
        raise ValueError("編集開始後にファイルが変わりました。再度開いてください。")
    path, result = storage.clone(original, reporter)
    try:
        edited = next(r for r in result["regions"] if r["id"] == item["id"])
        base = child(path, edited["folder"])
        destination = child(base, rel, allow_leaf_link=True)
        if operation == "delete":
            if destination.is_symlink() or destination.is_file():
                destination.unlink()
            else:
                shutil.rmtree(destination)
        elif operation == "rename":
            target = child(base, relative(request["destination"]), allow_leaf_link=True)
            if target.exists() or target.is_symlink():
                raise ValueError("同名の項目があります。")
            destination.rename(target)
        elif operation == "mkdir":
            destination.mkdir()
        elif operation == "upload":
            if destination.exists() or destination.is_symlink():
                if not request.get("overwrite"):
                    raise ValueError("同名の項目があります。上書きを選択してください。")
                if destination.is_dir() and not destination.is_symlink():
                    shutil.rmtree(destination)
                else:
                    destination.unlink()
            storage.copy_tree(request["local"], destination, reporter)
        else:
            raise ValueError("不明な編集操作です。")
        edited["entries"] = storage.inventory(base, reporter)
        response = {"backup": storage.finish(path, result)}
        if operation == "upload" and destination.is_file() and not destination.is_symlink():
            response["hash"] = sha256(destination, reporter)
        return response
    except BaseException:
        shutil.rmtree(path)
        raise


async def remote_mutation(request, lease, reporter):
    import transport
    rel = relative(request.get("relative", ""))
    if not rel or rel.split("/")[0] in MANAGED_NAMES:
        raise ValueError("コンテナルート・識別情報は変更できません。")
    operation = request["operation"]
    remote = await lease.path(rel, True)
    if request.get("expectedHash"):
        if await transport.file_hash(lease.afc, remote, reporter) != request["expectedHash"]:
            raise ValueError("編集開始後に端末のファイルが変わりました。再度開いてください。")
    if operation == "delete":
        if not await lease.afc.exists(remote):
            raise ValueError("対象が見つかりません。")
        await lease.replace(rel)
    elif operation == "upload":
        await lease.upload(request["local"], rel, request.get("overwrite", False))
        local = Path(request["local"])
        if local.is_file() and not local.is_symlink():
            return {"hash": sha256(local, reporter)}
    elif operation == "mkdir":
        with tempfile.TemporaryDirectory(prefix="airlift-empty-") as empty:
            await lease.upload(empty, rel)
    elif operation == "rename":
        target_rel = relative(request["destination"])
        if target_rel.startswith(rel + "/"):
            raise ValueError("フォルダ自身の中には移動できません。")
        target = await lease.path(target_rel, True)
        if await lease.afc.exists(target):
            raise ValueError("同名の項目があります。")
        # Original stays in undo; copy to a prepared path, then remove the source.
        with tempfile.TemporaryDirectory(prefix="airlift-rename-") as temporary:
            local = Path(temporary) / "item"
            await transport.pull(lease.afc, remote, local, reporter)
            await lease.upload(local, target_rel)
            await lease.replace(rel)
    else:
        raise ValueError("不明な編集操作です。")
    return {}


def operation_steps(regions, backup=False):
    steps = [("prepare", "準備・アプリ情報の確認")]
    if not backup:
        steps.append(("validate", "バックアップの内容検証"))
    for index, region in enumerate(regions, 1):
        prefix = f"{index}:"
        for key, title in [("connect", "コンテナ接続"), ("scan", "ファイル一覧・容量の集計"),
                           ("transfer", "分割受信" if backup else "分割送信"),
                           ("verify", "保存内容の検証" if backup else "復元内容の検証"),
                           ("return", "コンテナの復帰"), ("cleanup", "後片付け")]:
            steps.append((prefix + key, region["name"] + " · " + title))
    steps.append(("finish", "バックアップの索引を保存" if backup else "復元結果を保存"))
    return steps


async def backup(request, reporter):
    import transport
    verify = request.get("verify", True)
    app, device_info = await catalog.resolve(request["device"], request["appID"])
    kinds = request.get("regionKinds", ["data", "group", "bundle"])
    if not isinstance(kinds, list) or not kinds or any(kind not in ("data", "group", "bundle") for kind in kinds):
        raise ValueError("バックアップ対象を選択してください。")
    regions = [item for item in app["regions"] if item["kind"] in kinds]
    if not regions:
        raise ValueError("選択した対象には取得可能なコンテナがありません。")
    reporter.plan(operation_steps(regions, backup=True))
    reporter.begin("prepare")
    await transport.quiesce(request["device"], app, reporter)
    reporter.end()
    path, manifest = storage.create(app, device_info)
    manifest["verification"] = "sha256" if verify else "skipped"
    manifest["selectedRegionKinds"] = kinds
    try:
        async with transport.connection(request["device"]) as afc:
            for index, item in enumerate(regions, 1):
                reporter.set_region(item["name"], index, len(regions))
                reporter.progress("バックアップ: " + item["name"], force=True, phase="prepare")
                destination = child(path, storage.region_folder(item))
                destination.parent.mkdir(parents=True, exist_ok=True)
                try:
                    verified_hashes = {}
                    prefix = f"{index}:"
                    reporter.begin(prefix + "connect")
                    async with transport.Lease(request["device"], item["path"], reporter, afc, step_prefix=prefix) as lease:
                        reporter.end()
                        reporter.begin(prefix + "scan")
                        tree = await transport.tree_fingerprint(afc, lease.root, reporter)
                        needed = sum(row[2] for row in tree if row[1] == "S_IFREG")
                        reporter.end()
                        reporter.begin(prefix + "transfer", needed)
                        # The received digest is retained even when verification
                        # is disabled, so future restores can validate the backup.
                        await transport.pull(afc, lease.root, destination, reporter, verified_hashes, verify=False)
                        reporter.end()
                        if verify:
                            reporter.begin(prefix + "verify", needed)
                            entries = storage.inventory(destination, reporter)
                            for entry in entries:
                                if entry["kind"] == "file" and entry["sha256"] != verified_hashes[str(destination / entry["path"])][3]:
                                    raise IOError("保存した内容が受信データと一致しません: " + entry["path"])
                            reporter.end()
                        else:
                            reporter.skip(prefix + "verify")
                            entries = storage.inventory(destination, reporter, verified_hashes)
                    manifest["regions"].append({**item, "folder": storage.region_folder(item), "entries": entries})
                    reporter.progress("領域の保存完了: " + item["name"], force=True, phase="manifest")
                except Exception as error:
                    reporter.fail_remaining(f"{index}:")
                    from common import Cancelled
                    if isinstance(error, Cancelled):
                        raise
                    manifest["issues"].append(item["name"] + ": " + (str(error) or type(error).__name__))
                    reporter.progress("領域の取得失敗: " + manifest["issues"][-1], force=True, phase="warning")
                    if transport.pending(request["device"]):
                        raise
                atomic_json(path / storage.MANIFEST, manifest)
    except BaseException as error:
        manifest["issues"].append(str(error))
        atomic_json(path / storage.MANIFEST, manifest)
        raise
    reporter.begin("finish")
    result = storage.finish(path, manifest)
    reporter.end()
    return {"backup": result}


async def restore(request, reporter):
    import transport
    verify = request.get("verify", True)
    manifest = storage.load(request["backupPath"], verify=False, reporter=reporter)
    if manifest["status"] == "incomplete":
        raise ValueError("未完了のバックアップは復元できません。保存済みのバックアップを選択してください。")
    if request.get("mode", "replace") not in ("replace", "merge"):
        raise ValueError("復元方法が不正です。")
    app, _ = await catalog.resolve(request["device"], request["appID"])
    mappings = request.get("mappings", {})
    if not mappings:
        raise ValueError("復元する領域を選択してください。")
    if len(set(mappings.values())) != len(mappings):
        raise ValueError("同じ復元先に複数の領域は指定できません。")
    plan = []
    for source_id, target_id in mappings.items():
        source = next((r for r in manifest["regions"] if r["id"] == source_id), None)
        target = next((r for r in app["regions"] if r["id"] == target_id), None)
        if not source or not target or source["kind"] != target["kind"] or source["kind"] == "bundle":
            raise ValueError("復元先の領域の組み合わせが不正です。")
        plan.append((source, target))
    reporter.plan(operation_steps([target for _, target in plan]))
    reporter.begin("prepare")
    reporter.end()
    if verify:
        reporter.begin("validate", manifest["totalBytes"])
        storage.load(request["backupPath"], verify=True, reporter=reporter)
        reporter.end()
    else:
        reporter.skip("validate")
    await transport.quiesce(request["device"], app, reporter)
    completed = []
    async with transport.connection(request["device"]) as afc:
        for index, (source, target) in enumerate(plan, 1):
            reporter.set_region(target["name"], index, len(plan))
            needed = sum(entry["size"] for entry in source["entries"] if entry["kind"] == "file")
            free = int((await afc.get_device_info())["FSFreeBytes"])
            if free < needed + 64 * 1024**2:
                raise ValueError("端末の空き容量が不足しています。復元データの一時配置に " + str(needed) + " バイト必要です。")
            reporter.progress("復元: " + target["name"], force=True)
            local = child(request["backupPath"], source["folder"])
            try:
                prefix = f"{index}:"
                reporter.begin(prefix + "connect")
                async with transport.Lease(request["device"], target["path"], reporter, afc, step_prefix=prefix) as lease:
                    reporter.end()
                    reporter.begin(prefix + "scan")
                    transfer_bytes = sum(e["size"] for e in source["entries"] if e["kind"] == "file" and e["path"].split("/")[0] not in MANAGED_NAMES)
                    reporter.end()
                    reporter.begin(prefix + "transfer", transfer_bytes)
                    if request.get("mode", "replace") == "replace":
                        for name in await afc.listdir(lease.root):
                            if name not in MANAGED_NAMES and not (local / name).exists() and not (local / name).is_symlink():
                                await lease.replace(name)
                    await restore_children(lease, local, "", request.get("mode", "replace"), defer_verification=True)
                    reporter.end()
                    # Re-read the result in bounded chunks and compare file sets/content.
                    if verify:
                        reporter.begin(prefix + "verify", transfer_bytes)
                        expected_hashes = {entry["path"]: entry["sha256"] for entry in source["entries"] if entry["kind"] == "file"}
                        await verify_restore(lease, local, "", request.get("mode", "replace"), expected_hashes)
                        reporter.end()
                    else:
                        reporter.skip(prefix + "verify")
                completed.append(target["name"])
                reporter.progress("領域の復元完了: " + target["name"], force=True)
            except Exception as error:
                reporter.fail_remaining(f"{index}:")
                reporter.progress("復元工程を中断: " + target["name"], force=True, cancellable=False)
                raise RuntimeError("復元に失敗: " + target["name"] + "。完了した領域: "
                                   + (", ".join(completed) or "なし") + "。" + str(error)) from error
    reporter.begin("finish")
    reporter.end()
    return {"message": ("復元・内容照合が完了しました: " if verify else "復元が完了しました（内容検証なし）: ") + ", ".join(completed)}


async def restore_children(lease, local, prefix, mode, defer_verification=False):
    for item in local.iterdir():
        if not prefix and item.name in MANAGED_NAMES:
            continue
        rel = posixpath.join(prefix, item.name)
        destination = await lease.path(rel, True)
        exists = await lease.afc.exists(destination)
        if mode == "merge" and item.is_dir() and not item.is_symlink() and exists \
                and (await lease.afc.stat(destination))["st_ifmt"] == "S_IFDIR":
            await restore_children(lease, item, rel, mode, defer_verification)
        else:
            await lease.upload(item, rel, overwrite=True, verify=not defer_verification)


async def verify_restore(lease, local, prefix, mode, expected_hashes=None):
    import transport
    names = set(await lease.afc.listdir(await lease.path(prefix)))
    expected = {p.name for p in local.iterdir()}
    if not prefix:
        names -= MANAGED_NAMES
        expected -= MANAGED_NAMES
    if (mode == "replace" and names != expected) or not expected.issubset(names):
        raise IOError("復元後のファイル一覧が一致しません。")
    for item in local.iterdir():
        if not prefix and item.name in MANAGED_NAMES:
            continue
        rel = posixpath.join(prefix, item.name)
        path = await lease.path(rel, True)
        metadata = await lease.afc.stat(path)
        if item.is_symlink():
            if metadata["st_ifmt"] != "S_IFLNK" or metadata.get("LinkTarget") != os.readlink(item):
                raise IOError("リンクの内容が一致しません。")
        elif item.is_dir():
            await verify_restore(lease, item, rel, mode, expected_hashes)
        elif await transport.file_hash(lease.afc, path, lease.reporter) != (expected_hashes[rel] if expected_hashes is not None else sha256(item, lease.reporter)):
            raise IOError("復元後の内容が一致しません: " + rel)


def editor_read(request):
    path = Path(request["local"])
    size = path.stat().st_size
    mode = request.get("mode", "text")
    offset = max(0, int(request.get("offset", 0)))
    if mode == "hex":
        with path.open("rb") as stream:
            stream.seek(offset)
            data = stream.read(4096)
        text = "\n".join(" ".join(f"{byte:02X}" for byte in data[n:n + 16]) for n in range(0, len(data), 16))
        return {"text": text, "size": size, "offset": offset, "pageBytes": len(data), "encoding": "hex"}
    if size > 16 * 1024 * 1024:
        raise ValueError("16 MiBを超えるファイルは16進数表示で開いてください。")
    data = path.read_bytes()
    if mode == "plist":
        value = plistlib.loads(data)
        return {"text": plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=False).decode("utf-8"),
                "encoding": "bplist" if data.startswith(b"bplist00") else "xmlplist", "size": size}
    encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig" if data.startswith(b"\xef\xbb\xbf") else "utf-8"
    try:
        text = data.decode(encoding)
    except UnicodeDecodeError as error:
        raise ValueError("テキストとして読めません。16進数表示を選択してください。") from error
    return {"text": text, "encoding": encoding, "size": size}


def editor_write(request):
    path = Path(request["local"])
    encoding, text = request["encoding"], request["text"]
    if encoding == "hex":
        data = bytes.fromhex(text)
        expected = int(request["pageBytes"])
        if len(data) != expected or expected > 4096:
            raise ValueError("16進数編集では表示ページのバイト数を変えずに入力してください。")
        offset = int(request.get("offset", 0))
        if offset < 0 or offset + len(data) > path.stat().st_size:
            raise ValueError("編集範囲がファイルの外です。")
        with path.open("r+b") as stream:
            stream.seek(offset)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    else:
        if encoding in ("bplist", "xmlplist"):
            data = plistlib.dumps(plistlib.loads(text.encode("utf-8")),
                                 fmt=plistlib.FMT_BINARY if encoding == "bplist" else plistlib.FMT_XML,
                                 sort_keys=False)
        elif encoding in ("utf-8", "utf-8-sig", "utf-16"):
            data = text.encode(encoding)
        else:
            raise ValueError("未対応の文字コードです。")
        temporary = path.with_name(path.name + ".new")
        temporary.write_bytes(data)
        os.replace(temporary, path)
    return {}


async def dispatch(request, reporter):
    action = request["action"]
    if action == "backups":
        return storage.list_backups()
    if action == "import":
        return {"backup": storage.import_backup(request["source"], reporter)}
    if action == "export":
        return storage.export_backup(request["backupPath"], request["destination"], request.get("xcappdata", False), reporter)
    if action == "editor-read":
        return editor_read(request)
    if action == "editor-write":
        return editor_write(request)
    if request.get("backupPath") and action in ("list", "get", "mutate"):
        path, manifest, item, root = local_region(request)
        if action == "list":
            return listing_local(root, relative(request.get("relative", "")))
        if action == "mutate":
            return local_mutation(request, reporter)
        selected = child(root, relative(request["relative"]), allow_leaf_link=True)
        with download_destination(request["local"]) as temporary:
            storage.copy_tree(selected, temporary, reporter)
        return {"local": request["local"], "hash": sha256(selected, reporter) if selected.is_file() and not selected.is_symlink() else None}
    ensure_python()
    import transport
    if action == "pending":
        return {"pending": transport.pending(request.get("device"))}
    if action == "catalog":
        result = await catalog.catalog(request["device"])
        result["pending"] = transport.pending(request["device"])
        return result
    if action == "recover":
        return await transport.recover(request["device"], reporter)
    if action == "icon":
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.springboard import SpringBoardServicesService
        async with await create_using_usbmux(serial=request["device"]) as lockdown:
            async with SpringBoardServicesService(lockdown) as service:
                data = await service.get_icon_pngdata(request["appID"])
        Path(request["local"]).write_bytes(data)
        return {"local": request["local"]}
    if transport.pending(request["device"]):
        raise ValueError("この端末には未完了の操作があります。先に『未完了操作を復旧』を実行してください。")
    if action == "backup":
        return await backup(request, reporter)
    if action == "restore":
        return await restore(request, reporter)
    app, item = await catalog.resolve(request["device"], request["appID"], request["regionID"])
    await transport.quiesce(request["device"], app, reporter)
    async with transport.connection(request["device"]) as afc:
        async with transport.Lease(request["device"], item["path"], reporter, afc) as lease:
            if action == "list":
                return await listing_remote(lease, relative(request.get("relative", "")))
            if action == "get":
                remote = await lease.path(relative(request["relative"]), True)
                with download_destination(request["local"]) as temporary:
                    await transport.pull(afc, remote, temporary, reporter)
                path = Path(request["local"])
                return {"local": str(path), "hash": sha256(path, reporter) if path.is_file() and not path.is_symlink() else None}
            if action == "mutate":
                return await remote_mutation(request, lease, reporter)
    raise ValueError("不明な操作です。")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True)
    args = parser.parse_args()
    request = read_json(args.request)
    reporter = Reporter(request.get("cancelPath"))
    HOME.mkdir(parents=True, exist_ok=True)
    with (HOME / "manager.lock").open("a") as lock:
        try:
            # SpringBoard icons are read-only and do not use container leases.
            if request["action"] != "icon":
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = asyncio.run(dispatch(request, reporter))
            print(json.dumps({"event": "result", "ok": True, **result}, ensure_ascii=False), flush=True)
            return 0
        except Exception as error:
            print(json.dumps({"event": "result", "ok": False,
                              "error": str(error) or type(error).__name__}, ensure_ascii=False), flush=True)
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
