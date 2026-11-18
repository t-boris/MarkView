#!/usr/bin/env python3
"""Check analyzer diagnostics against a per-file baseline without accepting partial analysis."""
import argparse
import concurrent.futures
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASELINE = ROOT / "tools/lint/swiftlint-unused-import-allowlist.txt"
SOURCE_ROOTS = (ROOT / "MarkView", ROOT / "Packages/MarkViewCore/Sources")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--compiler-log", required=True)
parser.add_argument("--baseline", type=pathlib.Path, default=BASELINE)
selection = parser.add_mutually_exclusive_group(required=True)
selection.add_argument("--all", action="store_true")
selection.add_argument("--files", nargs="+")
parser.add_argument("--jobs", type=int, default=2)
parser.add_argument("--timeout", type=int, default=300, help="maximum seconds per file")
parser.add_argument("--tighten", action="store_true")
args = parser.parse_args()
if args.jobs < 1 or args.timeout < 1:
    parser.error("jobs and timeout must be positive")
log = pathlib.Path(args.compiler_log).resolve()
if not log.is_file():
    sys.exit(f"Compiler log does not exist: {log}")

sources = {p.resolve() for folder in SOURCE_ROOTS for p in folder.rglob("*.swift")}
if args.all:
    selected = sources
else:
    selected = {(ROOT / p).resolve() for p in args.files}
    if not selected <= sources:
        sys.exit("Not an existing app or package source: " + ", ".join(map(str, sorted(selected - sources))))
if not selected:
    sys.exit("No Swift source files selected")

allowed = {}
for line in args.baseline.read_text().splitlines():
    if line and not line.startswith("#"):
        parts = line.split(maxsplit=1)
        if len(parts) != 2 or not parts[0].isdigit() or int(parts[0]) < 1 or parts[1] in allowed:
            sys.exit(f"Malformed or duplicate unused-import baseline entry: {line}")
        count, path = parts
        allowed[path] = int(count)


def analyze(path):
    relative = str(path.relative_to(ROOT))
    try:
        result = subprocess.run(
            ["swiftlint", "analyze", "--only-rule", "unused_import", "--compiler-log-path", str(log),
             "--reporter", "json", str(path)], cwd=ROOT, capture_output=True, text=True, timeout=args.timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        return relative, None, str(error)
    match = re.search(r"Done analyzing!.* in (\d+) files?\.", result.stderr)
    if result.returncode or not match or int(match.group(1)) != 1:
        return relative, None, f"exit {result.returncode}; expected one analyzed file: {result.stderr[-500:]}"
    try:
        diagnostics = json.loads(result.stdout)
        if not isinstance(diagnostics, list) or any(
            item.get("rule_id") != "unused_import" or pathlib.Path(item.get("file", "")).resolve() != path
            for item in diagnostics
        ):
            raise ValueError("unexpected diagnostic rule or file")
    except (ValueError, TypeError, AttributeError) as error:
        return relative, None, str(error)
    return relative, len(diagnostics), None


actual = {}
failed = False
with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
    futures = [pool.submit(analyze, path) for path in sorted(selected)]
    for completed, future in enumerate(concurrent.futures.as_completed(futures), start=1):
        path, count, error = future.result()
        if error:
            print(f"{path}: analyzer failed: {error}", file=sys.stderr, flush=True)
            failed = True
        else:
            actual[path] = count
            print(f"Analyzed {completed}/{len(selected)}: {path}", flush=True)
if failed:
    sys.exit(1)

for path, count in sorted(actual.items()):
    limit = allowed.get(path, 0)
    if count > limit:
        print(f"{path}: unused_import: {count} exceeds {limit}", file=sys.stderr)
        failed = True
if failed:
    sys.exit(1)
if args.tighten:
    for path, count in actual.items():
        if count:
            allowed[path] = count
        else:
            allowed.pop(path, None)
    if args.all:
        allowed = {path: count for path, count in allowed.items() if ROOT / path in sources}
    lines = ["# Maximum unused_import diagnostics by path; counts may only shrink."]
    lines.extend(f"{count} {path}" for path, count in sorted(allowed.items()))
    args.baseline.write_text("\n".join(lines) + "\n")
elif any(count != allowed.get(path, 0) for path, count in actual.items()):
    sys.exit("Unused-import baseline has slack in the selected files; rerun with --tighten")
elif args.all and any(ROOT / path not in sources for path in allowed):
    sys.exit("Unused-import baseline names deleted files; rerun --all with --tighten")
print(f"Unused imports: {sum(actual.values())} warnings in {len(actual)} analyzed files")
