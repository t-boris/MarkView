#!/usr/bin/env python3
"""Preserve mtimes only for tracked build inputs whose content still matches.

Xcode's build database uses source timestamps. A fresh checkout changes those
timestamps even for unchanged files, so restore them from the cached build.
Changed files retain their checkout timestamps and are rebuilt by Xcode.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def build_inputs():
    output = subprocess.check_output([
        "git", "ls-files", "-z", "--", "MarkView", "MarkView.xcodeproj", "project.yml"
    ])
    for name in output.split(b"\0"):
        if name:
            path = os.fsdecode(name)
            if os.path.isfile(path) and not os.path.islink(path):
                yield path


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("save", "restore"):
        sys.exit("Usage: build-cache-mtimes.py save|restore MANIFEST")
    action, manifest = sys.argv[1], Path(sys.argv[2])
    if action == "save":
        entries = {path: [digest(path), os.stat(path).st_mtime_ns] for path in build_inputs()}
        manifest.write_text(json.dumps(entries), encoding="utf-8")
        print(f"Recorded {len(entries)} build input timestamps")
    elif manifest.is_file():
        entries = json.loads(manifest.read_text(encoding="utf-8"))
        count = 0
        for path in build_inputs():
            entry = entries.get(path)
            if entry and digest(path) == entry[0]:
                stat = os.stat(path)
                os.utime(path, ns=(stat.st_atime_ns, entry[1]))
                count += 1
        print(f"Restored timestamps for {count} unchanged build inputs")
    else:
        print("No cached build input timestamps")


if __name__ == "__main__":
    main()
