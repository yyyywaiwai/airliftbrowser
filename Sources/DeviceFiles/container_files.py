#!/usr/bin/env python3
"""List CoreDevice-accessible app and app-group containers as JSON."""
import argparse
import json
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


def apps(device):
    return run("device", "info", "apps", "--device", device,
               "--include-all-apps", "--include-container-paths",
               "--include-app-group-identifiers")["apps"]


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
                row["subtitle"] = f"{app.get('name', '')} · {app['bundleIdentifier']}"
    return sorted(rows.values(), key=lambda row: (row["subtitle"].casefold(), row["name"]))


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
            "subtitle": f"{app.get('name', identifier)} · {identifier}",
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
    installed = apps(device)
    bundles = bundle_rows(installed)
    if path == BUNDLE_ROOT:
        return sorted(bundles, key=lambda row: (row["subtitle"].casefold(), row["name"]))
    if posixpath.dirname(path) == BUNDLE_ROOT:
        return [{**row, "id": row["bundlePath"], "name": posixpath.basename(row["bundlePath"])}
                for row in bundles if row["id"] == path]
    if path == DATA_ROOT:
        return container_roots(installed)
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
            raise ValueError("このコンテナはCoreDeviceから参照できません。")
        relative = path[len(base):].lstrip("/")
        return list_domain(device, domain, row["domainIdentifier"], base, relative)
    raise ValueError("このディレクトリには動的な列挙サービスがありません。")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True)
    parser.add_argument("--path", required=True)
    args = parser.parse_args()
    try:
        result = {"ok": True, "entries": browse(args.device, args.path)}
    except Exception as error:
        result = {"ok": False, "error": str(error)}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
