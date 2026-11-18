#!/bin/bash
# Manifest-driven test runner for MarkView (AR-44 step 1, FU-27).
#
# Usage:
#   tools/tests/run.sh --list [--tier pure|gui|live|all] [--all] [--changed [<ref>]]
#   tools/tests/run.sh [--tier pure|gui|live|all] [--all] [--changed [<ref>]] [--suite <name>]... [--jobs <N>] [--dry-run] [<name>...]
#
# Every suite runs in its own process group, so the whole group (swiftc, test binaries, probe apps, background helpers)
# is killed when the suite times out, when the suite ends and leaves processes behind, and when this runner is
# interrupted. The time limit comes from the suite's optional "timeoutSeconds" in manifest.json, else from its tier:
# pure 180 s, gui 600 s, live 1800 s.
#
# Exit status: 0 all selected suites passed (or `--changed` found no changed file at all); 1 a suite failed or timed out,
# or a usage error; 2 an unknown suite name; 3 `--changed` selected nothing although files changed (or git could not tell).
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
USAGE="usage: $0 [--list] [--dry-run] [--all] [--tier pure|gui|live|all] [--changed [<ref>]] [--suite <name>] [--jobs <N>] [<name>...]"

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
        -*) echo "$USAGE" >&2; exit 1 ;;
        *) SUITES+=("$1"); shift ;;
    esac
done
case "$TIER" in
    pure|gui|live|all) ;;
    *) echo "Unknown tier: $TIER" >&2; echo "$USAGE" >&2; exit 1 ;;
esac

selected=$(python3 - "$MANIFEST" "$TIER" "$CHANGED_MODE" "$CHANGED_REF" "$USAGE" "${SUITES[@]:-}" <<'PY'
import json, subprocess, sys
from pathlib import Path

manifest_path, tier, changed_mode, changed_ref, usage = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4], sys.argv[5]
explicit = [s for s in sys.argv[6:] if s]
data = json.loads(Path(manifest_path).read_text())
suites = data.get("suites", [])

TIER_TIMEOUTS = {"pure": 180, "gui": 600, "live": 1800}

def timeout_of(suite):
    declared = suite.get("timeoutSeconds")
    if declared is None:
        return TIER_TIMEOUTS.get(suite.get("tier"), 180)
    if isinstance(declared, bool) or not isinstance(declared, int) or declared <= 0:
        print(f"Suite {suite['name']}: timeoutSeconds must be a positive integer, not {declared!r}", file=sys.stderr)
        sys.exit(1)
    return declared

for s in suites:
    timeout_of(s)

if explicit:
    known = {s["name"] for s in suites} | {s["script"] for s in suites}
    unknown = [req for req in explicit if req not in known]
    if unknown:
        print(f"Unknown test suite(s): {' '.join(unknown)}", file=sys.stderr)
        sys.exit(2)
    wanted = set(explicit)
    suites = [s for s in suites if s["name"] in wanted or s["script"] in wanted]
in_tier = suites if explicit or tier == "all" else [s for s in suites if s.get("tier") == tier]

def changed_files():
    """The files git reports as changed, or None (with a message) when git cannot tell."""
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
    diff = subprocess.run(["git", "diff", "--name-only", diff_range], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    status = subprocess.run(["git", "status", "--porcelain", "--untracked-files=all"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if diff.returncode != 0 or status.returncode != 0:
        detail = (diff.stderr or status.stderr).strip() or "git failed"
        print(f"--changed: git could not list the changed files ({diff_range}): {detail}", file=sys.stderr)
        return None
    changed = {line.strip() for line in diff.stdout.splitlines() if line.strip()}
    # Also include working-tree modifications if any
    for line in status.stdout.splitlines():
        if len(line) > 3:
            changed.add(line[3:].strip().split(" -> ")[-1].strip('"'))
    return changed

def covering(candidates, changed):
    changed_basenames = {Path(p).name for p in changed}
    found = []
    for s in candidates:
        src_set = set(s.get("sources", [])) | {s["script"]}
        src_basenames = {Path(p).name for p in src_set}
        if (src_set & changed) or (src_basenames & changed_basenames):
            found.append(s)
    return found

if changed_mode:
    changed = changed_files()
    if changed is None:
        print(usage, file=sys.stderr)
        sys.exit(3)
    if not changed:
        print("No changed files: git reports a clean tree, so no test suites are selected.", file=sys.stderr)
        suites = []
    else:
        suites = covering(in_tier, changed)
        if not suites:
            elsewhere = covering(data.get("suites", []), changed)
            listed = ", ".join(sorted(changed)[:5]) + (", ..." if len(changed) > 5 else "")
            if elsewhere and not explicit:
                names = " ".join(s["name"] for s in elsewhere)
                print(f"--changed: {len(changed)} changed file(s) ({listed}) are covered only by suites outside tier '{tier}': {names}.", file=sys.stderr)
            else:
                print(f"--changed: {len(changed)} changed file(s) ({listed}) match no selected suite's sources, so nothing was run.", file=sys.stderr)
            print("Name the suites to run, pick --tier gui|live|all, or add the files to a suite's sources in tools/tests/manifest.json.", file=sys.stderr)
            print(usage, file=sys.stderr)
            sys.exit(3)
else:
    suites = in_tier

for s in suites:
    weight = len(s.get("sources", []))
    print(f"{s['name']}\t{s['tier']}\t{s['script']}\t{weight}\t{timeout_of(s)}")
PY
)

if [ "$LIST_ONLY" = 1 ] || [ "$DRY_RUN" = 1 ]; then
    if [ -n "$selected" ]; then
        # name, tier, script, time limit in seconds
        cut -f1-3,5 <<< "$selected"
    fi
    exit 0
fi

if [ -z "$selected" ]; then
    echo "No test suites selected."
    exit 0
fi

# Compiling one-shot test binaries with -O dominates suite wall time; default to -Onone + shared module cache
# unless MARKVIEW_TEST_SWIFTC_OPT=1 requests optimized test builds. The runner removes the shim when it ends.
shim_dir=""
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

# The runner becomes the Python process (no shell in between), so a signal sent to it reaches the code that stops the suites.
export MARKVIEW_RUN_SHIM_DIR="$shim_dir"
exec python3 - "$selected" "$JOBS" <<'PY'
import atexit
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

raw_selected, raw_jobs = sys.argv[1], sys.argv[2]
GRACE_SECONDS = 3   # between SIGTERM and SIGKILL

shim_dir = os.environ.get("MARKVIEW_RUN_SHIM_DIR", "")
if shim_dir:
    atexit.register(shutil.rmtree, shim_dir, True)

items = []
for line in raw_selected.splitlines():
    if not line.strip():
        continue
    name, suite_tier, script, weight, timeout = line.split("\t")
    items.append((int(weight), name, suite_tier, script, int(timeout)))

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

live_groups = set()
live_lock = threading.Lock()
aborted = threading.Event()

def signal_group(pgid, signum):
    try:
        os.killpg(pgid, signum)
        return True
    except (ProcessLookupError, PermissionError):
        return False

def stop_everything(signum, _frame):
    """The runner was interrupted: stop every suite's group, then leave."""
    aborted.set()
    with live_lock:
        groups = list(live_groups)
    for pgid in groups:
        signal_group(pgid, signal.SIGTERM)
    deadline = time.time() + GRACE_SECONDS
    while time.time() < deadline and any(signal_group(pgid, 0) for pgid in groups):
        time.sleep(0.1)
    for pgid in groups:
        signal_group(pgid, signal.SIGKILL)
    if shim_dir:
        shutil.rmtree(shim_dir, True)
    os._exit(128 + signum)

for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(signum, stop_everything)

def command_for(script):
    path = os.path.abspath(script)
    try:
        executable = bool(os.stat(path).st_mode & 0o111) and os.access(path, os.X_OK)
    except OSError:
        executable = False
    if executable:
        return [path]
    first_line = ""
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            first_line = f.readline()
    except OSError:
        pass
    if "zsh" in first_line:
        return ["zsh", path]
    if "python3" in first_line:
        return ["python3", path]
    return ["bash", path]

def run_suite(item):
    _, name, suite_tier, script, limit = item
    if aborted.is_set():
        return name, suite_tier, script, 130, "Skipped: the runner was interrupted.\n", False, 0.0
    started = time.time()
    # Its own session and process group: everything the suite starts stays in it and can be stopped as one.
    proc = subprocess.Popen(command_for(script), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            start_new_session=True)
    pgid = proc.pid
    with live_lock:
        live_groups.add(pgid)
    chunks = []
    def drain():
        pending = b""
        while True:
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                return
            chunks.append(chunk)
            if name in {"ui-studio-session-tests", "research-map-web-tests"}:
                # These static stage labels make a stuck hosted scenario visible in CI
                # without interleaving the suite's complete buffered output.
                lines = (pending + chunk).split(b"\n")
                pending = lines.pop()[-4096:]
                for line in lines:
                    if line.startswith(b"--  ") and len(line) <= 256:
                        print(f"▸ [{suite_tier}] {name}: {line[4:].decode('utf-8', errors='replace')}", flush=True)
                    elif name == "research-map-web-tests" and line.startswith(b"research-map WebKit: ") and len(line) <= 256:
                        print(f"▸ [{suite_tier}] {name}: {line.decode('utf-8', errors='replace')}", flush=True)
    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    notes = []
    timed_out = False
    try:
        try:
            code = proc.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            timed_out = True
            signal_group(pgid, signal.SIGTERM)
            try:
                proc.wait(timeout=GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                pass
            signal_group(pgid, signal.SIGKILL)
            proc.wait()
            code = 124
            notes.append(f"TIMED OUT after {limit}s: the suite's process group was killed")
        else:
            # The suite has ended; whatever it left running in its group has no business running on.
            if signal_group(pgid, signal.SIGKILL):
                notes.append("the suite left background processes running; its process group was killed")
        reader.join(timeout=5)
    finally:
        with live_lock:
            live_groups.discard(pgid)
        try:
            proc.stdout.close()
        except OSError:
            pass
    output = b"".join(chunks).decode("utf-8", errors="replace")
    if notes:
        output += ("" if output.endswith("\n") or not output else "\n") + "\n".join(notes) + "\n"
    return name, suite_tier, script, code, output, timed_out, time.time() - started

passed = 0
failed = 0
failed_names = []
timed_out_names = []

executor = ThreadPoolExecutor(max_workers=workers)
try:
    futures = [executor.submit(run_suite, item) for item in items]
    for fut in as_completed(futures):
        name, suite_tier, script, rc, output, timed_out, seconds = fut.result()
        print(f"▸ [{suite_tier}] {name} ({script}) {seconds:.1f}s", flush=True)
        if output:
            sys.stdout.write(output if output.endswith("\n") else output + "\n")
            sys.stdout.flush()
        if rc == 0:
            passed += 1
        else:
            failed += 1
            failed_names.append(name)
            if timed_out:
                timed_out_names.append(name)
finally:
    executor.shutdown(wait=True, cancel_futures=True)

print(f"\nSuites summary: {passed} passed, {failed} failed", flush=True)
if failed > 0:
    print(f"Failed suites: {' '.join(sorted(failed_names))}", file=sys.stderr, flush=True)
    if timed_out_names:
        print(f"Timed out suites: {' '.join(sorted(timed_out_names))}", file=sys.stderr, flush=True)
    sys.exit(1)
PY
