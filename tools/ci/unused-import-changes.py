#!/usr/bin/env python3
"""Check changed app/package sources against the audited unused-import baseline."""
import argparse
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PREFIXES = ("MarkView/", "Packages/MarkViewCore/Sources/")
BASELINE = ROOT / "tools/lint/swiftlint-unused-import-allowlist.txt"

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--base", required=True)
parser.add_argument("--compiler-log", required=True)
args = parser.parse_args()
valid = subprocess.run(["git", "cat-file", "-e", args.base + "^{commit}"], cwd=ROOT, capture_output=True)
if valid.returncode:
    sys.exit(f"Cannot resolve comparison commit {args.base!r}")
result = subprocess.run(["git", "diff", "--no-renames", "--name-only", "-z", args.base, "HEAD", "--", *PREFIXES],
                        cwd=ROOT, capture_output=True, check=True)
changed = [p for p in result.stdout.decode().split("\0") if p.endswith(".swift") and p.startswith(PREFIXES)]
allowed = {line.split(maxsplit=1)[1] for line in BASELINE.read_text().splitlines() if line and not line.startswith("#")}
deleted = [p for p in changed if not (ROOT / p).is_file() and p in allowed]
if deleted:
    sys.exit("Remove deleted source files from the unused-import baseline: " + ", ".join(deleted))
selected = [p for p in changed if (ROOT / p).is_file()]
if not selected:
    print("No changed app or package Swift files to analyze")
    sys.exit(0)
print(f"Analyzing {len(selected)} changed app/package Swift files", flush=True)
sys.exit(subprocess.call([str(ROOT / "tools/lint/swiftlint-unused-import-ratchet.py"), "--compiler-log", args.compiler_log,
                          "--files", *selected], cwd=ROOT))
