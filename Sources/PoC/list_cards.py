#!/usr/bin/env python3
"""List Apple Pay card faces by temporarily relocating Wallet/Cards."""
from copy import deepcopy
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import posixpath
import secrets
import select
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True

CARDS_PATH = "/var/mobile/Library/Passes/Cards"
ARTWORK = (
    "cardBackgroundCombined@3x.png",
    "cardBackgroundCombined@2x.png",
    "cardBackgroundCombined.png",
    "cardBackgroundCombined.pdf",
    "dynamicLayerStaticFallback@3x.png",
    "dynamicLayerStaticFallback@2x.png",
    "dynamicLayerStaticFallback.png",
    "backgroundParallax@3x.png",
    "backgroundParallax@2x.png",
    "backgroundParallax.png",
    "foregroundParallax@3x.png",
    "foregroundParallax@2x.png",
    "foregroundParallax.png",
    "staticOverlay@3x.png",
    "staticOverlay@2x.png",
    "staticOverlay.png",
    "backgroundParallaxCrossDissolve@3x.png",
    "backgroundParallaxCrossDissolve@2x.png",
    "foregroundParallaxCrossDissolve@3x.png",
    "foregroundParallaxCrossDissolve@2x.png",
)
CACHE_LEAVES = ("FrontFace", "PlaceHolder", "Preview")
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

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


def uid_index(value):
    if not isinstance(value, plistlib.UID):
        raise ValueError("Unexpected FrontFace reference format")
    return value.data


def front_face_png(path: Path) -> bytes:
    data = path.read_bytes()
    if len(data) < 56 or data[48:56] != b"bplist00":
        raise ValueError("Unrecognized FrontFace format")
    archive_data = data[48:]
    if hashlib.sha256(archive_data).digest() != data[16:48]:
        raise ValueError("FrontFace checksum doesn't match")
    archive = plistlib.loads(archive_data)
    objects = archive["$objects"]
    root = objects[uid_index(archive["$top"]["root"])]
    face = objects[uid_index(root["faceImage"])]
    png = objects[uid_index(face["imageData"])]["NS.data"]
    if not isinstance(png, bytes) or not png.startswith(PNG_MAGIC):
        raise ValueError("FrontFace image isn't a PNG")
    return png


def display_text(value, limit: int) -> str:
    if not isinstance(value, str):
        return ""
    text = " ".join(value.split())
    return text[:limit]


def account_suffix(metadata: dict) -> str:
    for key in ("primaryAccountNumberSuffix", "primaryAccountSuffix"):
        value = metadata.get(key)
        if isinstance(value, str) and value.isdigit() and len(value) == 4:
            return value
    return ""


def artwork_png(pass_root: Path, temporary: Path):
    for name in ARTWORK:
        path = pass_root / name
        if not path.is_file():
            continue
        if path.suffix.lower() == ".png":
            data = path.read_bytes()
            if data.startswith(PNG_MAGIC):
                return data
            continue
        converted = temporary / "artwork.png"
        completed = subprocess.run(
            ["/usr/bin/sips", "-s", "format", "png", os.fspath(path), "--out", os.fspath(converted)],
            check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        if completed.returncode == 0 and converted.is_file():
            data = converted.read_bytes()
            converted.unlink(missing_ok=True)
            if data.startswith(PNG_MAGIC):
                return data
    return None


def image_size(path: Path):
    completed = subprocess.run(
        ["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", os.fspath(path)],
        check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=30)
    width = height = None
    for line in completed.stdout.splitlines():
        if "pixelWidth:" in line:
            width = int(round(float(line.rsplit(":", 1)[-1])))
        elif "pixelHeight:" in line:
            height = int(round(float(line.rsplit(":", 1)[-1])))
    if not width or not height or width > 8000 or height > 8000:
        return None
    return width, height


def https_url(value):
    if isinstance(value, Path):
        for name in ("cardBackgroundCombined.png.urls", "cardBackgroundCombined.pdf.urls"):
            candidate = value / name
            if not candidate.is_file():
                continue
            try:
                found = https_url(json.loads(candidate.read_text(encoding="utf-8")))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                continue
            if found:
                return found
        return None
    if isinstance(value, dict):
        candidate = value.get("url")
        if isinstance(candidate, str) and candidate.startswith("https://") and len(candidate) <= 2000 and "\n" not in candidate:
            return candidate
        for child in value.values():
            found = https_url(child)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = https_url(child)
            if found:
                return found
    return None


def create_catalog(download: Path, output: Path) -> list[dict]:
    thumbs = output / "thumbs"
    thumbs.mkdir()
    cards = []
    passes = sorted(path for path in download.glob("*.pkpass") if path.is_dir())
    for pass_root in passes:
        metadata_path = pass_root / "pass.json"
        if not metadata_path.is_file():
            continue
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            continue
        if not isinstance(metadata, dict) or "paymentCard" not in metadata:
            continue
        card_id = pass_root.name.removesuffix(".pkpass")
        if not card_id or "/" in card_id or "\0" in card_id:
            continue
        title = display_text(metadata.get("organizationName"), 80) or display_text(metadata.get("description"), 80) or "Card"
        assets = []
        for name in ARTWORK:
            artwork = pass_root / name
            if not artwork.is_file():
                continue
            size = image_size(artwork)
            if size:
                assets.append({"name": name, "width": size[0], "height": size[1]})
        with tempfile.TemporaryDirectory(prefix="airlift-card-art-") as temporary:
            png = artwork_png(pass_root, Path(temporary))
        if png is None:
            front = download / f"{card_id}.cache" / "FrontFace"
            if front.is_file():
                try:
                    png = front_face_png(front)
                except (OSError, ValueError, KeyError, IndexError, plistlib.InvalidFileException):
                    png = None
        thumbnail = None
        if png is not None:
            thumbnail = thumbs / f"{hashlib.sha256(card_id.encode()).hexdigest()}.png"
            thumbnail.write_bytes(png)
        cards.append({
            "id": card_id,
            "title": title,
            "subtitle": f"•••• {account_suffix(metadata)}" if account_suffix(metadata) else "",
            "thumbnailPath": os.fspath(thumbnail) if thumbnail else None,
            "assets": assets,
            "sourceURL": https_url(pass_root),
        })
    return cards


def host_ok(result: dict) -> bool:
    return result.get("exitCode") == 0 and result.get("ok") is True


def relocate(udid: str, identifier: str, destination: str) -> bool:
    result = airlift.run_json(
        [os.fspath(airlift.AIRTRAFFIC_HOST), udid, identifier, destination], timeout=120)
    return host_ok(result)


def recovered_absent(udid: str, recovered: str) -> bool:
    exists = airlift.run_json(
        [os.fspath(BRIDGE), "generated-exists", udid, recovered], timeout=60)
    return exists.get("exitCode") == 0 and exists.get("exists") is False


def wait_recovered(udid, recovered, mode):
    result = airlift.run_json(
        [os.fspath(BRIDGE), "wait-recovered", udid, recovered, mode], timeout=30)
    if not host_ok(result):
        raise airlift.AirLiftError(result.get("error") or "Couldn't check the saved data.")
    return result


def run_steps(udid, pairs, callbacks):
    """One AirTraffic sync. callbacks[i] runs after pair i, while the sync stays open."""
    if len(pairs) != len(callbacks):
        raise airlift.AirLiftError("The device transfer reported an unexpected number of steps.")
    environment = os.environ.copy()
    environment["AIRLIFT_STEP"] = "1"
    command = [os.fspath(airlift.AIRTRAFFIC_HOST), udid]
    for identifier, destination in pairs:
        command.extend((identifier, destination))
    process = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=environment, text=True, bufsize=1)
    seen = []
    callback_error = None
    deadline = time.monotonic() + 90
    while process.poll() is None and time.monotonic() < deadline and len(seen) < len(callbacks):
        ready, _, _ = select.select([process.stderr], [], [], 0.5)
        if not ready:
            continue
        line = process.stderr.readline()
        if "AIRLIFT_STEP" not in line:
            continue
        step = int(line.rsplit("AIRLIFT_STEP", 1)[1])
        if step != len(seen):
            callback_error = callback_error or airlift.AirLiftError("The device transfer steps arrived out of order.")
        else:
            try:
                callbacks[step]()
            except Exception as error:
                callback_error = callback_error or error
            seen.append(step)
        process.stdin.write("c")
        process.stdin.flush()
    try:
        stdout, _stderr = process.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, _stderr = process.communicate()
        raise airlift.AirLiftError("The device transfer didn't finish in time.")
    result = None
    for line in reversed((stdout or "").splitlines()):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            result = value
            break
    if callback_error is not None:
        raise callback_error
    if process.returncode != 0 or not result or not result.get("ok") or seen != list(range(len(callbacks))):
        raise airlift.AirLiftError((result or {}).get("error") or "The device transfer didn't complete.")
    return result


def restore_cards(udid: str, restore_id: str, destination: str, recovered: str) -> bool:
    relocate(udid, restore_id, destination)
    if recovered_absent(udid, recovered):
        return True
    time.sleep(1)
    if recovered_absent(udid, recovered):
        return True
    relocate(udid, restore_id, destination)
    return recovered_absent(udid, recovered)


def list_cards(device_id: str) -> dict:
    target = airlift.normalize_target(CARDS_PATH)
    parent, leaf = posixpath.split(target)
    udid = airlift.resolve_device(device_id)["udid"]
    token = secrets.token_hex(10)
    source = f"{airlift.SOURCE_PREFIX}{token}"
    link = f"{airlift.LINK_PREFIX}{token}"
    recovered = f"{airlift.RECOVERED_PREFIX}{token}"
    link_id = f"../../{source}/p0/p1/p2/link"
    target_id = posixpath.relpath(target, airlift.AIRLOCK_ROOT)
    restore_id = f"../../{recovered}"
    restore_destination = posixpath.join(link, leaf)
    output = Path(tempfile.mkdtemp(prefix="airlift-cards-"))
    work = Path(tempfile.mkdtemp(prefix="airlift-card-work-"))
    snapshot_root = work / "books-snapshot"
    moved = False
    restored = False
    cleanup_authorized = False
    finish = None
    cards = None
    error = None
    try:
        archive, books = work / "payload.zip", work / "Books.plist"
        snapshot_root.mkdir()
        archive.write_bytes(airlift.build_archive(parent, b"cards"))
        books.write_bytes(airlift.build_books([link_id, target_id, restore_id]))
        airlift.preflight(udid)
        snapshot = airlift.native("snapshot-books", udid, os.fspath(snapshot_root))
        if not airlift.operation_ok(snapshot):
            raise airlift.AirLiftError("Couldn't save the Books sync state.")
        stage = airlift.native(
            "stage", udid, source, link, recovered,
            os.fspath(archive), os.fspath(books), os.fspath(snapshot_root))
        cleanup_authorized = bool(stage.get("operation", {}).get("cleanupAuthorized"))
        if not airlift.operation_ok(stage):
            raise airlift.AirLiftError("Couldn't prepare to read the cards.")
        download = work / "Cards"

        def placed_link():
            return None

        def moved_cards():
            nonlocal moved, cards
            wait_recovered(udid, recovered, "directory")
            moved = True
            pulled = airlift.run_json(
                [os.fspath(BRIDGE), "pull-card-catalog", udid, recovered, os.fspath(download)],
                timeout=120)
            if not host_ok(pulled):
                raise airlift.AirLiftError(pulled.get("error") or "Couldn't copy the card images.")
            cards = create_catalog(download, output)
            shutil.rmtree(download, ignore_errors=True)

        def restored_cards():
            nonlocal restored
            wait_recovered(udid, recovered, "absent")
            restored = True

        run_steps(udid, [
            (link_id, link),
            (target_id, recovered),
            (restore_id, restore_destination),
        ], [placed_link, moved_cards, restored_cards])
    except Exception as caught:
        error = caught
    finally:
        try:
            if moved and not restored:
                try:
                    restored = restore_cards(udid, restore_id, restore_destination, recovered)
                except Exception as restore_error:
                    if error is None:
                        error = restore_error
            if cleanup_authorized and snapshot_root.is_dir() and (not moved or restored):
                try:
                    finish = airlift.run_json([
                        os.fspath(BRIDGE), "finish-delete", udid, source, link, recovered,
                        os.fspath(snapshot_root), "cleanup"], timeout=90)
                except Exception as finish_error:
                    if error is None:
                        error = finish_error
        finally:
            shutil.rmtree(work, ignore_errors=True)
    if error is not None or not restored or cards is None or not finish or finish.get("exitCode") or not finish.get("ok") or not finish.get("cleanupComplete"):
        shutil.rmtree(output, ignore_errors=True)
        if moved and not restored:
            raise airlift.AirLiftError(
                f"Couldn't put Cards back in its original location. The recovered data is kept in Media/{recovered}. Don't delete it.") from error
        if error is not None:
            raise error
        raise airlift.AirLiftError((finish or {}).get("error") or "Couldn't clean up after reading the card images.")
    return {"ok": True, "cards": cards, "count": len(cards),
            "snapshotPath": os.fspath(output), "restored": True, "cleanupComplete": True}


def self_test() -> None:
    png = bytes.fromhex(
        "89504e470d0a1a0a0000000d4948445200000001000000010802000000907753de"
        "0000000c4944415408d763f8cfc00000000300010005fe02fedccc59e70000000049454e44ae426082")
    objects = ["$null", {"faceImage": plistlib.UID(2)}, {"imageData": plistlib.UID(3)}, {"NS.data": png}]
    archive = {"$version": 100000, "$archiver": "NSKeyedArchiver",
               "$top": {"root": plistlib.UID(1)}, "$objects": objects}
    blob = plistlib.dumps(archive, fmt=plistlib.FMT_BINARY)
    front = b"\0" * 16 + hashlib.sha256(blob).digest() + blob
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        payment = root / "pay.pkpass"
        payment.mkdir()
        (payment / "pass.json").write_text(json.dumps({
            "organizationName": "Example Bank",
            "description": "Visa",
            "primaryAccountNumberSuffix": "4242",
            "primaryAccountNumber": "4111111111114242",
            "paymentCard": {"network": "Visa"},
        }), encoding="utf-8")
        other = root / "ticket.pkpass"
        other.mkdir()
        (other / "pass.json").write_text(json.dumps({"description": "Ticket"}), encoding="utf-8")
        secret = root / "pay.pkpass" / "signature"
        secret.write_bytes(b"secret")
        (payment / "cardBackgroundCombined.png.urls").write_text(json.dumps({
            "url": "file:///tmp/secret",
            "art": {"url": "https://example.com/original.png"},
        }), encoding="utf-8")
        cache = root / "pay.cache"
        cache.mkdir()
        (cache / "FrontFace").write_bytes(front)
        output = root / "out"
        output.mkdir()
        cards = create_catalog(root, output)
        assert len(cards) == 1
        assert cards[0]["title"] == "Example Bank"
        assert cards[0]["subtitle"] == "•••• 4242"
        assert cards[0]["thumbnailPath"]
        saved = Path(cards[0]["thumbnailPath"]).read_bytes()
        assert saved == png
        assert cards[0]["sourceURL"] == "https://example.com/original.png"
        assert "file://" not in json.dumps(cards)
        assert "4111111111114242" not in json.dumps(cards)
        assert not list(output.rglob("pass.json"))
        assert not list(output.rglob("signature"))
        long_suffix = root / "long.pkpass"
        long_suffix.mkdir()
        (long_suffix / "pass.json").write_text(json.dumps({
            "organizationName": "Other",
            "primaryAccountNumberSuffix": "4242424242424242",
            "paymentCard": {},
        }), encoding="utf-8")
        (long_suffix / "cardBackgroundCombined.png").write_bytes(png)
        again = root / "out2"
        again.mkdir()
        listed = create_catalog(root, again)
        long_card = next(card for card in listed if card["title"] == "Other")
        assert long_card["subtitle"] == ""
        assert long_card["assets"] == [{"name": "cardBackgroundCombined.png", "width": 1, "height": 1}]
        assert "4242424242424242" not in json.dumps(listed)
    print("ok")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.device:
        print(json.dumps({"ok": False, "error": "No device selected."}, ensure_ascii=False))
        return 1
    try:
        result = list_cards(args.device)
    except Exception as error:
        result = {"ok": False, "error": str(error)}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
