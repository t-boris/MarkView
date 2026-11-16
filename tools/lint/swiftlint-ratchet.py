#!/usr/bin/env python3
"""Fail when a SwiftLint diagnostic count exceeds the recorded baseline."""
import collections
import json
import pathlib
import subprocess
import sys

if sys.argv[1:] not in ([], ["--tighten"]):
    sys.exit("usage: swiftlint-ratchet.py [--tighten]")
tighten = sys.argv[1:] == ["--tighten"]
root = pathlib.Path(__file__).resolve().parents[2]
result = subprocess.run(["swiftlint", "lint", "--quiet", "--reporter", "json"], cwd=root, capture_output=True, text=True)
if result.returncode:
    print(result.stderr, file=sys.stderr)
    sys.exit(result.returncode)
actual = collections.Counter((str(pathlib.Path(item["file"]).relative_to(root)), item["rule_id"])
                             for item in json.loads(result.stdout))
allowed = {}
for line in (root / "tools/lint/swiftlint-allowlist.txt").read_text().splitlines():
    if line and not line.startswith("#"):
        count, path, rule = line.split()
        allowed[(path, rule)] = int(count)
excess = [(key, count, allowed.get(key, 0)) for key, count in actual.items() if count > allowed.get(key, 0)]
for (path, rule), count, limit in sorted(excess):
    print(f"{path}: {rule}: {count} exceeds {limit}", file=sys.stderr)
if excess:
    sys.exit(1)
if tighten:
    lines = ["# Maximum diagnostics by path and rule; counts may only shrink."]
    lines += [f"{count} {path} {rule}" for (path, rule), count in sorted(actual.items())]
    (root / "tools/lint/swiftlint-allowlist.txt").write_text("\n".join(lines) + "\n")
elif actual != allowed:
    sys.exit("SwiftLint baseline has slack; run swiftlint-ratchet.py --tighten")
print(f"SwiftLint: {sum(actual.values())} warnings; baseline {sum(allowed.values())}")
