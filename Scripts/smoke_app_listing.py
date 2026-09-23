#!/usr/bin/env python3
"""Read-only live metadata listing check. Usage: script UDID BUNDLE_ID

Stores fixtures for AIRLIFT_LISTING_FIXTURE=... swift test. Opens each region
once, compares sampled child listings during the same lease, and verifies that
no file contents were read and that cleanup completed before returning a tree.
"""
import asyncio
import fcntl
import json
from pathlib import Path
import posixpath
import sys
import time
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Sources/AppManagement"))
import catalog
import manager
import transport
from common import HOME, Reporter, atomic_json


async def run(device, bundle):
    app, device_info = await catalog.resolve(device, bundle)
    assert not transport.pending(device), "Recover pending operations first"
    rows = []
    original_listing = manager.listing_tree
    original_operation = transport.TimedAFC.__getattr__
    payload_reads = 0

    def metadata_only(self, name):
        if name in ("fopen", "fread", "get_file_contents", "pull"):
            nonlocal payload_reads
            payload_reads += 1
            raise AssertionError("Listing attempted to read file contents: " + name)
        return original_operation(self, name)

    async def checked_listing(lease):
        result = await original_listing(lease)
        directories = [""] + [entry["id"] for entry in result["tree"] if entry["kind"] == "directory"]
        # Compare shallow/deep/empty directories to ordinary live AFC listings.
        sample = list(dict.fromkeys(directories[:3] + sorted(directories, key=lambda p: p.count("/"))[-3:]))
        for rel in sample:
            direct = await manager.listing_remote(lease, rel)
            cached = [entry for entry in result["tree"] if posixpath.dirname(entry["id"]) == rel]
            assert sorted(direct["entries"], key=lambda e: e["id"]) == sorted(cached, key=lambda e: e["id"])
        checks.update(directories=len(directories), comparedDirectories=len(sample),
                      reusedCopyScan=lease.copy_tree is not None)
        return result

    with patch.object(transport.TimedAFC, "__getattr__", metadata_only), patch.object(manager, "listing_tree", checked_listing):
        for index, region in enumerate(app["regions"]):
            checks = {}
            start = time.monotonic()
            result = await manager.dispatch({"action": "list-tree", "device": device,
                                             "appID": bundle, "regionID": region["id"]}, Reporter())
            elapsed = time.monotonic() - start
            assert not transport.pending(device)
            fixture = ROOT / f"dist/listing-smoke-{index}.json"
            atomic_json(fixture, {"ok": True, **result})
            rows.append({"region": region["id"], "entries": len(result["tree"]),
                         "secondsIncludingCleanupAndComparison": elapsed, "fixture": str(fixture), **checks})
            print(json.dumps(rows[-1]), flush=True)
    report = {"device": device_info, "app": bundle, "regions": rows,
              "payloadReadCalls": payload_reads, "pendingOperations": len(transport.pending(device))}
    atomic_json(ROOT / "dist/app-listing-smoke.json", report)
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    HOME.mkdir(parents=True, exist_ok=True)
    with (HOME / "manager.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        asyncio.run(run(*sys.argv[1:]))
