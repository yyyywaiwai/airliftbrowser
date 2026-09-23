"""Shared, disk-backed state for the app-container helper."""
import hashlib
from contextlib import contextmanager
import json
import os
from pathlib import Path
import time
import uuid
import shutil

# AFC reads support 4 MiB per request. Keep memory bounded without creating
# split files or repeatedly opening a connection for each 128 MiB segment.
CHUNK = 4 * 1024 * 1024
HOME = Path(os.environ.get("AIRLIFT_LIBRARY", Path.home() / "Library/Application Support/Airlift Browser"))
BACKUPS = HOME / "Backups"
JOURNALS = HOME / "Operations"
MANIFEST = "Manifest.json"
MANAGED_NAMES = {".com.apple.mobile_container_manager.metadata.plist"}


class Cancelled(Exception):
    pass


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".new")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


@contextmanager
def download_destination(destination):
    """Publish only a complete download; leave an existing destination intact."""
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise ValueError("Something already exists at this location. Choose a different name.")
    temporary = destination.with_name(".airlift-download-" + str(uuid.uuid4()))
    try:
        yield temporary
        if destination.exists() or destination.is_symlink():
            raise ValueError("An item with the same name appeared while saving. Choose a different name.")
        os.rename(temporary, destination)
    finally:
        if temporary.is_symlink() or temporary.is_file():
            temporary.unlink()
        elif temporary.exists():
            shutil.rmtree(temporary)


def relative(value):
    if not isinstance(value, str) or "\0" in value or value.startswith("/"):
        raise ValueError("Invalid path.")
    if value and any(part in ("", ".", "..") for part in value.split("/")):
        raise ValueError("Invalid path.")
    return value


def child(root, value, allow_leaf_link=False):
    """Resolve beneath a root without ever following a payload symlink."""
    root = Path(root)
    cursor = root
    parts = relative(value).split("/") if value else []
    if root.is_symlink():
        raise ValueError("The container's top folder can't be a link.")
    for index, part in enumerate(parts):
        cursor = cursor / part
        if cursor.is_symlink() and not (allow_leaf_link and index == len(parts) - 1):
            raise ValueError("Actions through links aren't supported.")
    return cursor


def sha256(path, reporter=None):
    digest = hashlib.sha256()
    size = Path(path).stat().st_size
    completed = 0
    with Path(path).open("rb") as stream:
        while data := stream.read(CHUNK):
            digest.update(data)
            completed += len(data)
            if reporter:
                reporter.advance(len(data))
                reporter.progress("Verifying on Mac: " + Path(path).name, completed, size, phase="verify-local")
    return digest.hexdigest()


class Reporter:
    def __init__(self, cancel_path=None):
        self.cancel_path = Path(cancel_path) if cancel_path else None
        self.last = 0
        self.region = None
        self.region_index = None
        self.region_count = None
        self.steps = []
        self.active_step = None

    def plan(self, steps):
        self.steps = [{"id": key, "title": title, "state": "pending", "completed": 0,
                       "total": None} for key, title in steps]

    def begin(self, key, total=None, cancellable=True):
        self.active_step = next(step for step in self.steps if step["id"] == key)
        self.active_step.update(state="running", completed=0, total=total)
        self.progress(self.active_step["title"], force=True, cancellable=cancellable)

    def advance(self, count):
        if self.active_step and self.active_step["total"] is not None:
            self.active_step["completed"] += count

    def end(self, state="complete"):
        if self.active_step:
            title = self.active_step["title"]
            self.active_step["state"] = state
            self.active_step = None
            self.progress(title + (": done" if state == "complete" else ": stopped"), force=True, cancellable=False)

    def skip(self, key):
        step = next(step for step in self.steps if step["id"] == key)
        step["state"] = "skipped"
        self.progress("Skipped: " + step["title"], force=True)

    def fail_remaining(self, prefix):
        for step in self.steps:
            if step["id"].startswith(prefix) and step["state"] in ("pending", "running"):
                step["state"] = "failed"
        self.active_step = None

    def set_region(self, name, index, count):
        self.region, self.region_index, self.region_count = name, index, count

    def check(self):
        if self.cancel_path and self.cancel_path.exists():
            raise Cancelled("Cancelled. Anything temporarily moved on the device will be put back before finishing.")

    def progress(self, message, completed=None, total=None, force=False, *, phase=None, chunk_size=None, cancellable=True):
        if cancellable:
            self.check()
        now = time.monotonic()
        if force or now - self.last > 0.2:
            print(json.dumps({"event": "progress", "message": message, "phase": phase,
                              "completed": completed, "total": total,
                               "region": self.region, "regionIndex": self.region_index, "regionCount": self.region_count,
                              "steps": self.steps or None,
                              "chunkSize": chunk_size,
                              "chunkIndex": (completed + chunk_size - 1) // chunk_size if chunk_size and completed is not None else None,
                              "chunkCount": (total + chunk_size - 1) // chunk_size if chunk_size and total is not None else None}, ensure_ascii=False), flush=True)
            self.last = now
