"""App identity and current container locations; no UUIDs cached across restores."""
import asyncio
import hashlib
from pathlib import Path
import posixpath
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "DeviceFiles"))
import container_files


def region(kind, identifier, path, name=None):
    return {"id": kind + ":" + identifier, "kind": kind, "identifier": identifier,
            "name": name or identifier, "path": container_files.normalized(path)}


async def installed(device):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    async with await create_using_usbmux(serial=device) as lockdown:
        device_info = {"id": device, "name": lockdown.all_values.get("DeviceName", device),
                       "version": lockdown.all_values.get("ProductVersion", ""),
                       "product": lockdown.all_values.get("ProductType", "")}
        async with InstallationProxyService(lockdown) as service:
            apps = await service.lookup({"ApplicationType": "Any", "ReturnAttributes": [
                "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString",
                "CFBundleVersion", "ApplicationType", "Container", "Path", "GroupContainers"]})
    rows = []
    for identifier, info in (apps or {}).items():
        if not isinstance(info, dict):
            continue
        name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or identifier
        regions = []
        if info.get("Container"):
            regions.append(region("data", identifier, info["Container"], "Data"))
        for group, path in sorted((info.get("GroupContainers") or {}).items()):
            regions.append(region("group", group, path))
        if info.get("Path"):
            regions.append(region("bundle", identifier, info["Path"], "App"))
        rows.append({"id": identifier, "bundleID": identifier, "name": name,
                     "version": info.get("CFBundleShortVersionString") or info.get("CFBundleVersion", ""),
                     "category": "system" if info.get("ApplicationType") == "System" else "user",
                     "identity": "installed", "regions": regions})
    return rows, device_info


async def catalog(device, include_orphans=True):
    rows, device_info = await installed(device)
    warnings = []
    if include_orphans:
        from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
        from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
        from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
        known = {item["path"] for row in rows for item in row["regions"]}
        known.update(posixpath.dirname(item["path"]) for row in rows for item in row["regions"] if item["kind"] == "bundle")
        try:
            async with UserspaceRsdTunnel(serial=device) as rsd:
                async with DvtProvider(rsd) as dvt, DeviceInfo(dvt) as info:
                    for root, kind in ((container_files.DATA_ROOT, "data"), (container_files.GROUP_ROOT, "group"),
                                       (container_files.BUNDLE_ROOT, "bundle")):
                        try:
                            leaves = await asyncio.wait_for(info.ls(root), 30)
                        except Exception as error:
                            warnings.append("Couldn't list unidentified containers: " + root + " · " + (str(error) or type(error).__name__))
                            continue
                        for leaf in leaves:
                            if "/" in leaf or leaf in (".", ".."):
                                continue
                            path = root + "/" + leaf
                            if path in known:
                                continue
                            key = "orphan:" + hashlib.sha256(path.encode()).hexdigest()[:20]
                            title = {"data": "Leftover data", "group": "Leftover App Group", "bundle": "Leftover app"}[kind]
                            rows.append({"id": key, "bundleID": "", "name": title + " · " + leaf,
                                         "version": "", "category": "orphan", "identity": "unknown",
                                         "regions": [region(kind, leaf, path, title)]})
        except Exception as error:
            warnings.append("Couldn't list unidentified containers: " + (str(error) or type(error).__name__))
        # Preserve inferred identities, without treating a guess as an installed
        # app or merging two different residual UUIDs into one row.
        try:
            known_data = {r["path"] for app in rows if app["identity"] == "installed"
                          for r in app["regions"] if r["kind"] == "data"}
            names = {app["bundleID"]: app["name"] for app in rows if app["bundleID"]}
            inferred = await asyncio.wait_for(container_files.extra_data_rows(device, known_data, names), 45)
            by_path = {r["id"]: r["domainIdentifier"] for r in inferred}
            for app in rows:
                if app["identity"] == "unknown":
                    identifier = by_path.get(app["regions"][0]["path"])
                    if identifier:
                        app["bundleID"] = identifier
                        app["name"] = names.get(identifier, identifier) + " (leftover, estimated)"
                        app["identity"] = "inferred"
        except Exception as error:
            warnings.append("Couldn't look up names for leftover containers: " + (str(error) or type(error).__name__))
    order = {"user": 0, "system": 1, "orphan": 2}
    return {"apps": sorted(rows, key=lambda row: (order[row["category"]], row["name"].casefold())),
            "device": device_info, "warnings": warnings}


async def resolve(device, app_id, region_id=None):
    result = await catalog(device, include_orphans=app_id.startswith("orphan:"))
    app = next((row for row in result["apps"] if row["id"] == app_id), None)
    if not app:
        raise ValueError("Couldn't find the app. Please refresh the app list.")
    if region_id is None:
        return app, result["device"]
    selected = next((row for row in app["regions"] if row["id"] == region_id), None)
    if not selected:
        raise ValueError("Couldn't find the container. Please refresh the app list.")
    return app, selected
