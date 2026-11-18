#!/usr/bin/env python3
"""Partition Xcode's enumerated editor XCTest methods without omitting any."""
import json
from pathlib import Path
import sys

if len(sys.argv) != 4:
    sys.exit("usage: editor-test-shards.py ENUMERATION SHARD COUNT")
path, shard, count = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
if count < 1 or not 0 <= shard < count:
    sys.exit("Invalid editor shard")
data = json.loads(path.read_text())
if data.get("errors") or not data.get("values"):
    sys.exit("Xcode test enumeration failed or returned no test plans")
prefix = "MarkViewHostedTests/EditorHostTests/"
tests = [test["identifier"] for plan in data["values"] for test in plan.get("enabledTests", [])]
if len(tests) < count or len(tests) != len(set(tests)) or any(not name.startswith(prefix) for name in tests):
    sys.exit("Editor enumeration is empty, duplicated, or contains an unexpected test")
selected = sorted(tests)[shard::count]
if not selected:
    sys.exit("Editor shard is empty")
print("\n".join(selected))
