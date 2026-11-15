#!/bin/bash
# Manifest-driven test runner for MarkView (AR-44 step 1).
#
# Usage:
#   tools/tests/run.sh --list [--tier pure|gui|live|all] [--all] [--changed [<ref>]]
#   tools/tests/run.sh [--tier pure|gui|live|all] [--all] [--changed [<ref>]] [--suite <name>]... [--jobs <N>] [--dry-run] [<name>...]
set -euo pipefail
cd "$(dirname "$0")/../.."

MANIFEST="tools/tests/manifest.json"
TIER="pure"
CHANGED_MODE=0
CHANGED_REF=""
LIST_ONLY=0
DRY_RUN=0
JOBS="${MARKVIEW_TEST_JOBS:-}"
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
        --jobs|-j) JOBS="${2:?--jobs requires a positive integer}"; shift 2 ;;
        --jobs=*) JOBS="${1#--jobs=}"; shift ;;
        -*) echo "usage: $0 [--list] [--dry-run] [--all] [--tier pure|gui|live|all] [--changed [<ref>]] [--suite <name>] [--jobs <N>] [<name>...]" >&2; exit 1 ;;
        *) SUITES+=("$1"); shift ;;
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
    known = {s["name"] for s in suites} | {s["script"] for s in suites}
    unknown = [req for req in explicit if req not in known]
    if unknown:
        print(f"Unknown test suite(s): {' '.join(unknown)}", file=sys.stderr)
        sys.exit(2)
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
    weight = len(s.get("sources", []))
    print(f"{s['name']}\t{s['tier']}\t{s['script']}\t{weight}")
PY
)

if [ "$LIST_ONLY" = 1 ] || [ "$DRY_RUN" = 1 ]; then
    if [ -n "$selected" ]; then
        cut -f1-3 <<< "$selected"
    fi
    exit 0
fi

if [ -z "$selected" ]; then
    echo "No test suites selected."
    exit 0
fi

shim_dir=""
cleanup() {
    if [ -n "$shim_dir" ] && [ -d "$shim_dir" ]; then
        rm -rf "$shim_dir"
    fi
}
trap cleanup EXIT

# Compiling one-shot test binaries with -O dominates suite wall time; default to -Onone + shared module cache
# unless MARKVIEW_TEST_SWIFTC_OPT=1 requests optimized test builds.
if [ "${MARKVIEW_TEST_SWIFTC_OPT:-0}" != "1" ]; then
    real_swiftc=$(command -v swiftc || true)
    if [ -n "$real_swiftc" ]; then
        shim_dir=$(mktemp -d "${TMPDIR:-/tmp}/markview-swiftc-shim.XXXXXX")
        mod_cache="${MARKVIEW_TEST_MODULE_CACHE:-${TMPDIR:-/tmp}/markview-test-module-cache}"
        mkdir -p "$mod_cache"
        cat > "$shim_dir/swiftc" <<EOF
#!/bin/bash
args=()
has_mod_cache=0
for a in "\$@"; do
    case "\$a" in
        -O) continue ;;
        -module-cache-path) has_mod_cache=1 ;;
    esac
    args+=("\$a")
done
if [ "\$has_mod_cache" = 0 ]; then
    args=("-module-cache-path" "$mod_cache" "\${args[@]}")
fi
exec "$real_swiftc" "\${args[@]}"
EOF
        chmod +x "$shim_dir/swiftc"
        export PATH="$shim_dir:$PATH"
    fi
fi

python3 - "$selected" "$JOBS" <<'PY'
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

raw_selected, raw_jobs = sys.argv[1], sys.argv[2]
items = []
for line in raw_selected.splitlines():
    if not line.strip():
        continue
    name, suite_tier, script, weight = line.split("\t")
    items.append((int(weight), name, suite_tier, script))

# Start multi-file heavy suites first so the parallel schedule does not end on a long tail.
items.sort(key=lambda item: (-item[0], item[1]))

if raw_jobs:
    try:
        workers = max(1, int(raw_jobs))
    except ValueError:
        print(f"Invalid --jobs value: {raw_jobs}", file=sys.stderr)
        sys.exit(2)
else:
    cpus = os.cpu_count() or 4
    cap = 6 if os.environ.get("CI") == "true" else 8
    workers = max(1, min(cpus, cap, len(items)))

def run_suite(item):
    _, name, suite_tier, script = item
    if os.access(script, os.X_OK):
        cmd = [f"./{script}"]
    else:
        first_line = ""
        try:
            with open(script, "r", encoding="utf-8", errors="ignore") as f:
                first_line = f.readline()
        except OSError:
            pass
        if "zsh" in first_line:
            cmd = ["zsh", script]
        elif "python3" in first_line:
            cmd = ["python3", script]
        else:
            cmd = ["bash", script]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
        return name, suite_tier, script, proc.returncode, proc.stdout
    except subprocess.TimeoutExpired as exc:
        partial = exc.stdout.decode("utf-8", errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        return name, suite_tier, script, 124, partial + "\nTIMED OUT after 180s\n"

passed = 0
failed = 0
failed_names = []

with ThreadPoolExecutor(max_workers=workers) as executor:
    futures = [executor.submit(run_suite, item) for item in items]
    for fut in as_completed(futures):
        name, suite_tier, script, rc, output = fut.result()
        print(f"▸ [{suite_tier}] {name} ({script})", flush=True)
        if output:
            sys.stdout.write(output if output.endswith("\n") else output + "\n")
            sys.stdout.flush()
        if rc == 0:
            passed += 1
        else:
            failed += 1
            failed_names.append(name)

print(f"\nSuites summary: {passed} passed, {failed} failed", flush=True)
if failed > 0:
    print(f"Failed suites: {' '.join(sorted(failed_names))}", file=sys.stderr, flush=True)
    sys.exit(1)
PY
