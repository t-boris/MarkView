#!/usr/bin/env python3
"""Balance all pure suites using observed CI durations, with a fallback for new suites."""
import json
import os
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
manifest = json.loads((root / "tools/tests/manifest.json").read_text())
timings = json.loads((root / "tools/ci/pure-suite-seconds.json").read_text())
suites = [suite["name"] for suite in manifest["suites"] if suite["tier"] == "pure"]
if len(set(suites)) != len(suites):
    sys.exit("Duplicate pure suite name in manifest")
if os.environ.get("MARKVIEW_REMOTE_SKIP_DUPLICATE_PURE") == "1":
    required = {"remote-workspace-tests", "remote-relay-settings-tests"}
    missing = required.difference(suites)
    if missing:
        sys.exit("Remote de-duplication requires these pure suites: " + ", ".join(sorted(missing)))
if len(sys.argv) != 2 or sys.argv[1] not in {"0", "1", "2"}:
    sys.exit("usage: pure-test-shards.py 0|1|2")

# Longest-processing-time scheduling: place each suite on the least loaded shard.
# Unmeasured suites get the median observed duration until timings are refreshed.
fallback = sorted(timings.values())[len(timings) // 2]
loads = [0.0, 0.0, 0.0]
shards = [[], [], []]
for name in sorted(suites, key=lambda item: (-timings.get(item, fallback), item)):
    shard = min(range(3), key=lambda item: (loads[item], item))
    shards[shard].append(name)
    loads[shard] += timings.get(name, fallback)
print("\n".join(shards[int(sys.argv[1])]))
