#!/usr/bin/env python3
"""List installed app and app-group containers as JSON."""
import argparse
import asyncio
import json
import os
import posixpath
import subprocess
import sys
from urllib.parse import unquote, urlparse

sys.dont_write_bytecode = True

DATA_ROOT = "/var/mobile/Containers/Data/Application"
GROUP_ROOT = "/var/mobile/Containers/Shared/AppGroup"
BUNDLE_ROOT = "/var/containers/Bundle/Application"


def run(*arguments):
    completed = subprocess.run(
        ["xcrun", "devicectl", *arguments, "--quiet", "--json-output", "-"],
        check=True, capture_output=True, text=True, timeout=30)
    return json.loads(completed.stdout)["result"]


def ensure_python():
    try:
        import pymobiledevice3  # noqa: F401
        return
    except ImportError:
        pass
    for candidate in ("/opt/homebrew/bin/python3", "/usr/local/bin/python3"):
        if candidate != sys.executable and os.access(candidate, os.X_OK):
            os.execv(candidate, [candidate, *sys.argv])


def devicectl_apps(device):
    return run("device", "info", "apps", "--device", device,
               "--include-all-apps", "--include-container-paths",
               "--include-app-group-identifiers")["apps"]


async def load_installed(device):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    async with await create_using_usbmux(serial=device) as lockdown:
        async with InstallationProxyService(lockdown) as service:
            found = await service.lookup({
                "ApplicationType": "Any",
                "ReturnAttributes": [
                    "CFBundleDisplayName", "CFBundleName", "Container", "Path", "GroupContainers",
                ],
            })
    apps = []
    for identifier, info in (found or {}).items():
        if not isinstance(info, dict):
            continue
        path = info.get("Path") or ""
        apps.append({
            "bundleIdentifier": identifier,
            "name": info.get("CFBundleDisplayName") or info.get("CFBundleName") or identifier,
            "dataContainerPath": info.get("Container") or None,
            "url": f"file://{path}" if path else None,
            "groupContainerPaths": info.get("GroupContainers") or {},
        })
    return apps


def installed_apps(device):
    try:
        return asyncio.run(load_installed(device))
    except Exception:
        return devicectl_apps(device)


def normalized(path):
    return path.removeprefix("/private")


def container_roots(installed, group=False):
    rows = {}
    for app in installed:
        paths = app.get("groupContainerPaths", {}) if group else {
            app.get("bundleIdentifier", ""): app.get("dataContainerPath")}
        for identifier, raw_path in paths.items():
            if not raw_path:
                continue
            path = normalized(raw_path)
            row = rows.setdefault(path, {
                "id": path,
                "name": posixpath.basename(path),
                "kind": "S_IFDIR",
                "size": -1,
                "subtitle": identifier if group else app.get("name", identifier),
                "domainIdentifier": identifier,
            })
            if not group and app.get("bundleIdentifier"):
                name = app.get("name") or ""
                bundle_id = app["bundleIdentifier"]
                row["subtitle"] = f"{name} · {bundle_id}" if name and name != bundle_id else bundle_id
    return sorted(rows.values(), key=lambda row: (row["subtitle"].casefold(), row["name"]))


IGNORED_PREFERENCE_NAMES = {
    "APMExperimentSuiteName",
    "APMAnalyticsSuiteName",
    "__gads__",
    "com.google.gmp.measurement",
    "com.google.gmp.measurement.monitor",
    "com.firebase.FIRInstallations",
    "com.revenuecat.user_defaults",
    "Mixpanel",
}


def preference_identifier(name):
    stem = name.removesuffix(".plist").removesuffix(".savedState")
    if "." not in stem or " " in stem or stem in IGNORED_PREFERENCE_NAMES:
        return None
    if stem.startswith(("com.google.", "com.firebase.", "com.revenuecat.")):
        return None
    return stem


async def extra_data_rows(device, known_paths, names_by_bundle):
    """Name data containers missing from installd, using snapshots and preference names."""
    from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
    from pymobiledevice3.services.dvt.instruments.application_listing import ApplicationListing
    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider

    async with UserspaceRsdTunnel(serial=device) as rsd:
        async with DvtProvider(rsd) as dvt:
            async with DeviceInfo(dvt) as info:
                try:
                    present = await info.ls(DATA_ROOT)
                except Exception:
                    return []
                missing = [name for name in present if f"{DATA_ROOT}/{name}" not in known_paths]
                if not missing:
                    return []
                semaphore = asyncio.Semaphore(16)

                async def names_at(uuid, relative):
                    async with semaphore:
                        try:
                            return await info.ls(f"{DATA_ROOT}/{uuid}/{relative}")
                        except Exception:
                            return []

                async def identify(uuid):
                    snapshots = await names_at(uuid, "Library/SplashBoard/Snapshots")
                    if snapshots:
                        bundle_id = snapshots[0].split(" - ", 1)[0].strip()
                        if preference_identifier(bundle_id + ".plist"):
                            return uuid, bundle_id
                    found = []
                    for relative in (
                        "Library/Preferences",
                        "Library/Saved Application State",
                        "Library/HTTPStorages",
                    ):
                        for name in await names_at(uuid, relative):
                            identifier = preference_identifier(name)
                            if identifier and identifier not in found:
                                found.append(identifier)
                    if not found:
                        return None
                    known = [identifier for identifier in found if identifier in names_by_bundle]
                    chosen = known[0] if len(known) == 1 else found[0] if len(found) == 1 else None
                    return (uuid, chosen) if chosen else None

                pairs = [pair for pair in await asyncio.gather(*(identify(uuid) for uuid in missing)) if pair]
            if not pairs:
                return []
            display = dict(names_by_bundle)
            if any(bundle_id not in display for _, bundle_id in pairs):
                async with ApplicationListing(dvt) as listing:
                    for row in await listing.applist():
                        identifier = row.get("CFBundleIdentifier")
                        if identifier and row.get("DisplayName"):
                            display.setdefault(identifier, row["DisplayName"])
    rows = []
    for uuid, bundle_id in pairs:
        name = display.get(bundle_id) or bundle_id
        rows.append({
            "id": f"{DATA_ROOT}/{uuid}",
            "name": uuid,
            "kind": "S_IFDIR",
            "size": -1,
            "subtitle": f"{name} · {bundle_id}" if name != bundle_id else bundle_id,
            "domainIdentifier": bundle_id,
        })
    return rows


def bundle_rows(installed):
    rows = []
    for app in installed:
        raw_url = app.get("url")
        identifier = app.get("bundleIdentifier")
        if not raw_url or not identifier:
            continue
        bundle = normalized(unquote(urlparse(raw_url).path)).rstrip("/")
        root = posixpath.dirname(bundle)
        if not root.startswith(BUNDLE_ROOT + "/"):
            continue
        rows.append({
            "id": root,
            "name": posixpath.basename(root),
            "kind": "S_IFDIR",
            "size": -1,
            "subtitle": (
                f"{app['name']} · {identifier}"
                if app.get("name") and app.get("name") != identifier else identifier
            ),
            "bundlePath": bundle,
        })
    return rows


def list_domain(device, domain, identifier, base, relative):
    command = ["device", "info", "files", "--device", device,
               "--domain-type", domain, "--domain-identifier", identifier,
               "--no-recurse"]
    if relative:
        command += ["--subdirectory", relative]
    files = run(*command)["files"]
    return [{
        "id": posixpath.join(base, item["relativePath"]),
        "name": item["name"],
        "kind": "S_IFLNK" if item["resources"].get("isSymbolicLink")
                else "S_IFDIR" if item["resources"].get("isDirectory") else "S_IFREG",
        "size": item.get("metadata", {}).get("size", -1),
    } for item in files]


def browse(device, path):
    installed = installed_apps(device)
    bundles = bundle_rows(installed)
    if path == BUNDLE_ROOT:
        return sorted(bundles, key=lambda row: (row["subtitle"].casefold(), row["name"]))
    if posixpath.dirname(path) == BUNDLE_ROOT:
        return [{**row, "id": row["bundlePath"], "name": posixpath.basename(row["bundlePath"])}
                for row in bundles if row["id"] == path]
    if path == DATA_ROOT:
        rows = container_roots(installed)
        names = {app.get("bundleIdentifier"): app.get("name") or app.get("bundleIdentifier")
                 for app in installed if app.get("bundleIdentifier")}
        try:
            rows.extend(asyncio.run(extra_data_rows(device, {row["id"] for row in rows}, names)))
        except Exception:
            pass
        return sorted(rows, key=lambda row: ((row.get("subtitle") or "").casefold(), row["name"]))
    if path == GROUP_ROOT:
        return container_roots(installed, group=True)
    for root, domain, rows in (
        (DATA_ROOT, "appDataContainer", container_roots(installed)),
        (GROUP_ROOT, "appGroupDataContainer", container_roots(installed, group=True)),
    ):
        if not path.startswith(root + "/"):
            continue
        uuid = path[len(root) + 1:].split("/", 1)[0]
        base = f"{root}/{uuid}"
        row = next((row for row in rows if row["id"] == base), None)
        if not row:
            raise ValueError("This container can't be accessed.")
        relative = path[len(base):].lstrip("/")
        return list_domain(device, domain, row["domainIdentifier"], base, relative)
    raise ValueError("This folder can't be listed.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True)
    parser.add_argument("--path", required=True)
    args = parser.parse_args()
    ensure_python()
    try:
        result = {"ok": True, "entries": browse(args.device, args.path)}
    except Exception as error:
        result = {"ok": False, "error": str(error)}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
