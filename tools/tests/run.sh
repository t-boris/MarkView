#!/bin/bash
# Manifest-driven test runner for MarkView (AR-44 step 1).
#
# Usage:
#   tools/tests/run.sh --list [--tier pure|gui|live|all] [--changed <ref>]
#   tools/tests/run.sh [--tier pure|gui|live|all] [--changed <ref>] [--suite <name>]... [--dry-run]
set -euo pipefail
cd "$(dirname "$0")/../.."

MANIFEST="tools/tests/manifest.json"
TIER="pure"
CHANGED_REF=""
LIST_ONLY=0
DRY_RUN=0
SUITES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --tier) TIER="${2:?--tier requires pure|gui|live|all}"; shift 2 ;;
        --changed) CHANGED_REF="${2:?--changed requires a git ref}"; shift 2 ;;
        --suite) SUITES+=("${2:?--suite requires a suite name}"); shift 2 ;;
        *) echo "usage: $0 [--list] [--dry-run] [--tier pure|gui|live|all] [--changed <ref>] [--suite <name>]" >&2; exit 1 ;;
    esac
done

selected=$(python3 - "$MANIFEST" "$TIER" "$CHANGED_REF" "${SUITES[@]:-}" <<'PY'
import json, subprocess, sys
from pathlib import Path

manifest_path, tier, changed_ref = sys.argv[1], sys.argv[2], sys.argv[3]
explicit = [s for s in sys.argv[4:] if s]
data = json.loads(Path(manifest_path).read_text())
suites = data.get("suites", [])

if explicit:
    wanted = set(explicit)
    suites = [s for s in suites if s["name"] in wanted or s["script"] in wanted]
elif tier != "all":
    suites = [s for s in suites if s.get("tier") == tier]

if changed_ref:
    out = subprocess.check_output(["git", "diff", "--name-only", f"{changed_ref}...HEAD"], text=True)
    changed = {line.strip() for line in out.splitlines() if line.strip()}
    # Also include working-tree modifications if any
    wt = subprocess.check_output(["git", " status", "--porcelain"] if False else ["git", "status", "--porcelain"], text=True)
    for line in wt.splitlines():
        if len(line) > 3:
            changed.add(line[3:].strip())
    if changed:
        changed_basenames = {Path(p).name for p in changed}
        filtered = []
        for s in suites:
            src_set = set(s.get("sources", [])) | {s["script"]}
            src_basenames = {Path(p).name for p in src_set}
            if (src_set & changed) or (src_basenames & changed_basenames):
                filtered.append(s)
        suites = filtered
    else:
        suites = []

for s in suites:
    print(f"{s['name']}\t{s['tier']}\t{s['script']}")
PY
)

if [ "$LIST_ONLY" = 1 ] || [ "$DRY_RUN" = 1 ]; then
    if [ -n "$selected" ]; then
        echo "$selected"
    fi
    exit 0
fi

if [ -z "$selected" ]; then
    echo "No test suites selected."
    exit 0
fi

passed=0
failed=0
failed_names=()
while IFS=$'\t' read -r name suite_tier script; do
    [ -n "$script" ] || continue
    echo "▸ [$suite_tier] $name ($script)"
    if bash "$script"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        failed_names+=("$name")
    fi
done <<< "$selected"

echo ""
echo "Suites summary: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    echo "Failed suites: ${failed_names[*]}" >&2
    exit 1
fi
