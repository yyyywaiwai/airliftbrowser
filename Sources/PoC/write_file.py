#!/usr/bin/env python3
"""Write one fresh file outside Media with Airlift and verify exact bytes."""
from copy import deepcopy
import argparse
import importlib.util
import json
import os
from pathlib import Path
import posixpath
import secrets
import subprocess
import tempfile
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("upstream_airlift", ROOT / "airlift.py")
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
    if not name or name in (".", "..") or "/" in name or "\0" in name or len(name.encode()) > 255:
        raise ValueError("ファイル名が不正です。")
    payload = Path(local_path).read_bytes()
    if len(payload) > 128 * 1024 * 1024:
        raise ValueError("ファイルは128 MiB以下にしてください。")
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
        archive.write_bytes(airlift.build_archive(target, payload))
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
                check = airlift.run_json([
                    os.fspath(BRIDGE), "verify-recovered", udid, recovered,
                    os.fspath(expected)], timeout=60)
                verified = check.get("exitCode") == 0 and check.get("ok")
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
                "bytes": len(payload), "exactBytesVerified": True,
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


if __name__ == "__main__":
    raise SystemExit(main())
