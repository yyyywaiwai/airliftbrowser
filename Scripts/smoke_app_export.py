#!/usr/bin/env python3
"""Export selected X items on the connected test device; never stage a full region.

Usage: python3 -B Scripts/smoke_app_export.py UDID
Uses the metadata fixtures produced by smoke_app_listing.py for X.
"""
import asyncio
import fcntl
import json
from pathlib import Path
import posixpath
import sys
import tempfile
import time
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Sources/AppManagement"))
import catalog
import manager
import storage
import transport
from common import HOME, Reporter, atomic_json, read_json, sha256


async def run(device):
    bundle = "com.atebits.Tweetie2"
    app, device_info = await catalog.resolve(device, bundle)
    tree = read_json(ROOT / "dist/listing-smoke-3.json")["tree"]
    nested = next(row["id"] for row in tree if row["id"].startswith("Frameworks/") and row["id"].endswith("/Info.plist"))
    folder = next(row["id"] for row in tree if row["kind"] == "directory" and row["id"].startswith("ChatCore_ChatStrings.bundle/") and row["id"].endswith(".lproj"))
    cases = [("bundle:" + bundle, "Info.plist"), ("bundle:" + bundle, nested),
             ("bundle:" + bundle, folder), ("data:" + bundle, "Library/Preferences/APMAnalyticsSuiteName.plist")]
    real_relocate = transport.relocate
    real_cleanup = transport.Lease.cleanup
    results = []
    identities = {}
    for region_id, selected in cases:
        region = next(item for item in app["regions"] if item["id"] == region_id)
        expected_id = posixpath.relpath(posixpath.join(region["path"], selected), transport.airlift.AIRLOCK_ROOT)
        moves = []
        restored = False
        copied = False

        async def relocate(serial, identifier, destination):
            if "/p0/p1/p2/" not in identifier:
                expected = expected_id if region["kind"] == "bundle" else posixpath.relpath(region["path"], transport.airlift.AIRLOCK_ROOT)
                assert identifier == expected or identifier.startswith("../../airlift-recovered-"), identifier
                moves.append(identifier)
            await real_relocate(serial, identifier, destination)

        async def cleanup(lease):
            nonlocal restored, copied
            if "originalRoot" in lease.state:
                assert await lease.source_matches()
                if "sourceContainerRoot" in lease.state:
                    identities[region_id] = json.dumps(lease.state["sourceContainerRoot"], sort_keys=True)
                restored = True
                copied = lease.state.get("copiedSource", False)
            await real_cleanup(lease)

        with tempfile.TemporaryDirectory(prefix="airlift-selected-export-") as temporary:
            local = Path(temporary) / "item"
            start = time.monotonic()
            with patch.object(transport, "relocate", relocate), patch.object(transport.Lease, "cleanup", cleanup):
                result = await manager.dispatch({"action": "get", "device": device, "appID": bundle,
                                                  "regionID": region_id, "relative": selected,
                                                  "containerPath": region["path"], "sourceIdentity": identities.get(region_id),
                                                  "file": next((row for row in tree if row["id"] == selected), None),
                                                  "local": str(local)}, Reporter())
            elapsed = time.monotonic() - start
            assert restored and not transport.pending(device)
            assert len(moves) == (1 if copied else 2)
            if local.is_file():
                assert sha256(local) == result["hash"]
                size = local.stat().st_size
                count = 1
            else:
                entries = storage.inventory(local)
                expected = {row["id"].removeprefix(selected + "/"): row["size"] for row in tree
                            if row["kind"] == "file" and row["id"].startswith(selected + "/")}
                actual = {row["path"]: row["size"] for row in entries if row["kind"] == "file"}
                assert expected == actual
                size = sum(actual.values())
                count = len(actual)
            results.append({"region": region_id, "selected": selected, "bytes": size, "files": count,
                            "seconds": elapsed, "copied": copied, "originalMetadataRestored": restored,
                            "wholeContainerCopies": 0})
    report = {"device": device_info, "app": bundle, "exports": results, "pendingOperations": len(transport.pending(device))}
    atomic_json(ROOT / "dist/app-export-smoke.json", report)
    print(report)


if __name__ == "__main__":
    HOME.mkdir(parents=True, exist_ok=True)
    with (HOME / "manager.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        asyncio.run(run(sys.argv[1]))
