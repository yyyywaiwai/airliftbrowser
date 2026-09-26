#!/usr/bin/env python3
"""JSON-lines command interface for the macOS app manager."""
import argparse
import asyncio
import fcntl
import json
import os
from pathlib import Path
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
        raise RuntimeError("Python 3 with pymobiledevice3 is required.")


def local_region(request):
    path = Path(request["backupPath"])
    manifest = storage.load(path)
    item = next((r for r in manifest["regions"] if r["id"] == request["regionID"]), None)
    if not item:
        raise ValueError("The backup doesn't contain the selected area.")
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
            raise ValueError("Invalid file name.")
        info = await afc.stat(posixpath.join(root, name))
        kind = {"S_IFDIR": "directory", "S_IFREG": "file", "S_IFLNK": "link"}.get(info["st_ifmt"], "other")
        entries.append({"id": posixpath.join(rel, name), "name": name, "kind": kind,
                        "size": info["st_size"], "modified": info["st_mtime"].timestamp(),
                        "target": info.get("LinkTarget")})
    return {"entries": entries}


async def listing_tree(lease):
    """Metadata only: never open/read file contents or follow symbolic links."""
    from transport import tree_fingerprint
    lease.reporter.check()
    # Bundle copy readiness already traverses the full tree. Reuse that scan.
    tree = lease.copy_tree
    if tree is None:
        tree = await tree_fingerprint(lease.afc, lease.root, lease.reporter)
    entries = []
    for path, kind, size, modified, target in tree:
        lease.reporter.check()
        entries.append({"id": path, "name": posixpath.basename(path),
                        "kind": {"S_IFDIR": "directory", "S_IFREG": "file", "S_IFLNK": "link"}.get(kind, "other"),
                        "size": size, "modified": modified.timestamp(), "target": target})
    result = {"tree": entries}
    if "originalRoot" in lease.state:
        result["sourceIdentity"] = json.dumps(lease.state["originalRoot"], sort_keys=True)
    return result


def local_mutation(request, reporter):
    original, manifest, item, root = local_region(request)
    rel = relative(request.get("relative", ""))
    operation = request["operation"]
    if not rel or rel.split("/")[0] in MANAGED_NAMES:
        raise ValueError("The container's top folder and identity files can't be changed.")
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
                raise ValueError("An item with the same name already exists.")
            destination.rename(target)
        elif operation == "mkdir":
            destination.mkdir()
        elif operation == "upload":
            if destination.exists() or destination.is_symlink():
                if not request.get("overwrite"):
                    raise ValueError("An item with the same name already exists. Choose to replace it.")
                if destination.is_dir() and not destination.is_symlink():
                    shutil.rmtree(destination)
                else:
                    destination.unlink()
            storage.copy_tree(request["local"], destination, reporter)
        else:
            raise ValueError("Unknown edit action.")
        edited["entries"] = storage.inventory(base, reporter)
        return {"backup": storage.finish(path, result)}
    except BaseException:
        shutil.rmtree(path)
        raise


async def remote_mutation(request, lease, reporter):
    import transport
    rel = relative(request.get("relative", ""))
    if not rel or rel.split("/")[0] in MANAGED_NAMES:
        raise ValueError("The container's top folder and identity files can't be changed.")
    operation = request["operation"]
    remote = await lease.path(rel, True)
    if operation == "delete":
        if not await lease.afc.exists(remote):
            raise ValueError("Couldn't find the item.")
        await lease.replace(rel)
    elif operation == "upload":
        await lease.upload(request["local"], rel, request.get("overwrite", False))
    elif operation == "mkdir":
        with tempfile.TemporaryDirectory(prefix="airlift-empty-") as empty:
            await lease.upload(empty, rel)
    elif operation == "rename":
        target_rel = relative(request["destination"])
        if target_rel.startswith(rel + "/"):
            raise ValueError("A folder can't be moved into itself.")
        target = await lease.path(target_rel, True)
        if await lease.afc.exists(target):
            raise ValueError("An item with the same name already exists.")
        # Original stays in undo; copy to a prepared path, then remove the source.
        with tempfile.TemporaryDirectory(prefix="airlift-rename-") as temporary:
            local = Path(temporary) / "item"
            await transport.pull(lease.afc, remote, local, reporter)
            await lease.upload(local, target_rel)
            await lease.replace(rel)
    else:
        raise ValueError("Unknown edit action.")
    return {}


def operation_steps(regions, backup=False):
    steps = [("prepare", "Preparing")]
    if not backup:
        steps.append(("validate", "Verifying backup"))
    for index, region in enumerate(regions, 1):
        prefix = f"{index}:"
        for key, title in [("connect", "Connecting"), ("scan", "Counting files"),
                           ("transfer", "Receiving files" if backup else "Sending files"),
                           ("verify", "Verifying saved data" if backup else "Verifying restored data"),
                           ("return", "Returning container"), ("cleanup", "Cleaning up")]:
            steps.append((prefix + key, region["name"] + " · " + title))
    steps.append(("finish", "Saving backup index" if backup else "Saving results"))
    return steps


async def backup(request, reporter):
    import transport
    verify = request.get("verify", True)
    app, device_info = await catalog.resolve(request["device"], request["appID"])
    kinds = request.get("regionKinds", ["data", "group", "bundle"])
    if not isinstance(kinds, list) or not kinds or any(kind not in ("data", "group", "bundle") for kind in kinds):
        raise ValueError("Choose what to back up.")
    regions = [item for item in app["regions"] if item["kind"] in kinds]
    if not regions:
        raise ValueError("There's nothing to back up in the selected items.")
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
                reporter.progress("Backing up: " + item["name"], force=True, phase="prepare")
                destination = child(path, storage.region_folder(item))
                destination.parent.mkdir(parents=True, exist_ok=True)
                try:
                    verified_hashes = {}
                    file_issues = []
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
                        await transport.pull(afc, lease.root, destination, reporter, verified_hashes, verify=False,
                                             issues=file_issues)
                        reporter.end("failed" if file_issues else "complete")
                        needed = sum(value[0] for value in verified_hashes.values())
                        if verify:
                            reporter.begin(prefix + "verify", needed)
                            entries = storage.inventory(destination, reporter)
                            for entry in entries:
                                if entry["kind"] == "file" and entry["sha256"] != verified_hashes[str(destination / entry["path"])][3]:
                                    raise IOError("Saved data doesn't match what was received: " + entry["path"])
                            reporter.end()
                        else:
                            reporter.skip(prefix + "verify")
                            entries = storage.inventory(destination, reporter, verified_hashes)
                    manifest["regions"].append({**item, "folder": storage.region_folder(item), "entries": entries,
                                                "issues": file_issues})
                    manifest["issues"].extend(f'{item["name"]}: {issue["path"]}: {issue["error"]}' for issue in file_issues)
                    message = "Partly saved (some files skipped): " if file_issues else "Saved: "
                    reporter.progress(message + item["name"], force=True, phase="manifest")
                except Exception as error:
                    reporter.fail_remaining(f"{index}:")
                    from common import Cancelled
                    if isinstance(error, Cancelled):
                        raise
                    manifest["issues"].append(item["name"] + ": " + (str(error) or type(error).__name__))
                    reporter.progress("Couldn't back up: " + manifest["issues"][-1], force=True, phase="warning")
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
        raise ValueError("An incomplete backup can't be restored. Choose a completed backup.")
    if request.get("mode", "replace") not in ("replace", "merge"):
        raise ValueError("Invalid restore method.")
    app, _ = await catalog.resolve(request["device"], request["appID"])
    mappings = request.get("mappings", {})
    if not mappings:
        raise ValueError("Choose what to restore.")
    if len(set(mappings.values())) != len(mappings):
        raise ValueError("Multiple items can't be restored to the same destination.")
    plan = []
    for source_id, target_id in mappings.items():
        source = next((r for r in manifest["regions"] if r["id"] == source_id), None)
        target = next((r for r in app["regions"] if r["id"] == target_id), None)
        if not source or not target or source["kind"] != target["kind"] or source["kind"] == "bundle":
            raise ValueError("These items can't be restored to the selected destination.")
        if source.get("issues") and request.get("mode", "replace") == "replace":
            raise ValueError("This backup is missing some files, so it can't replace existing data. Choose 'Add & Replace', which keeps existing files.")
        plan.append((source, target))
    reporter.plan(operation_steps([target for _, target in plan]))
    reporter.begin("prepare")
    reporter.end()
    mismatched = []
    if verify:
        reporter.begin("validate", manifest["totalBytes"])
        mismatched = storage.mismatches(request["backupPath"], manifest, reporter)
        reporter.end()
        if mismatched and not request.get("acceptMismatch"):
            return {"confirm": "mismatch", "warnings": mismatched}
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
                raise ValueError("Not enough free space on the device. Restoring needs " + str(needed) + " bytes of temporary space.")
            reporter.progress("Restoring: " + target["name"], force=True)
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
                        expected_hashes = None if mismatched else {entry["path"]: entry["sha256"] for entry in source["entries"] if entry["kind"] == "file"}
                        await verify_restore(lease, local, "", request.get("mode", "replace"), expected_hashes)
                        reporter.end()
                    else:
                        reporter.skip(prefix + "verify")
                completed.append(target["name"])
                reporter.progress("Restored: " + target["name"], force=True)
            except Exception as error:
                reporter.fail_remaining(f"{index}:")
                reporter.progress("Restore stopped: " + target["name"], force=True, cancellable=False)
                raise RuntimeError("Restore failed: " + target["name"] + ". Completed: "
                                   + (", ".join(completed) or "none") + ". " + str(error)) from error
    reporter.begin("finish")
    reporter.end()
    result = {"message": ("Restore and verification complete: " if verify else "Restore complete (not verified): ") + ", ".join(completed)}
    if mismatched:
        result["warnings"] = mismatched
    return result


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
        raise IOError("The restored files don't match the backup.")
    for item in local.iterdir():
        if not prefix and item.name in MANAGED_NAMES:
            continue
        rel = posixpath.join(prefix, item.name)
        path = await lease.path(rel, True)
        metadata = await lease.afc.stat(path)
        if item.is_symlink():
            if metadata["st_ifmt"] != "S_IFLNK" or metadata.get("LinkTarget") != os.readlink(item):
                raise IOError("A restored link doesn't match the backup.")
        elif item.is_dir():
            await verify_restore(lease, item, rel, mode, expected_hashes)
        elif await transport.file_hash(lease.afc, path, lease.reporter) != (expected_hashes[rel] if expected_hashes is not None else sha256(item, lease.reporter)):
            raise IOError("Restored content doesn't match the backup: " + rel)


async def dispatch(request, reporter):
    action = request["action"]
    if action == "backups":
        return storage.list_backups()
    if action == "import":
        return {"backup": storage.import_backup(request["source"], reporter)}
    if action == "rename":
        return {"backup": storage.rename(request["backupPath"], request["label"])}
    if action == "export":
        return storage.export_backup(request["backupPath"], request["destination"], request.get("xcappdata", False), reporter)
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
    if action in ("icon", "icons"):
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.springboard import SpringBoardServicesService
        icons = request["icons"] if action == "icons" else {request["appID"]: request["local"]}
        async with await asyncio.wait_for(create_using_usbmux(serial=request["device"]), 15) as lockdown:
            async with SpringBoardServicesService(lockdown) as service:
                for app_id, local in icons.items():
                    try:
                        data = await asyncio.wait_for(service.get_icon_pngdata(app_id), 10)
                        Path(local).write_bytes(data)
                    except (asyncio.TimeoutError, ConnectionError, EOFError):
                        # A timed-out stream cannot safely be reused for the next app.
                        raise
                    except Exception as error:
                        if action == "icon":
                            raise
                        print(json.dumps({"event": "progress", "appID": app_id,
                                          "error": str(error)}, ensure_ascii=False), flush=True)
                    else:
                        if action == "icons":
                            print(json.dumps({"event": "progress", "appID": app_id,
                                              "local": local}), flush=True)
        return {"local": request["local"]} if action == "icon" else {}
    if transport.pending(request["device"]):
        raise ValueError("This device has unfinished tasks. Run 'Recover Unfinished Tasks' first.")
    if action == "backup":
        return await backup(request, reporter)
    if action == "restore":
        return await restore(request, reporter)
    if action not in ("list", "list-tree", "get", "mutate"):
        raise ValueError("Unknown action.")
    app, item = await catalog.resolve(request["device"], request["appID"], request["regionID"])
    await transport.quiesce(request["device"], app, reporter)
    async with transport.connection(request["device"]) as afc:
        if action == "get":
            # Keep the local result private until the selected item is restored
            # and the lease's on-device cleanup has succeeded.
            with download_destination(request["local"]) as temporary:
                rel = relative(request["relative"])
                scoped_copy = item["kind"] == "bundle" and bool(rel)
                if scoped_copy and not request.get("file"):
                    raise ValueError("Item details are missing. Please refresh the list.")
                if scoped_copy and request.get("containerPath") not in (None, item["path"]):
                    raise ValueError("The app's location has changed. Please refresh the list.")
                async with transport.Lease(request["device"], item["path"], reporter, afc,
                                           selection=rel if scoped_copy else "",
                                           copy_file=request["file"] if scoped_copy else None,
                                           source_identity=request.get("sourceIdentity") if scoped_copy else None) as lease:
                    if scoped_copy and request["file"]["kind"] == "link":
                        temporary.symlink_to(request["file"]["target"])
                    else:
                        remote = lease.download_path if scoped_copy else await lease.path(rel, True)
                        await transport.pull(afc, remote, temporary, reporter)
            path = Path(request["local"])
            return {"local": str(path), "hash": sha256(path, reporter) if path.is_file() and not path.is_symlink() else None}
        async with transport.Lease(request["device"], item["path"], reporter, afc) as lease:
            if action == "list-tree":
                return await listing_tree(lease)
            if action == "list":
                return await listing_remote(lease, relative(request.get("relative", "")))
            if action == "mutate":
                return await remote_mutation(request, lease, reporter)
    raise ValueError("Unknown action.")


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
            if request["action"] not in ("icon", "icons"):
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise RuntimeError("Another task is still running. Wait for it to finish, then try again.") from None
            result = asyncio.run(dispatch(request, reporter))
            print(json.dumps({"event": "result", "ok": True, **result}, ensure_ascii=False), flush=True)
            return 0
        except Exception as error:
            print(json.dumps({"event": "result", "ok": False,
                              "error": str(error) or type(error).__name__}, ensure_ascii=False), flush=True)
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
