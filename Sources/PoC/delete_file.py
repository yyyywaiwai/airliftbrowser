#!/usr/bin/env python3
"""Delete one known regular file outside Media through AirTraffic."""
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
import time
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


def target_present(device_id, parent, leaf):
    script = ROOT.parent / "DeviceFiles/dvt_files.py"
    python = next((path for path in (Path("/opt/homebrew/bin/python3"), Path("/usr/local/bin/python3"))
                   if path.is_file()), None)
    if not python:
        return False
    try:
        completed = subprocess.run([
            os.fspath(python), os.fspath(script), "--device", device_id,
            "--path", parent], capture_output=True, text=True, timeout=75)
        reply = json.loads(completed.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return False
    return completed.returncode == 0 and any(
        entry.get("name") == leaf and entry.get("kind") == "S_IFREG"
        for entry in reply.get("entries", []))


def restore_file(udid, restore_id, destination, parent, leaf, recovered):
    process = subprocess.Popen([
        os.fspath(airlift.AIRTRAFFIC_HOST), udid, restore_id, destination],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    restored = False
    for _ in range(12):
        time.sleep(0.5)
        if target_present(udid, parent, leaf):
            restored = True
            break
        if process.poll() is not None:
            break
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    if not restored:
        exists = airlift.run_json([
            os.fspath(BRIDGE), "generated-exists", udid, recovered], timeout=60)
        restored = exists.get("exitCode") == 0 and not exists.get("exists", True)
    if restored:
        exists = airlift.run_json([
            os.fspath(BRIDGE), "generated-exists", udid, recovered], timeout=60)
        if exists.get("exists"):
            removed = airlift.run_json([
                os.fspath(BRIDGE), "remove", udid, "/" + recovered], timeout=60)
            restored = removed.get("exitCode") == 0 and removed.get("ok")
    return restored


def delete_file(device_id, target, local_path=None):
    target = airlift.normalize_target(target)
    parent, leaf = posixpath.split(target)
    if not parent or not leaf or leaf in (".", ".."):
        raise ValueError("削除対象パスが不正です。")
    udid = airlift.resolve_device(device_id)["udid"]
    token = secrets.token_hex(10)
    source = f"{airlift.SOURCE_PREFIX}{token}"
    link = f"{airlift.LINK_PREFIX}{token}"
    recovered = f"{airlift.RECOVERED_PREFIX}{token}"
    link_id = f"../../{source}/p0/p1/p2/link"
    target_id = posixpath.relpath(target, airlift.AIRLOCK_ROOT)
    restore_id = f"../../{recovered}"

    with tempfile.TemporaryDirectory(prefix="airlift-delete-") as temporary:
        work = Path(temporary)
        archive, books = work / "payload.zip", work / "Books.plist"
        snapshot_root = work / "books-snapshot"
        snapshot_root.mkdir()
        archive.write_bytes(airlift.build_archive(parent, b"delete"))
        books.write_bytes(airlift.build_books([link_id, target_id, restore_id]))
        airlift.preflight(udid)
        snapshot = airlift.native("snapshot-books", udid, os.fspath(snapshot_root))
        if not airlift.operation_ok(snapshot):
            raise airlift.AirLiftError("Books state snapshot failed")
        cleanup_authorized = False
        moved = False
        should_restore = local_path is not None
        restored = False
        extracted = None
        type_error = None
        finish = None
        try:
            stage = airlift.native("stage", udid, source, link, recovered,
                os.fspath(archive), os.fspath(books), os.fspath(snapshot_root))
            cleanup_authorized = bool(stage.get("operation", {}).get("cleanupAuthorized"))
            if not airlift.operation_ok(stage):
                raise airlift.AirLiftError("Airlift staging failed")
            link_move = airlift.run_json([
                os.fspath(airlift.AIRTRAFFIC_HOST), udid, link_id, link], timeout=120)
            if link_move.get("exitCode") or not link_move.get("ok"):
                raise airlift.AirLiftError("Airlift link relocation failed")
            traffic = airlift.run_json([
                os.fspath(airlift.AIRTRAFFIC_HOST), udid, target_id, recovered], timeout=120)
            moved = traffic.get("exitCode") == 0 and traffic.get("ok")
            if not moved:
                raise airlift.AirLiftError(traffic.get("error", "AirTraffic delete relocation failed"))
            observed = airlift.run_json([
                os.fspath(BRIDGE), "generated-kind", udid, recovered], timeout=60)
            if observed.get("exitCode") or observed.get("kind") != "S_IFREG":
                should_restore = True
                type_error = "通常ファイルだけ削除できます。対象は元の場所へ復元しました。"
            elif local_path:
                extracted = airlift.run_json([
                    os.fspath(BRIDGE), "get", udid, "/" + recovered, local_path], timeout=120)
        finally:
            if cleanup_authorized:
                if moved and should_restore and not restored:
                    restored = restore_file(udid, restore_id,
                        posixpath.join(link, leaf), parent, leaf, recovered)
                finish = airlift.run_json([
                    os.fspath(BRIDGE), "finish-delete", udid, source, link,
                    recovered, os.fspath(snapshot_root),
                    "cleanup" if should_restore else "delete"], timeout=90)
        if should_restore and not restored:
            raise airlift.AirLiftError(
                f"対象を元へ復元できませんでした。回収データをMedia/{recovered}に保持しています。")
        if type_error:
            if not finish or finish.get("exitCode") or not finish.get("ok"):
                raise airlift.AirLiftError((finish or {}).get("error", type_error))
            raise airlift.AirLiftError(type_error)
        if local_path:
            if not extracted or extracted.get("exitCode") or not extracted.get("ok"):
                raise airlift.AirLiftError((extracted or {}).get("error", "ファイル抽出に失敗しました。"))
            if not finish or finish.get("exitCode") or not finish.get("ok"):
                raise airlift.AirLiftError((finish or {}).get("error", "抽出後の復元に失敗しました。"))
            return {"ok": True, "target": target, "local": local_path,
                    "bytes": extracted.get("bytes"), "exactBytesVerified": True,
                    "restored": True, "cleanupComplete": finish.get("cleanupComplete", False)}
        if not moved or not finish or finish.get("exitCode") or not finish.get("ok"):
            raise airlift.AirLiftError((finish or {}).get("error", "AirTraffic delete failed"))
        return {"ok": True, "target": target, "deleted": True,
                "targetAbsent": finish.get("targetAbsent", False),
                "cleanupComplete": finish.get("cleanupComplete", False)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--local")
    args = parser.parse_args()
    try:
        result = delete_file(args.device, args.target, args.local)
    except Exception as error:
        result = {"ok": False, "error": str(error)}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
