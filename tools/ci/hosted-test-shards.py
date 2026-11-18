#!/usr/bin/env python3
"""Partition Xcode's enumerated hosted XCTest methods without omitting any."""
import json
import math
from pathlib import Path
import sys

if len(sys.argv) not in (4, 5):
    sys.exit("usage: hosted-test-shards.py ENUMERATION SHARD COUNT [editor|general]")
path, shard, count = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
group = sys.argv[4] if len(sys.argv) == 5 else "editor"
if count < 1 or not 0 <= shard < count:
    sys.exit("Invalid hosted test shard")
if group not in {"editor", "general"}:
    sys.exit("Invalid hosted test group")
data = json.loads(path.read_text())
if data.get("errors") or not data.get("values"):
    sys.exit("Xcode test enumeration failed or returned no test plans")
tests = [test["identifier"] for plan in data["values"] for test in plan.get("enabledTests", [])]
prefix = "MarkViewHostedTests/EditorHostTests/"
invalid = any(not name.startswith(prefix) for name in tests) if group == "editor" else any(
    not name.startswith("MarkViewHostedTests/") or name.startswith(prefix)
    or len(name.split("/")) < 3 or name.split("/")[1].startswith("Manual") for name in tests
)
if len(tests) < count or len(tests) != len(set(tests)) or invalid:
    sys.exit("Hosted test enumeration is empty, duplicated, or contains an unexpected test")
if group == "general":
    # Historical GitHub ARM timings balance slow WebKit tests; unknown tests
    # still run and receive a conservative default until timings are refreshed.
    timings = json.loads(Path(__file__).with_name("hosted-test-seconds.json").read_text())
    if not isinstance(timings, dict) or any(
        not isinstance(key, str) or isinstance(value, bool)
        or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0
        for key, value in timings.items()
    ):
        sys.exit("Invalid hosted test timings")
    partitions = [[] for _ in range(count)]
    loads = [0.0] * count
    for name in sorted(tests, key=lambda name: (-timings.get(name, 1.0), name)):
        index = min(range(count), key=lambda index: (loads[index], index))
        partitions[index].append(name)
        loads[index] += timings.get(name, 1.0)
    selected = sorted(partitions[shard])
else:
    selected = sorted(tests)[shard::count]
if not selected:
    sys.exit("Hosted test shard is empty")
print("\n".join(selected))
