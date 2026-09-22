#!/usr/bin/env python3
"""List a real device directory through the DVT device-info service."""
import argparse
import asyncio
import json
import posixpath
import sys

sys.dont_write_bytecode = True

from pymobiledevice3.exceptions import DvtDirListError
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider


KNOWN_DIRECTORIES = {
    "/Applications",
    "/bin",
    "/cores",
    "/dev",
    "/Developer",
    "/etc",
    "/Library",
    "/private",
    "/sbin",
    "/System",
    "/tmp",
    "/usr",
    "/var",
    "/var/mobile",
    "/var/mobile/Documents",
    "/var/mobile/Library",
    "/var/mobile/Library/Preferences",
    "/var/mobile/Library/Caches",
    "/var/mobile/Library/SpringBoard",
    "/var/mobile/Library/SMS",
    "/var/mobile/Library/Safari",
    "/var/mobile/Media",
    "/var/mobile/Containers",
    "/var/mobile/Containers/Data",
    "/var/mobile/Containers/Data/Application",
    "/var/mobile/Containers/Shared",
    "/var/mobile/Containers/Shared/AppGroup",
}

DIRECTORY_ONLY_PATHS = {
    "/var",
    "/var/mobile/Containers/Data/Application",
    "/var/containers/Bundle/Application",
}


async def browse(device, path):
    async with UserspaceRsdTunnel(serial=device) as rsd:
        async with DvtProvider(rsd) as dvt, DeviceInfo(dvt) as info:
            names = await info.ls(path)
            semaphore = asyncio.Semaphore(24)

            async def entry(name):
                child = posixpath.join(path, name)
                is_directory = path in DIRECTORY_ONLY_PATHS or child in KNOWN_DIRECTORIES
                if not is_directory:
                    async with semaphore:
                        try:
                            await info.ls(child)
                            is_directory = True
                        except DvtDirListError:
                            pass
                return {
                    "id": child,
                    "name": name,
                    "kind": "S_IFDIR" if is_directory else "S_IFREG",
                    "size": -1,
                }

            return await asyncio.gather(*(entry(name) for name in names))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True)
    parser.add_argument("--path", required=True)
    args = parser.parse_args()
    try:
        result = {"ok": True, "entries": asyncio.run(
            asyncio.wait_for(browse(args.device, args.path), timeout=60))}
    except Exception as error:
        result = {"ok": False, "error": str(error) or type(error).__name__}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
