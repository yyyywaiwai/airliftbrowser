"""Portable full-app snapshots and Xcode app-data packages."""
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import stat
import uuid

from common import BACKUPS, MANIFEST, atomic_json, child, read_json, relative, sha256


def inventory(root, reporter=None, verified_hashes=None):
    root = Path(root)
    entries = []

    def walk(path, prefix=""):
        for item in sorted(path.iterdir(), key=lambda p: p.name):
            if reporter:
                reporter.check()
            rel = relative(prefix + item.name)
            metadata = item.lstat()
            row = {"path": rel, "size": metadata.st_size, "mode": stat.S_IMODE(metadata.st_mode),
                   "modifiedNS": metadata.st_mtime_ns}
            if item.is_symlink():
                row.update(kind="link", target=os.readlink(item), size=0)
            elif item.is_dir():
                row.update(kind="directory", size=0)
            elif item.is_file():
                cached = (verified_hashes or {}).get(str(item))
                identity = (metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns)
                digest = cached[3] if cached and cached[:3] == identity else sha256(item, reporter)
                row.update(kind="file", sha256=digest)
            else:
                raise ValueError("This file type can't be saved: " + rel)
            entries.append(row)
            if row["kind"] == "directory":
                walk(item, rel + "/")
    walk(root)
    return entries


def signature(entries):
    return sorted((row["path"], row["kind"], row.get("sha256"), row.get("target"),
                   row["size"] if row["kind"] == "file" else 0) for row in entries)


def region_folder(item):
    if item["kind"] == "data":
        return "Payload/Data"
    if item["kind"] == "bundle":
        return "Payload/Bundle"
    return "Payload/Groups/" + hashlib.sha256(item["identifier"].encode()).hexdigest()


def create(app, device, origin="device"):
    BACKUPS.mkdir(parents=True, exist_ok=True)
    identifier = str(uuid.uuid4())
    path = BACKUPS / (identifier + ".airliftbackup")
    path.mkdir()
    manifest = {"format": "airlift.app-backup", "version": 1, "id": identifier,
                "created": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "app": app, "device": device, "origin": origin, "status": "incomplete",
                "regions": [], "issues": [], "totalBytes": 0,
                "fileAttributes": ["type", "size", "modifiedTime", "symlinkTarget"],
                "consistency": "per-region; processes quiesced, not an OS snapshot"}
    atomic_json(path / MANIFEST, manifest)
    return path, manifest


def load(path, verify=False, reporter=None):
    path = Path(path)
    if path.is_symlink() or not path.is_dir():
        raise ValueError("Choose a backup package.")
    manifest = read_json(child(path, MANIFEST))
    if manifest.get("format") != "airlift.app-backup" or manifest.get("version") != 1:
        raise ValueError("This backup format isn't supported.")
    identifiers = set()
    folders = set()
    for item in manifest["regions"]:
        if item["id"] in identifiers or item["folder"] in folders:
            raise ValueError("The backup contains duplicate areas.")
        identifiers.add(item["id"])
        folders.add(item["folder"])
        if item["folder"] != region_folder(item):
            raise ValueError("The backup contains an invalid folder path.")
        root = child(path, item["folder"])
        names = set()
        for entry in item["entries"]:
            key = relative(entry["path"])
            if not key or key in names:
                raise ValueError("The backup contains duplicate or invalid paths.")
            names.add(key)
            child(root, key, allow_leaf_link=True)
        if verify and signature(inventory(root, reporter)) != signature(item["entries"]):
            raise ValueError("The backup doesn't match its record: " + item["name"])
    return manifest


def summary(path, manifest):
    return {"id": manifest["id"], "path": str(path), "name": manifest["app"]["name"],
            "bundleID": manifest["app"]["bundleID"], "created": manifest["created"],
            "totalBytes": manifest["totalBytes"], "status": manifest["status"],
            "version": manifest["app"].get("version", ""),
            "deviceName": manifest["device"].get("name", ""),
            "issues": manifest["issues"], "regions": [
                {key: value for key, value in item.items() if key != "entries"} for item in manifest["regions"]]}


def list_backups():
    rows, issues = [], []
    for path in BACKUPS.glob("*.airliftbackup"):
        try:
            rows.append(summary(path, load(path)))
        except (ValueError, KeyError, OSError) as error:
            issues.append(path.name + ": " + str(error))
    return {"backups": sorted(rows, key=lambda row: row["created"], reverse=True), "warnings": issues}


def finish(path, manifest):
    manifest["totalBytes"] = sum(entry["size"] for item in manifest["regions"] for entry in item["entries"]
                                 if entry["kind"] == "file")
    manifest["status"] = "partial" if manifest["issues"] else "complete"
    atomic_json(Path(path) / MANIFEST, manifest)
    return summary(path, manifest)


def clone(source, reporter):
    manifest = load(source, verify=True, reporter=reporter)
    path, result = create(manifest["app"], manifest["device"], "edited")
    try:
        for item in manifest["regions"]:
            reporter.progress("Creating an editable copy: " + item["name"], force=True)
            destination = child(path, item["folder"])
            destination.parent.mkdir(parents=True, exist_ok=True)
            copy_tree(child(source, item["folder"]), destination, reporter)
            result["regions"].append(dict(item))
        result["issues"] = list(manifest["issues"])
        result["parentID"] = manifest["id"]
        finish(path, result)
        return path, result
    except BaseException:
        shutil.rmtree(path)
        raise


def copy_tree(source, destination, reporter):
    """copy2 streams in the kernel; cancellation is checked between bounded chunks."""
    source, destination = Path(source), Path(destination)
    if source.is_symlink():
        destination.symlink_to(os.readlink(source))
    elif source.is_dir():
        destination.mkdir()
        for item in source.iterdir():
            reporter.check()
            copy_tree(item, destination / item.name, reporter)
        shutil.copystat(source, destination)
    else:
        from common import CHUNK
        with source.open("rb") as src, destination.open("xb") as dst:
            while data := src.read(CHUNK):
                reporter.check()
                dst.write(data)
        shutil.copystat(source, destination)


def import_backup(source, reporter):
    source = Path(source)
    if source.suffix.lower() == ".xcappdata":
        data = child(source, "AppData")
        if not data.is_dir():
            raise ValueError("The xcappdata has no AppData folder.")
        info = {}
        info_path = child(source, "AppDataInfo.plist")
        if info_path.exists():
            with info_path.open("rb") as stream:
                info = plistlib.load(stream)
        bundle = info.get("CFBundleIdentifier") or info.get("ApplicationBundleIdentifier") or ""
        app = {"id": bundle or str(uuid.uuid4()), "bundleID": bundle,
               "name": info.get("CFBundleDisplayName") or info.get("CFBundleName") or info.get("ApplicationName") or source.stem,
               "version": info.get("CFBundleShortVersionString") or info.get("CFBundleVersion") or "",
               "category": "user", "identity": "imported", "regions": []}
        path, manifest = create(app, {}, "xcappdata")
        item = {"id": "data:" + bundle, "kind": "data", "identifier": bundle, "name": "Data",
                "folder": "Payload/Data", "entries": []}
        try:
            destination = child(path, item["folder"])
            destination.parent.mkdir(parents=True, exist_ok=True)
            copy_tree(data, destination, reporter)
            item["entries"] = inventory(destination, reporter)
            manifest["regions"] = [item]
            return finish(path, manifest)
        except BaseException:
            shutil.rmtree(path)
            raise
    path, manifest = clone(source, reporter)
    manifest["origin"] = "imported"
    return finish(path, manifest)


def export_backup(source, destination, xcappdata, reporter):
    manifest = load(source, verify=True, reporter=reporter)
    destination = Path(destination)
    if destination.exists():
        raise ValueError("Something already exists at this location. Choose a different name.")
    temporary = destination.with_name("." + destination.name + "." + str(uuid.uuid4()))
    try:
        if xcappdata:
            item = next((r for r in manifest["regions"] if r["kind"] == "data"), None)
            if not item:
                raise ValueError("This backup doesn't include app data.")
            temporary.mkdir()
            copy_tree(child(source, item["folder"]), temporary / "AppData", reporter)
            with (temporary / "AppDataInfo.plist").open("wb") as stream:
                plistlib.dump({"CFBundleIdentifier": manifest["app"]["bundleID"],
                               "CFBundleName": manifest["app"]["name"],
                               "CFBundleShortVersionString": manifest["app"].get("version", ""),
                               "ApplicationBundleIdentifier": manifest["app"]["bundleID"],
                               "ApplicationName": manifest["app"]["name"]}, stream)
        else:
            copy_tree(source, temporary, reporter)
        os.rename(temporary, destination)
    except BaseException:
        if temporary.exists():
            shutil.rmtree(temporary)
        raise
    return {"path": str(destination)}
