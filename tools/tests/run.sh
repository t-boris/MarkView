#!/bin/bash
# Manifest-driven test runner for MarkView (AR-44 step 1).
#
# Usage:
#   tools/tests/run.sh --list [--tier pure|gui|live|all] [--all] [--changed [<ref>]]
#   tools/tests/run.sh [--tier pure|gui|live|all] [--all] [--changed [<ref>]] [--suite <name>]... [--dry-run]
set -euo pipefail
cd "$(dirname "$0")/../.."

MANIFEST="tools/tests/manifest.json"
TIER="pure"
CHANGED_MODE=0
CHANGED_REF=""
LIST_ONLY=0
DRY_RUN=0
SUITES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --all) TIER="all"; shift ;;
        --tier) TIER="${2:?--tier requires pure|gui|live|all}"; shift 2 ;;
        --changed)
            CHANGED_MODE=1
            if [ $# -ge 2 ] && [[ "$2" != -* ]]; then
                CHANGED_REF="$2"
                shift 2
            else
                shift
            fi
            ;;
        --suite) SUITES+=("${2:?--suite requires a suite name}"); shift 2 ;;
        *) echo "usage: $0 [--list] [--dry-run] [--all] [--tier pure|gui|live|all] [--changed [<ref>]] [--suite <name>]" >&2; exit 1 ;;
    esac
done

selected=$(python3 - "$MANIFEST" "$TIER" "$CHANGED_MODE" "$CHANGED_REF" "${SUITES[@]:-}" <<'PY'
import json, subprocess, sys
from pathlib import Path

manifest_path, tier, changed_mode, changed_ref = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]
explicit = [s for s in sys.argv[5:] if s]
data = json.loads(Path(manifest_path).read_text())
suites = data.get("suites", [])

if explicit:
    wanted = set(explicit)
    suites = [s for s in suites if s["name"] in wanted or s["script"] in wanted]
elif tier != "all":
    suites = [s for s in suites if s.get("tier") == tier]

if changed_mode:
    if not changed_ref:
        has_origin_main = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", "origin/main"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        ).returncode == 0
        diff_range = "origin/main...HEAD" if has_origin_main else "HEAD"
    elif "..." in changed_ref or ".." in changed_ref:
        diff_range = changed_ref
    else:
        diff_range = f"{changed_ref}...HEAD"
    out = subprocess.check_output(["git", "diff", "--name-only", diff_range], text=True)
    changed = {line.strip() for line in out.splitlines() if line.strip()}
    # Also include working-tree modifications if any
    wt = subprocess.check_output(["git", "status", "--porcelain"], text=True)
    for line in wt.splitlines():
        if len(line) > 3:
            changed.add(line[3:].strip().split(" -> ")[-1].strip('"'))
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

run_script() {
    local s="$1"
    if [ -x "$s" ]; then
        "./$s"
        return $?
    fi
    local first_line=""
    IFS= read -r first_line < "$s" || true
    case "$first_line" in
        "#!"*zsh*) zsh "$s" ;;
        "#!"*python3*) python3 "$s" ;;
        *) bash "$s" ;;
    esac
}

passed=0
failed=0
failed_names=()
while IFS=$'\t' read -r name suite_tier script; do
    [ -n "$script" ] || continue
    echo "▸ [$suite_tier] $name ($script)"
    if run_script "$script"; then
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
