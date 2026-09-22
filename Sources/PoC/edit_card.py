#!/usr/bin/env python3
"""Replace an Apple Pay card face, or restore the original from its CDN URL."""
import argparse
import json
import os
from pathlib import Path
import posixpath
import secrets
import subprocess
import sys
import tempfile
import urllib.request

sys.dont_write_bytecode = True

import list_cards

airlift = list_cards.airlift
BRIDGE = list_cards.BRIDGE
CARDS_PATH = list_cards.CARDS_PATH
ARTWORK = list_cards.ARTWORK
PNG_MAGIC = list_cards.PNG_MAGIC


def fit_cover(source: Path, width: int, height: int, output: Path) -> None:
    if width < 1 or height < 1 or width > 8000 or height > 8000:
        raise ValueError("券面サイズが不正です。")
    with tempfile.TemporaryDirectory(prefix="airlift-fit-") as temporary:
        temp = Path(temporary)
        raster = temp / "source.png"
        if source.read_bytes().startswith(PNG_MAGIC):
            raster = source
        else:
            completed = subprocess.run(
                ["/usr/bin/sips", "-s", "format", "png", os.fspath(source), "--out", os.fspath(raster)],
                check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
            if completed.returncode != 0 or not raster.is_file():
                raise ValueError("選択した画像を読み込めませんでした。")
        size = list_cards.image_size(raster)
        if not size:
            raise ValueError("選択した画像のサイズを読み取れませんでした。")
        scale = max(width / float(size[0]), height / float(size[1]))
        resized_width = max(width, int(round(size[0] * scale)))
        resized_height = max(height, int(round(size[1] * scale)))
        scaled = temp / "scaled.png"
        fitted = temp / "fitted.png"
        subprocess.check_call(
            ["/usr/bin/sips", "-z", str(resized_height), str(resized_width),
             os.fspath(raster), "--out", os.fspath(scaled)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        subprocess.check_call(
            ["/usr/bin/sips", "--cropToHeightWidth", str(height), str(width),
             "--cropOffset", str((resized_height - height) // 2), str((resized_width - width) // 2),
             os.fspath(scaled), "--out", os.fspath(fitted)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        if output.suffix.lower() == ".pdf":
            subprocess.check_call(
                ["/usr/bin/sips", "-s", "format", "pdf", os.fspath(fitted), "--out", os.fspath(output)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        else:
            output.write_bytes(fitted.read_bytes())
    data = output.read_bytes()
    if output.suffix.lower() == ".pdf":
        if not data.startswith(b"%PDF-"):
            raise ValueError("差し替え用データがPDFではありません。")
    elif not data.startswith(PNG_MAGIC):
        raise ValueError("差し替え用データがPNGではありません。")
    if len(data) > 16 * 1024 * 1024:
        raise ValueError("差し替え用データが大きすぎます。")


def safe_card_id(card_id):
    if not card_id or card_id in (".", "..") or "/" in card_id or "\0" in card_id or len(card_id.encode()) > 255:
        raise ValueError("カードIDが不正です。")
    return card_id


def parse_asset(text):
    name, width_text, height_text = text.rsplit(":", 2)
    if name not in ARTWORK:
        raise ValueError("券面ファイル名が不正です。")
    width, height = int(width_text), int(height_text)
    if width < 1 or height < 1 or width > 8000 or height > 8000:
        raise ValueError("券面サイズが不正です。")
    return {"name": name, "width": width, "height": height}


def bridge(udid, *arguments):
    result = airlift.run_json([os.fspath(BRIDGE), *arguments[:1], udid, *arguments[1:]], timeout=60)
    if not list_cards.host_ok(result):
        raise airlift.AirLiftError(result.get("error") or "端末操作に失敗しました。")
    return result


def staged_names(device_id):
    udid = airlift.resolve_device(device_id)["udid"]
    token = secrets.token_hex(10)
    source = "%s%s" % (airlift.SOURCE_PREFIX, token)
    link = "%s%s" % (airlift.LINK_PREFIX, token)
    recovered = "%s%s" % (airlift.RECOVERED_PREFIX, token)
    return udid, source, link, recovered


def exchange_file(device_id, directory, name, payload):
    """Replace one existing file in a single AirTraffic sync and verify the bytes."""
    if name not in ARTWORK and name not in list_cards.CACHE_LEAVES:
        raise ValueError("券面データが不正です。")
    if not payload or len(payload) > 32 * 1024 * 1024:
        raise ValueError("券面データが大きすぎます。")
    directory = airlift.normalize_target(directory)
    udid, source, link, recovered = staged_names(device_id)
    link_id = "../../%s/p0/p1/p2/link" % source
    payload_id = "../../%s/payload" % source
    target_path = posixpath.join(directory, name)
    target_id = posixpath.relpath(target_path, airlift.AIRLOCK_ROOT)
    relative_dir, leaf = posixpath.split(target_id)
    lexical_id = "%s/./%s" % (relative_dir, leaf)
    restore_id = "../../%s" % recovered
    destination = posixpath.join(link, name)
    with tempfile.TemporaryDirectory(prefix="airlift-card-swap-") as temporary:
        work = Path(temporary)
        snapshot_root = work / "books-snapshot"
        snapshot_root.mkdir()
        expected = work / "expected.bin"
        backup = work / "backup.bin"
        expected.write_bytes(payload)
        (work / "payload.zip").write_bytes(airlift.build_archive(directory, payload))
        (work / "Books.plist").write_bytes(airlift.build_books(
            [link_id, target_id, payload_id, lexical_id, restore_id]))
        airlift.preflight(udid)
        if not airlift.operation_ok(airlift.native("snapshot-books", udid, os.fspath(snapshot_root))):
            raise airlift.AirLiftError("Books同期状態を保存できませんでした。")
        stage = airlift.native(
            "stage", udid, source, link, recovered,
            os.fspath(work / "payload.zip"), os.fspath(work / "Books.plist"),
            os.fspath(snapshot_root))
        cleanup_authorized = bool(stage.get("operation", {}).get("cleanupAuthorized"))
        if not airlift.operation_ok(stage):
            raise airlift.AirLiftError("券面書き込みの準備に失敗しました。")
        original = b""
        moved = False
        verified = False
        restored = False

        def hold_original():
            nonlocal original, moved
            list_cards.wait_recovered(udid, recovered, "file")
            bridge(udid, "get", "/" + recovered, os.fspath(backup))
            original = backup.read_bytes()
            bridge(udid, "remove", "/" + recovered)
            moved = True

        def check_new():
            nonlocal verified
            list_cards.wait_recovered(udid, recovered, "file")
            try:
                bridge(udid, "verify-recovered", recovered, os.fspath(expected))
                verified = True
            except airlift.AirLiftError:
                bridge(udid, "remove", "/" + recovered)
                backup.write_bytes(original)
                bridge(udid, "put", "/" + recovered, os.fspath(backup))

        def confirm_back():
            nonlocal restored
            list_cards.wait_recovered(udid, recovered, "absent")
            restored = True

        try:
            list_cards.run_steps(udid, [
                (link_id, link),
                (target_id, recovered),
                (payload_id, destination),
                (lexical_id, recovered),
                (restore_id, destination),
            ], [lambda: None, hold_original, lambda: None, check_new, confirm_back])
        finally:
            if moved and not restored:
                list_cards.restore_cards(udid, restore_id, destination, recovered)
            if cleanup_authorized:
                airlift.run_json([
                    os.fspath(BRIDGE), "finish-write", udid, source, link, recovered,
                    os.fspath(expected), directory[1:], name, os.fspath(snapshot_root)], timeout=90)
        if not verified or not restored:
            raise airlift.AirLiftError("差し替えた券面を確認できませんでした。")


def copy_file(device_id, target, local_path):
    parent, leaf = posixpath.split(airlift.normalize_target(target))
    udid, source, link, recovered = staged_names(device_id)
    link_id = "../../%s/p0/p1/p2/link" % source
    target_id = posixpath.relpath(target, airlift.AIRLOCK_ROOT)
    restore_id = "../../%s" % recovered
    with tempfile.TemporaryDirectory(prefix="airlift-card-copy-") as temporary:
        work = Path(temporary)
        snapshot_root = work / "books-snapshot"
        snapshot_root.mkdir()
        archive = work / "payload.zip"
        books = work / "Books.plist"
        archive.write_bytes(airlift.build_archive(parent, b"copy"))
        books.write_bytes(airlift.build_books([link_id, target_id, restore_id]))
        airlift.preflight(udid)
        if not airlift.operation_ok(airlift.native("snapshot-books", udid, os.fspath(snapshot_root))):
            raise airlift.AirLiftError("Books同期状態を保存できませんでした。")
        stage = airlift.native(
            "stage", udid, source, link, recovered,
            os.fspath(archive), os.fspath(books), os.fspath(snapshot_root))
        cleanup_authorized = bool(stage.get("operation", {}).get("cleanupAuthorized"))
        if not airlift.operation_ok(stage):
            raise airlift.AirLiftError("ファイル読み出しの準備に失敗しました。")
        copied = False
        back = False

        def grab():
            nonlocal copied
            list_cards.wait_recovered(udid, recovered, "file")
            bridge(udid, "get", "/" + recovered, local_path)
            copied = True

        def confirm():
            nonlocal back
            list_cards.wait_recovered(udid, recovered, "absent")
            back = True

        try:
            list_cards.run_steps(udid, [
                (link_id, link),
                (target_id, recovered),
                (restore_id, posixpath.join(link, leaf)),
            ], [lambda: None, grab, confirm])
        finally:
            if copied and not back:
                list_cards.restore_cards(udid, restore_id, posixpath.join(link, leaf), recovered)
            if cleanup_authorized:
                airlift.run_json([
                    os.fspath(BRIDGE), "finish-delete", udid, source, link, recovered,
                    os.fspath(snapshot_root), "cleanup"], timeout=90)
        if not copied:
            raise airlift.AirLiftError("ファイルを読み出せませんでした。")


def remove_file(device_id, target):
    parent, _leaf = posixpath.split(airlift.normalize_target(target))
    udid, source, link, recovered = staged_names(device_id)
    link_id = "../../%s/p0/p1/p2/link" % source
    target_id = posixpath.relpath(target, airlift.AIRLOCK_ROOT)
    with tempfile.TemporaryDirectory(prefix="airlift-card-drop-") as temporary:
        work = Path(temporary)
        snapshot_root = work / "books-snapshot"
        snapshot_root.mkdir()
        archive = work / "payload.zip"
        books = work / "Books.plist"
        archive.write_bytes(airlift.build_archive(parent, b"drop"))
        books.write_bytes(airlift.build_books([link_id, target_id]))
        airlift.preflight(udid)
        if not airlift.operation_ok(airlift.native("snapshot-books", udid, os.fspath(snapshot_root))):
            return False
        stage = airlift.native(
            "stage", udid, source, link, recovered,
            os.fspath(archive), os.fspath(books), os.fspath(snapshot_root))
        cleanup = bool(stage.get("operation", {}).get("cleanupAuthorized"))
        removed = False

        def drop():
            nonlocal removed
            list_cards.wait_recovered(udid, recovered, "file")
            bridge(udid, "remove", "/" + recovered)
            removed = True

        try:
            if not airlift.operation_ok(stage):
                return False
            try:
                list_cards.run_steps(udid, [(link_id, link), (target_id, recovered)], [lambda: None, drop])
            except Exception:
                return False
        finally:
            if cleanup:
                airlift.run_json([
                    os.fspath(BRIDGE), "finish-delete", udid, source, link, recovered,
                    os.fspath(snapshot_root), "cleanup"], timeout=90)
        return removed


def keep_shape(original, fitted):
    """Keep the original art's transparent rounded corners on the new image."""
    tool = list_cards.HELPERS / "mask_image"
    if not tool.is_file() or not fitted.startswith(PNG_MAGIC):
        return fitted
    source = original if isinstance(original, bytes) and original.startswith(PNG_MAGIC) else fitted
    with tempfile.TemporaryDirectory(prefix="airlift-mask-") as temporary:
        work = Path(temporary)
        (work / "original.png").write_bytes(source)
        (work / "fitted.png").write_bytes(fitted)
        output = work / "shaped.png"
        completed = subprocess.run(
            [os.fspath(tool), os.fspath(work / "original.png"), os.fspath(work / "fitted.png"),
             os.fspath(output)],
            check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        if completed.returncode != 0 or not output.is_file():
            return fitted
        shaped = output.read_bytes()
    return shaped if shaped.startswith(PNG_MAGIC) else fitted


def replace_assets(device_id, card_id, assets, image_path):
    card_id = safe_card_id(card_id)
    parent = posixpath.join(CARDS_PATH, card_id + ".pkpass")
    preview_dir = Path(tempfile.mkdtemp(prefix="airlift-card-preview-"))
    preview = preview_dir / "preview.png"
    replaced = []
    with tempfile.TemporaryDirectory(prefix="airlift-card-fit-") as temporary:
        work = Path(temporary)
        for asset in assets:
            fitted = work / asset["name"]
            fit_cover(Path(image_path), asset["width"], asset["height"], fitted)
            shaped = fitted.read_bytes()
            if fitted.suffix.lower() == ".png":
                backup = work / ("original-" + asset["name"])
                try:
                    copy_file(device_id, posixpath.join(parent, asset["name"]), os.fspath(backup))
                    shaped = keep_shape(backup.read_bytes(), shaped)
                except Exception:
                    shaped = keep_shape(b"", shaped)
            if not preview.exists():
                if shaped.startswith(PNG_MAGIC):
                    preview.write_bytes(shaped)
                else:
                    subprocess.check_call(
                        ["/usr/bin/sips", "-s", "format", "png", os.fspath(fitted), "--out", os.fspath(preview)],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
            exchange_file(device_id, parent, asset["name"], shaped)
            replaced.append(asset["name"])
    return replaced, os.fspath(preview)


def sniff_extension(payload):
    if payload.startswith(PNG_MAGIC):
        return "png"
    if payload.startswith(b"%PDF-"):
        return "pdf"
    if payload.startswith(b"\xff\xd8"):
        return "jpg"
    if payload[4:8] == b"ftyp" and (b"heic" in payload[:32] or b"heif" in payload[:32]):
        return "heic"
    return "bin"


def run_export(device_id, card_id, destination):
    if not isinstance(destination, str) or "\0" in destination or not os.path.isabs(destination):
        raise ValueError("保存先が不正です。")
    payload = download_original(read_original_url(device_id, card_id))
    Path(destination).write_bytes(payload)
    return {"ok": True, "fileExtension": sniff_extension(payload)}


def download_original(url):
    if not isinstance(url, str) or not url.startswith("https://") or len(url) > 2000:
        raise ValueError("元画像のURLがhttpsではありません。")
    request = urllib.request.Request(url, headers={"User-Agent": "AirliftBrowser"})
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = response.read(16 * 1024 * 1024 + 1)
    if not payload or len(payload) > 16 * 1024 * 1024:
        raise ValueError("元画像のサイズが不正です。")
    return payload


def read_original_url(device_id, card_id):
    card_id = safe_card_id(card_id)
    with tempfile.TemporaryDirectory(prefix="airlift-card-url-") as temporary:
        work = Path(temporary)
        for leaf in ("cardBackgroundCombined.png.urls", "cardBackgroundCombined.pdf.urls"):
            local = work / leaf
            try:
                copy_file(device_id, posixpath.join(CARDS_PATH, card_id + ".pkpass", leaf), os.fspath(local))
            except Exception:
                continue
            if not local.is_file():
                continue
            try:
                found = list_cards.https_url(json.loads(local.read_text(encoding="utf-8")))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                continue
            if found:
                return found
    raise RuntimeError("元画像のURLが券面データにありません。")


def restart_wallet(device_id):
    udid = airlift.resolve_device(device_id)["udid"]
    suffixes = (
        "/PassbookUIService.app/PassbookUIService",
        "/PassbookUISceneService.app/PassbookUISceneService",
        "/Passbook.app/Passbook",
        "/WalletApp.app/WalletApp",
    )
    signaled = False
    for search in ("Passbook", "Wallet"):
        completed = subprocess.run(
            ["xcrun", "devicectl", "device", "info", "processes", "--device", udid,
             "--search", search, "--timeout", "15", "--quiet", "--json-output", "-"],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=25)
        try:
            processes = json.loads(completed.stdout).get("result", {}).get("runningProcesses", [])
        except json.JSONDecodeError:
            continue
        for process in processes:
            executable = process.get("executable")
            pid = process.get("processIdentifier")
            if not isinstance(executable, str) or not isinstance(pid, int):
                continue
            if not executable.endswith(suffixes):
                continue
            result = subprocess.run(
                ["xcrun", "devicectl", "device", "process", "signal", "--device", udid,
                 "--pid", str(pid), "--signal", "15", "--timeout", "10", "--quiet", "--json-output", "-"],
                check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
            signaled = signaled or result.returncode == 0
    launched = subprocess.run(
        ["xcrun", "devicectl", "device", "process", "launch", "--device", udid,
         "--terminate-existing", "--timeout", "15", "com.apple.Passbook",
         "--quiet", "--json-output", "-"],
        check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=25)
    return signaled or launched.returncode == 0


def clear_display_cache(device_id, card_id):
    card_id = safe_card_id(card_id)
    parent = posixpath.join(CARDS_PATH, card_id + ".cache")
    cleared = False
    for leaf in list_cards.CACHE_LEAVES:
        if remove_file(device_id, posixpath.join(parent, leaf)):
            cleared = True
    return cleared


def run_replace(device_id, card_id, assets, image_path):
    replaced, preview = replace_assets(device_id, card_id, assets, image_path)
    cache_cleared = clear_display_cache(device_id, card_id)
    wallet_restarted = restart_wallet(device_id)
    return {"ok": True, "replaced": replaced, "thumbnailPath": preview,
            "cacheCleared": cache_cleared, "walletRestarted": wallet_restarted}


def run_restore(device_id, card_id, assets):
    url = read_original_url(device_id, card_id)
    with tempfile.TemporaryDirectory(prefix="airlift-original-") as temporary:
        download = Path(temporary) / "original"
        download.write_bytes(download_original(url))
        return run_replace(device_id, card_id, assets, download)


def self_test():
    raw = bytes.fromhex(
        "89504e470d0a1a0a0000000d4948445200000001000000010802000000907753de"
        "0000000c4944415408d763f8cfc00000000300010005fe02fedccc59e70000000049454e44ae426082")
    with tempfile.TemporaryDirectory() as temporary:
        source = Path(temporary) / "in.png"
        source.write_bytes(raw)
        output = Path(temporary) / "out.png"
        fit_cover(source, 2, 2, output)
        assert output.read_bytes().startswith(PNG_MAGIC)
        size = list_cards.image_size(output)
        assert size == (2, 2)
    assert list_cards.https_url({"url": "file:///tmp/x", "art": {"url": "https://example.com/a.png"}}) == "https://example.com/a.png"
    try:
        download_original("file:///etc/passwd")
    except ValueError:
        pass
    else:
        raise AssertionError("file URL was accepted")
    assert sniff_extension(raw) == "png"
    assert sniff_extension(b"%PDF-1.7") == "pdf"
    try:
        run_export("device", "card", "relative.png")
    except ValueError:
        pass
    else:
        raise AssertionError("relative export path was accepted")
    print("ok")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--restore", action="store_true")
    parser.add_argument("--export", metavar="PATH")
    parser.add_argument("--device")
    parser.add_argument("--card-id")
    parser.add_argument("--image")
    parser.add_argument("--asset", action="append", default=[])
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    try:
        if args.export:
            if not args.device or not args.card_id:
                raise ValueError("カードを指定してください。")
            result = run_export(args.device, args.card_id, args.export)
        else:
            assets = [parse_asset(item) for item in args.asset]
            if not args.device or not args.card_id or not assets:
                raise ValueError("カードと券面ファイルを指定してください。")
            if args.restore:
                result = run_restore(args.device, args.card_id, assets)
            else:
                if not args.image:
                    raise ValueError("差し替える画像を指定してください。")
                result = run_replace(args.device, args.card_id, assets, args.image)
    except Exception as error:
        result = {"ok": False, "error": str(error)}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
