#!/usr/bin/env python3
"""Live streaming/edit/delete smoke check inside a fresh app-owned tmp item.

The app's existing files are not edited. A round-trip report is written to dist.
Usage: python3 -B Scripts/smoke_app_containers.py UDID BUNDLE_ID [bytes]
"""
import asyncio
import fcntl
import json
from pathlib import Path
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Sources/AppManagement"))
import manager
import transport
from common import HOME, Reporter, atomic_json, sha256


async def run(device, bundle, size):
    reporter = Reporter()
    relative = "tmp/airlift-stream-test-" + str(uuid.uuid4()) + ".bin"
    context = {"device": device, "appID": bundle, "regionID": "data:" + bundle, "relative": relative}
    async with transport.connection(device) as afc:
        info = await afc.get_device_info()
        if int(info["FSFreeBytes"]) < size + 512 * 1024**2:
            raise ValueError("実機の空き容量が不足しています。")
    uploaded = False
    with tempfile.TemporaryDirectory(prefix="airlift-live-test-") as temporary:
        local = Path(temporary) / "source.bin"
        with local.open("wb") as stream:
            stream.truncate(size)
            stream.write(b"airlift streaming test\x00\xff")
            stream.seek(size - 32)
            stream.write(b"verified-end-of-large-file".ljust(32, b"\0"))
        try:
            await manager.dispatch({**context, "action": "mutate", "operation": "upload", "local": str(local)}, reporter)
            uploaded = True
            destination = Path(temporary) / "download.bin"
            result = await manager.dispatch({**context, "action": "get", "local": str(destination)}, reporter)
            expected = sha256(local)
            assert sha256(destination) == expected == result["hash"]
            assert destination.stat().st_size == size
        finally:
            if uploaded:
                await manager.dispatch({**context, "action": "mutate", "operation": "delete"}, reporter)
        listing = await manager.dispatch({**context, "action": "list", "relative": "tmp"}, reporter)
        assert all(row["id"] != relative for row in listing["entries"])
        assert not transport.pending(device)
        report = {"device": device, "app": bundle, "bytes": size, "sha256": expected,
                  "roundTripMatched": True, "testItemRemoved": True, "pendingOperations": 0}
        atomic_json(ROOT / "dist/app-container-smoke.json", report)
        print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    HOME.mkdir(parents=True, exist_ok=True)
    with (HOME / "manager.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        asyncio.run(run(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) == 4 else 129 * 1024**2 + 17))
