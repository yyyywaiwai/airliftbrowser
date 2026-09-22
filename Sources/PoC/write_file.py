#!/usr/bin/env python3
"""Write one fresh file or folder outside Media with Airlift and verify exact bytes."""
from copy import deepcopy
import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import posixpath
import secrets
import stat
import subprocess
import tempfile
import zipfile
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent
airlift_py = ROOT / "airlift.py"
if not airlift_py.is_file():
    airlift_py = ROOT.parents[1] / "airlift" / "airlift.py"
spec = importlib.util.spec_from_file_location("upstream_airlift", airlift_py)
airlift = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(airlift)

HELPERS = ROOT.parents[1] / "Helpers"
airlift.DEVICE_HELPER = HELPERS / "poc_device_helper"
airlift.AIRTRAFFIC_HOST = HELPERS / "airtraffic_host"
BRIDGE = HELPERS / "browser_bridge"
upstream_available_devices = airlift.available_devices


def available_devices(devices):
    candidates = deepcopy(devices)
    products = {}
    for device in candidates:
        hardware = device.get("hardwareProperties") or device.get("properties", {}).get("hardware", {})
        product, udid = hardware.get("productType"), hardware.get("udid")
        if isinstance(product, str) and product.startswith("iPad"):
            products[udid] = product
            hardware["productType"] = "iPhone" + product[4:]
    matches = upstream_available_devices(candidates)
    for match in matches:
        match["product"] = products.get(match["udid"], match["product"])
    return matches


airlift.available_devices = available_devices

LIMIT = 128 * 1024 * 1024


def safe_component(name):
    return bool(name) and name not in (".", "..") and "/" not in name and "\0" not in name and len(name.encode()) <= 255


def collect_tree(root):
    files, dirs, total = {}, {""}, 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = Path(dirpath).relative_to(root).as_posix()
        if rel_dir == ".":
            rel_dir = ""
        depth = 0 if not rel_dir else rel_dir.count("/") + 1
        if depth > 40:
            raise ValueError("フォルダの階層が深すぎます。")
        if rel_dir:
            if any(not safe_component(part) for part in rel_dir.split("/")):
                raise ValueError("フォルダ名が不正です。")
            dirs.add(rel_dir)
        for name in dirnames:
            path = Path(dirpath) / name
            if path.is_symlink():
                raise ValueError(f"シンボリックリンクは書けません: {name}")
            if not safe_component(name):
                raise ValueError("フォルダ名が不正です。")
        for name in filenames:
            path = Path(dirpath) / name
            if name == ".DS_Store":
                continue
            if path.is_symlink():
                raise ValueError(f"シンボリックリンクは書けません: {name}")
            if not path.is_file():
                raise ValueError(f"通常ファイル以外は書けません: {name}")
            if not safe_component(name):
                raise ValueError("ファイル名が不正です。")
            data = path.read_bytes()
            total += len(data)
            if total > LIMIT:
                raise ValueError("フォルダは合計128 MiB以下にしてください。")
            files[name if not rel_dir else f"{rel_dir}/{name}"] = data
    return files, dirs


def build_tree_archive(target, files, dirs):
    # Same staging zip as airlift.build_archive; payload is the folder tree.
    target_tail = target[1:]
    metadata = plistlib.dumps({"Version": 2}, fmt=plistlib.FMT_BINARY, sort_keys=True)
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED, allowZip64=False) as archive:
        archive.writestr(airlift.zip_info("META-INF/", stat.S_IFDIR | 0o755), b"")
        archive.writestr(airlift.zip_info("META-INF/com.apple.ZipMetadata.plist", stat.S_IFREG | 0o600), metadata)
        for directory in ("p0/", "p0/p1/", "p0/p1/p2/"):
            archive.writestr(airlift.zip_info(directory, stat.S_IFDIR | 0o755), b"")
        archive.writestr(airlift.zip_info("p0/p1/p2/link", stat.S_IFLNK | 0o777), f"../../../{target_tail}".encode())
        cursor = ""
        for component in target_tail.split("/"):
            cursor += component + "/"
            archive.writestr(airlift.zip_info(cursor, stat.S_IFDIR | 0o755), b"")
        archive.writestr(airlift.zip_info("payload/", stat.S_IFDIR | 0o755), b"")
        for rel in sorted(dirs):
            if rel:
                archive.writestr(airlift.zip_info(f"payload/{rel}/", stat.S_IFDIR | 0o755), b"")
        for rel, data in files.items():
            archive.writestr(airlift.zip_info(f"payload/{rel}", stat.S_IFREG | 0o600), data)
    return output.getvalue()


def list_media(udid, path):
    reply = airlift.run_json([os.fspath(BRIDGE), "list", udid, path], timeout=75)
    if reply.get("exitCode") or not reply.get("ok"):
        raise airlift.AirLiftError(reply.get("error") or "回収したフォルダを読めませんでした。")
    return reply.get("entries") or []


def read_media_file(udid, remote, scratch):
    destination = scratch / "blob"
    destination.unlink(missing_ok=True)
    reply = airlift.run_json(
        [os.fspath(BRIDGE), "get", udid, remote, os.fspath(destination)], timeout=120)
    if reply.get("exitCode") or not reply.get("ok"):
        raise airlift.AirLiftError(reply.get("error") or "回収したファイルを読めませんでした。")
    data = destination.read_bytes()
    destination.unlink()
    return data


def pull_tree(udid, media_path, scratch, depth=0):
    if depth > 40:
        raise airlift.AirLiftError("回収したフォルダの階層が深すぎます。")
    files, dirs = {}, {""}
    for entry in list_media(udid, media_path):
        name, kind, child = entry.get("name"), entry.get("kind"), entry.get("id")
        if not isinstance(name, str) or not isinstance(child, str) or not safe_component(name):
            raise airlift.AirLiftError("回収したフォルダに不正な項目があります。")
        if kind == "S_IFDIR":
            sub_files, sub_dirs = pull_tree(udid, child, scratch, depth + 1)
            dirs.add(name)
            for rel, data in sub_files.items():
                files[f"{name}/{rel}"] = data
            for rel in sub_dirs:
                if rel:
                    dirs.add(f"{name}/{rel}")
        elif kind == "S_IFREG":
            files[name] = read_media_file(udid, child, scratch)
        else:
            raise airlift.AirLiftError(f"通常ファイルとフォルダ以外は照合できません: {name}")
    return files, dirs


def recovered_tree_matches(udid, recovered, files, dirs):
    waited = airlift.run_json(
        [os.fspath(BRIDGE), "wait-recovered", udid, recovered, "directory"], timeout=30)
    if waited.get("exitCode") or not waited.get("ok"):
        return False
    with tempfile.TemporaryDirectory(prefix="airlift-folder-read-") as temporary:
        remote_files, remote_dirs = pull_tree(udid, "/" + recovered, Path(temporary))
    return remote_files == files and remote_dirs == dirs


def ensure_name_is_absent(device_id, target, name):
    device_files = ROOT.parent / "DeviceFiles"
    attempts = []
    for python in (Path("/opt/homebrew/bin/python3"), Path("/usr/local/bin/python3")):
        if python.is_file():
            attempts.append([os.fspath(python), os.fspath(device_files / "dvt_files.py"),
                             "--device", device_id, "--path", target])
            break
    attempts.append(["/usr/bin/python3", os.fspath(device_files / "container_files.py"),
                     "--device", device_id, "--path", target])
    for command in attempts:
        try:
            completed = subprocess.run(command, capture_output=True, text=True, timeout=75)
            reply = json.loads(completed.stdout)
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
            continue
        if completed.returncode or not reply.get("ok"):
            continue
        if any(entry.get("name") == name for entry in reply.get("entries", [])):
            raise ValueError("同名の項目があります。上書きせず、入力元の名前を変更してください。")
        return
    raise ValueError("同名項目の有無を取得できないため、元のファイル名では書込めません。")


def write_file(device_id, target, local_path, name):
    if not safe_component(name):
        raise ValueError("名前が不正です。")
    local = Path(local_path)
    if local.is_symlink():
        raise ValueError("シンボリックリンクは書けません。")
    tree = None
    if local.is_dir():
        files, dirs = collect_tree(local)
        archive_bytes = build_tree_archive(target, files, dirs)
        payload = b"dir"
        tree = (files, dirs)
        payload_size = sum(len(data) for data in files.values())
    else:
        payload = local.read_bytes()
        if len(payload) > LIMIT:
            raise ValueError("ファイルは128 MiB以下にしてください。")
        archive_bytes = airlift.build_archive(target, payload)
        payload_size = len(payload)
    device = airlift.resolve_device(device_id)
    udid = device["udid"]
    token = secrets.token_hex(10)
    original = Path(name)
    name = original.name
    ensure_name_is_absent(udid, target, name)
    source = f"{airlift.SOURCE_PREFIX}{token}"
    link = f"{airlift.LINK_PREFIX}{token}"
    recovered = f"{airlift.RECOVERED_PREFIX}{token}"
    link_id = f"../../{source}/p0/p1/p2/link"
    payload_id = f"../../{source}/payload"
    target_path = posixpath.join(target, name)
    target_id = posixpath.relpath(target_path, airlift.AIRLOCK_ROOT)
    restore_id = f"../../{recovered}"
    identifiers = [link_id, payload_id, target_id, restore_id]
    destinations = [link, posixpath.join(link, name), recovered,
                    posixpath.join(link, name)]

    with tempfile.TemporaryDirectory(prefix="airlift-write-") as temporary:
        work = Path(temporary)
        archive = work / "payload.zip"
        books = work / "Books.plist"
        expected = work / "expected.bin"
        snapshot_root = work / "books-snapshot"
        snapshot_root.mkdir()
        archive.write_bytes(archive_bytes)
        books.write_bytes(airlift.build_books(identifiers))
        expected.write_bytes(payload)
        airlift.preflight(udid)
        snapshot = airlift.native("snapshot-books", udid, os.fspath(snapshot_root))
        if not airlift.operation_ok(snapshot):
            raise airlift.AirLiftError("Books state snapshot failed")
        cleanup_authorized = False
        traffic_ok = False
        verified = False
        restored = False
        finish = None
        try:
            stage = airlift.native("stage", udid, source, link, recovered,
                os.fspath(archive), os.fspath(books), os.fspath(snapshot_root))
            cleanup_authorized = bool(stage.get("operation", {}).get("cleanupAuthorized"))
            if not airlift.operation_ok(stage):
                raise airlift.AirLiftError("Airlift staging failed")
            link_move = airlift.run_json([
                os.fspath(airlift.AIRTRAFFIC_HOST), udid, link_id, link],
                timeout=120)
            if link_move.get("exitCode") or not link_move.get("ok"):
                raise airlift.AirLiftError("Airlift link relocation failed")
            command = [os.fspath(airlift.AIRTRAFFIC_HOST), udid,
                       payload_id, destinations[1], target_id, recovered]
            traffic = airlift.run_json(command, timeout=120)
            traffic_ok = traffic.get("exitCode") == 0 and traffic.get("ok")
            if traffic_ok:
                if tree is None:
                    check = airlift.run_json([
                        os.fspath(BRIDGE), "verify-recovered", udid, recovered,
                        os.fspath(expected)], timeout=60)
                    verified = check.get("exitCode") == 0 and check.get("ok")
                else:
                    verified = recovered_tree_matches(udid, recovered, *tree)
            if verified:
                for _ in range(3):
                    restore = airlift.run_json([
                        os.fspath(airlift.AIRTRAFFIC_HOST), udid,
                        restore_id, destinations[3]], timeout=120)
                    if restore.get("exitCode") or not restore.get("ok"):
                        continue
                    exists = airlift.run_json([
                        os.fspath(BRIDGE), "generated-exists", udid, recovered],
                        timeout=60)
                    restored = exists.get("exitCode") == 0 and not exists.get("exists", True)
                    if restored:
                        break
        finally:
            if cleanup_authorized:
                finish = airlift.run_json([
                    os.fspath(BRIDGE), "finish-write", udid, source, link,
                    recovered, os.fspath(expected), target[1:], name,
                    os.fspath(snapshot_root)], timeout=90)
        if not traffic_ok or not verified or not restored or not finish or finish.get("exitCode") or not finish.get("ok"):
            message = (finish or {}).get("error", "AirTraffic write failed")
            raise airlift.AirLiftError(message)
        return {"ok": True, "target": target_path,
                "bytes": payload_size, "exactBytesVerified": True,
                "cleanupComplete": finish.get("cleanupComplete", False)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--local", required=True)
    parser.add_argument("--name", required=True)
    args = parser.parse_args()
    try:
        result = write_file(args.device, airlift.normalize_target(args.target), args.local, args.name)
    except Exception as error:
        result = {"ok": False, "error": str(error)}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


def self_check():
    with tempfile.TemporaryDirectory(prefix="airlift-folder-check-") as temporary:
        root = Path(temporary) / "箱"
        (root / "サブ").mkdir(parents=True)
        (root / "サブ" / "あ.txt").write_bytes("値".encode())
        (root / "empty").mkdir()
        (root / ".DS_Store").write_bytes(b"skip")
        files, dirs = collect_tree(root)
        assert files == {"サブ/あ.txt": "値".encode()} and dirs == {"", "サブ", "empty"}
        blob = build_tree_archive("/var/tmp", files, dirs)
        with zipfile.ZipFile(io.BytesIO(blob)) as archive:
            names = set(archive.namelist())
            assert {"payload/", "payload/empty/", "payload/サブ/", "payload/サブ/あ.txt"} <= names
            assert archive.read("payload/サブ/あ.txt") == "値".encode()
            assert b"../../../var/tmp" == archive.read("p0/p1/p2/link")
        (root / "サブ" / "link").symlink_to("あ.txt")
        try:
            collect_tree(root)
        except ValueError:
            pass
        else:
            raise SystemExit("symlink accepted")
    print("ok")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-check":
        self_check()
    else:
        raise SystemExit(main())
