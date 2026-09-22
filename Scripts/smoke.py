#!/usr/bin/env python3
"""One bounded USB smoke check; only changes its own UUID-named directory."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "dist/Airlift Browser.app/Contents/Helpers/browser_bridge"


def call(*args, succeeds=True):
    process = subprocess.run([str(HELPER), *args], capture_output=True, timeout=130)
    reply = json.loads(process.stdout)
    assert reply["ok"] == succeeds, reply
    assert (process.returncode == 0) == succeeds, reply
    return reply


def main():
    devices = call("devices")["devices"]
    requested = sys.argv[1] if len(sys.argv) > 1 else None
    device = next(d for d in devices if (d["id"] == requested if requested else d["product"] == "iPad14,8"))
    udid = device["id"]
    root = "/AirliftBrowser-Smoke-" + uuid.uuid4().hex
    source = root + "/日本語 roundtrip.bin"
    renamed = root + "/renamed.bin"
    created = False
    remote_files = set()
    report = {"device": device, "checks": []}
    try:
        listing = call("list", udid, "/")
        report["rootEntryCount"] = len(listing["entries"])
        call("list", udid, "/../Library", succeeds=False)
        report["checks"].append("USB listing and path validation")
        call("mkdir", udid, root)
        created = True
        with tempfile.TemporaryDirectory(prefix="airlift-browser-smoke-") as temporary:
            local = Path(temporary) / "input.bin"
            output = Path(temporary) / "output.bin"
            payload = bytes(range(256)) * 1024 + "Airlift Browser USB実機検証\n".encode()
            local.write_bytes(payload)
            remote_files.add(source)
            call("put", udid, source, str(local))
            call("put", udid, source, str(local), succeeds=False)
            call("remove", udid, "/", succeeds=False)
            entries = call("list", udid, root)["entries"]
            assert len(entries) == 1 and entries[0]["size"] == len(payload), entries
            nested = root + "/nested"
            call("mkdir", udid, nested)
            call("put", udid, nested + "/leaf.bin", str(local))
            call("remove", udid, nested)
            assert all(item["id"] != nested for item in call("list", udid, root)["entries"])
            report["checks"].append("mkdir, Unicode upload, overwrite, root-delete rejection, nonempty directory delete")
            remote_files.add(renamed)
            call("rename", udid, source, renamed)
            remote_files.discard(source)
            call("get", udid, renamed, str(output))
            assert output.read_bytes() == payload, "roundtrip differs"
            call("get", udid, renamed, str(output), succeeds=False)
            assert output.read_bytes() == payload, "existing local file changed"
            report["sha256"] = hashlib.sha256(payload).hexdigest()
            report["bytes"] = len(payload)
            report["checks"].append("rename, download, exact-byte SHA-256 match, local overwrite rejection")
            call("remove", udid, renamed)
            remote_files.discard(renamed)
            assert call("list", udid, root)["entries"] == []
        call("remove", udid, root)
        created = False
        assert root not in {item["id"] for item in call("list", udid, "/")["entries"]}
        report["checks"].append("file/directory cleanup and absence verification")
        report["ok"] = True
    finally:
        if created:
            # Never recurse or touch any path that this check did not create.
            for entry in call("list", udid, root)["entries"]:
                if entry["id"] in remote_files or entry["name"].startswith(".airlift-upload-"):
                    call("remove", udid, entry["id"])
            call("remove", udid, root)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
