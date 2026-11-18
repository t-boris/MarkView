#!/usr/bin/env python3
"""Check changed and bounded recompiled sources against the unused-import baseline."""
import argparse
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PREFIXES = ("MarkView/", "Packages/MarkViewCore/Sources/")
BASELINE = ROOT / "tools/lint/swiftlint-unused-import-allowlist.txt"
MAX_COMPILED = 120


def compiled_sources(log_text, root=ROOT):
    """Read per-primary-file Xcode entries; batch summary lines are not source paths."""
    found = set()
    for line in log_text.splitlines():
        parts = line.split(" ", 3)
        if len(parts) != 4 or parts[:2] != ["SwiftCompile", "normal"]:
            continue
        path, marker, _ = parts[3].rpartition(" (in target ")
        if not marker or not path.endswith(".swift"):
            continue
        try:
            relative = pathlib.Path(path).resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            continue
        if relative.startswith(PREFIXES) and (root / relative).is_file():
            found.add(relative)
    return found


def select_sources(changed, compiled, maximum=MAX_COMPILED):
    """Include compiler-selected dependants only when the bounded run can cover them all."""
    changed = set(changed)
    combined = changed | compiled
    if len(combined) > max(maximum, len(changed)):
        return sorted(changed), True
    return sorted(combined), False


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
    compiled = compiled_sources(log.read_text(errors="replace"))
    if not compiled:
        sys.exit("Compiler log contains no app/package SwiftCompile source entries")
    selected, limited = select_sources(selected, compiled)
    if limited:
        print(f"Coverage limited: {len(compiled)} compiled files exceed the bounded analysis budget; "
              "only changed sources will be analyzed", flush=True)
    else:
        print(f"Analyzing {len(selected)} changed or compiler-selected app/package Swift files", flush=True)
    return subprocess.call([str(ROOT / "tools/lint/swiftlint-unused-import-ratchet.py"), "--compiler-log", str(log),
                            "--files", *selected], cwd=ROOT)


if __name__ == "__main__":
    sys.exit(main())
