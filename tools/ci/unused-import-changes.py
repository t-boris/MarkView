#!/usr/bin/env python3
"""Check the changed app and package sources against the unused-import baseline.

Only the changed files: analyzing the files Xcode recompiled because of them (up to 120) did not fit the CI step's 35 minutes
(Boris, 2026-11-27). The full audit (`swiftlint-unused-import-ratchet.py --all`) covers the rest."""
import argparse
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PREFIXES = ("MarkView/", "Packages/MarkViewCore/Sources/")
BASELINE = ROOT / "tools/lint/swiftlint-unused-import-allowlist.txt"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--compiler-log")
    parser.add_argument("--prepare", action="store_true", help="force changed sources into the next compiler log")
    args = parser.parse_args()
    if not args.prepare and not args.compiler_log:
        parser.error("--compiler-log is required unless --prepare is set")
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
        return 0
    if args.prepare:
        for path in selected:
            os.utime(ROOT / path, None)
        print(f"Prepared {len(selected)} changed app/package Swift files for compilation")
        return 0
    log = pathlib.Path(args.compiler_log)
    if not log.is_file():
        sys.exit(f"Compiler log does not exist: {log}")
    print(f"Analyzing {len(selected)} changed app/package Swift files", flush=True)
    return subprocess.call([str(ROOT / "tools/lint/swiftlint-unused-import-ratchet.py"), "--compiler-log", str(log),
                            "--files", *selected], cwd=ROOT)


if __name__ == "__main__":
    sys.exit(main())
