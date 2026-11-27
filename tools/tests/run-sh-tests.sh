#!/bin/bash
# The test runner itself (tools/tests/run.sh, FU-27), run against a tiny fake repository and manifest in a temporary
# folder: per-tier and per-suite time limits, the whole process group of a hanging suite being killed (a background
# sleeper must be gone), background processes a passing suite leaves behind, an interrupted runner stopping its suites,
# exit codes, and `--changed` never reporting success for files it did not test.
#   tools/tests/run-sh-tests.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
real_runner="$PWD/tools/tests/run.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/markview-run-sh-tests.XXXXXX")
cleanup() {
    for pidfile in "$work"/pids/*; do
        [ -f "$pidfile" ] && kill -9 "$(cat "$pidfile")" 2>/dev/null
    done
    rm -rf "$work"
}
trap cleanup EXIT

failures=0
check() {
    if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; failures=$((failures + 1)); fi
}
# The sleeper recorded in pids/<name> is gone (it may take a moment to be reaped).
gone() {
    local pid deadline=$((SECONDS + 5))
    pid=$(cat "$work/pids/$1" 2>/dev/null) || return 1
    [ -n "$pid" ] || return 1
    while kill -0 "$pid" 2>/dev/null; do
        [ $SECONDS -lt $deadline ] || return 1
        sleep 0.1
    done
    return 0
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
export MARKVIEW_TEST_SWIFTC_OPT=1
export FAKE_PIDS="$work/pids"
mkdir -p "$FAKE_PIDS"

repo="$work/repo"
mkdir -p "$repo/tools/tests" "$repo/src" "$repo/docs"
cp "$real_runner" "$repo/tools/tests/run.sh"
suite() { printf '#!/bin/bash\n%s\n' "$2" > "$repo/tools/tests/$1.sh"; chmod +x "$repo/tools/tests/$1.sh"; }
suite ok 'echo fine'
suite fail 'echo broken; exit 1'
# A hanging suite with background helpers at three depths, all in its process group.
suite hang 'sleep 300 & echo $! > "$FAKE_PIDS/hang-1"
( sleep 300 ) &
bash -c "sleep 300 & echo \$! > \"$FAKE_PIDS/hang-2\"; wait" &
echo started; wait'
# A suite that ignores SIGTERM (and so does its sleeper): only SIGKILL stops it.
suite stubborn 'trap "" TERM
sleep 300 & echo $! > "$FAKE_PIDS/stubborn-1"
echo started; while true; do sleep 1; done'
# A suite that passes but leaves a background process holding its output.
suite leaky 'sleep 300 & echo $! > "$FAKE_PIDS/leaky-1"
echo done'
suite slow-gui 'sleep 3; echo slow but within the gui limit'
suite slow-pure 'sleep 30'
suite long 'sleep 300 & echo $! > "$FAKE_PIDS/long-1"
echo started; wait'
suite gui-only 'echo gui'
suite ui-studio-session-tests 'printf "%s" "--  fixture"; sleep 0.1; echo " stage"; sleep 3; echo complete'
suite research-map-web-tests 'printf "%s" "research-map WebKit: 50"; sleep 0.1; echo " checks"; sleep 3; echo complete'
python3 - "$repo/tools/tests/manifest.json" <<'PY'
import json, sys
def s(name, tier="pure", sources=None, **extra):
    return {"name": name, "script": f"tools/tests/{name}.sh", "tier": tier, "sources": sources or [f"src/{name}.txt"], **extra}
suites = [
    s("ok", sources=["src/a.txt"]), s("fail"),
    s("hang", timeoutSeconds=2), s("stubborn", timeoutSeconds=2), s("leaky"),
    s("slow-gui", tier="gui"), s("slow-pure", timeoutSeconds=1), s("long", timeoutSeconds=120),
    s("gui-only", tier="gui", sources=["src/g.txt"]),
    s("ui-studio-session-tests", tier="gui", timeoutSeconds=10),
    s("research-map-web-tests", tier="gui", timeoutSeconds=10),
    s("live-default", tier="live"), s("live-limit", tier="live", timeoutSeconds=7),
]
json.dump({"schema": 1, "suiteCount": len(suites), "suites": suites}, open(sys.argv[1], "w"), indent=2)
PY
suite live-default 'echo live'
suite live-limit 'echo live'
run() { (cd "$repo" && ./tools/tests/run.sh "$@"); }

# --- Time limits come from the tier unless the suite declares its own.
limits=$(run --list --all | awk -F'\t' '{print $1 "=" $4}' | tr '\n' ' ')
for expected in ok=180 gui-only=600 live-default=1800 live-limit=7 hang=2; do
    case " $limits" in *" $expected "*) check 0 "the time limit of ${expected%%=*} is ${expected##*=} s" ;; *) check 1 "the time limit of ${expected%%=*} is ${expected##*=} s ($limits)" ;; esac
done

# --- Passing, failing and unknown suites.
run ok > "$work/ok.out" 2>&1; rc=$?
check $((rc != 0)) "a passing suite exits 0"
grep -q "Suites summary: 1 passed, 0 failed" "$work/ok.out"; check $? "the summary counts the passing suite"
run ok fail > "$work/okfail.out" 2>&1; rc=$?
check $((rc != 1)) "a failing suite makes the runner exit 1"
grep -q "Failed suites: fail" "$work/okfail.out"; check $? "the failing suite is named"
run no-such-suite > "$work/unknown.out" 2>&1; rc=$?
check $((rc != 2)) "an unknown suite exits 2"

# UI Studio's static progress must be visible before its long-running suite exits.
(cd "$repo" && exec ./tools/tests/run.sh --tier gui ui-studio-session-tests > "$work/progress.out" 2>&1) &
progress_runner=$!
observed=0
for _ in $(seq 1 100); do
    if grep -Fq '▸ [gui] ui-studio-session-tests: fixture stage' "$work/progress.out" 2>/dev/null && kill -0 "$progress_runner" 2>/dev/null; then
        observed=1
        break
    fi
    sleep 0.05
done
check $((observed != 1)) "UI Studio stage progress appears while the suite is running"
wait "$progress_runner"; rc=$?
check $((rc != 0)) "the progress-reporting suite still passes"
grep -Fq -- '--  fixture stage' "$work/progress.out"; check $? "the complete buffered output still contains the stage"

(cd "$repo" && exec ./tools/tests/run.sh --tier gui research-map-web-tests > "$work/research-progress.out" 2>&1) &
progress_runner=$!
observed=0
for _ in $(seq 1 100); do
    if grep -Fq '▸ [gui] research-map-web-tests: research-map WebKit: 50 checks' "$work/research-progress.out" 2>/dev/null && kill -0 "$progress_runner" 2>/dev/null; then
        observed=1
        break
    fi
    sleep 0.05
done
check $((observed != 1)) "research map progress appears while the suite is running"
wait "$progress_runner"; rc=$?
check $((rc != 0)) "the research map progress-reporting suite still passes"
grep -Fq 'research-map WebKit: 50 checks' "$work/research-progress.out"; check $? "the complete buffered output still contains research map progress"

# --- A hanging suite, one that ignores SIGTERM, one that leaks a process, and the limits at work.
start=$SECONDS
run --tier all hang stubborn leaky slow-gui slow-pure > "$work/limits.out" 2>&1; rc=$?
elapsed=$((SECONDS - start))
check $((rc != 1)) "timed-out suites make the runner exit 1"
check $((elapsed > 25)) "the run ends after the longest limit plus the kill grace, not after the suites' own 300 s (${elapsed} s)"
grep -q "Failed suites: hang slow-pure stubborn" "$work/limits.out"; check $? "exactly the suites over their limit fail"
grep -q "Timed out suites: hang slow-pure stubborn" "$work/limits.out"; check $? "the timed-out suites are named"
grep -q "TIMED OUT after 2s" "$work/limits.out"; check $? "a timed-out suite says how long it was given"
grep -q "TIMED OUT after 1s" "$work/limits.out"; check $? "a suite's own limit is used instead of its tier's"
grep -q "slow but within the gui limit" "$work/limits.out"; check $? "a gui suite that takes longer than the pure limit still finishes (tier limits differ)"
grep -q "Suites summary: 2 passed, 3 failed" "$work/limits.out"; check $? "a suite that leaks a background process still passes on its own result"
grep -q "left background processes running" "$work/limits.out"; check $? "leftover background processes of a passing suite are reported"
gone hang-1; check $? "the background sleeper of a timed-out suite is gone"
gone hang-2; check $? "a sleeper started two shells deep in a timed-out suite is gone"
gone stubborn-1; check $? "a sleeper that ignores SIGTERM is killed by SIGKILL"
gone leaky-1; check $? "the sleeper a passing suite left behind is gone"

# --- An interrupted runner stops the suites it started.
(cd "$repo" && exec ./tools/tests/run.sh long > "$work/interrupt.out" 2>&1) &
runner=$!
for _ in $(seq 1 100); do [ -s "$work/pids/long-1" ] && break; sleep 0.1; done
check $([ -s "$work/pids/long-1" ] && echo 0 || echo 1) "the suite under test is running before the runner is interrupted"
kill -TERM "$runner" 2>/dev/null
wait "$runner" 2>/dev/null; rc=$?
check $((rc != 143)) "an interrupted runner exits with the signal's status ($rc)"
gone long-1; check $? "interrupting the runner kills the suite's process group"

# --- --changed
git_in_repo() { git -C "$repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
echo base > "$repo/src/a.txt"; echo base > "$repo/src/g.txt"; echo base > "$repo/docs/note.md"
git_in_repo init -q . && git_in_repo add -A && git_in_repo commit -q -m base
run --changed > "$work/changed-clean.out" 2>&1; rc=$?
check $((rc != 0)) "--changed with a clean tree exits 0"
grep -q "No changed files" "$work/changed-clean.out"; check $? "--changed with a clean tree says there is nothing to test"
echo more >> "$repo/src/a.txt"
run --changed > "$work/changed-covered.out" 2>&1; rc=$?
grep -q "▸ \[pure\] ok" "$work/changed-covered.out" && ! grep -q "▸ \[pure\] fail" "$work/changed-covered.out"; check $? "--changed runs the suite whose source changed, and only that one"
check $((rc != 0)) "--changed exits with the selected suite's result"
git_in_repo checkout -q -- src/a.txt
echo note >> "$repo/docs/note.md"
run --changed > "$work/changed-uncovered.out" 2>&1; rc=$?
check $((rc != 3)) "--changed exits 3 when files changed but no suite covers them"
grep -q "docs/note.md" "$work/changed-uncovered.out" && grep -q "nothing was run" "$work/changed-uncovered.out" && grep -q "usage:" "$work/changed-uncovered.out"; check $? "--changed names the uncovered files, says nothing was run and prints the usage"
git_in_repo checkout -q -- docs/note.md
echo more >> "$repo/src/g.txt"
run --changed > "$work/changed-tier.out" 2>&1; rc=$?
check $((rc != 3)) "--changed exits 3 when only suites of another tier cover the change"
grep -q "gui-only" "$work/changed-tier.out" && grep -q "outside tier 'pure'" "$work/changed-tier.out"; check $? "--changed names the suites of the other tier"
run --changed --tier gui > "$work/changed-gui.out" 2>&1; rc=$?
grep -q "▸ \[gui\] gui-only" "$work/changed-gui.out"; check $? "--changed --tier gui runs the gui suite that covers the change"
run --changed no-such-ref > "$work/changed-ref.out" 2>&1; rc=$?
check $((rc != 3)) "--changed with a ref git does not know exits 3, not 0"
grep -q "git could not list the changed files" "$work/changed-ref.out"; check $? "--changed says that git could not tell"
git_in_repo checkout -q -- src/g.txt
mkdir "$work/not-a-repo" && mkdir -p "$work/not-a-repo/tools/tests" && cp "$repo/tools/tests/manifest.json" "$repo/tools/tests/ok.sh" "$repo/tools/tests/run.sh" "$work/not-a-repo/tools/tests/"
(cd "$work/not-a-repo" && GIT_CEILING_DIRECTORIES="$work" ./tools/tests/run.sh --changed > "$work/changed-norepo.out" 2>&1); rc=$?
check $((rc != 3)) "--changed outside a git repository exits 3, not 0"

# Xcode's enumerated editor methods must be distributed once, with no silent partial selection.
python3 - "$PWD/tools/ci/hosted-test-shards.py" "$work" <<'PY'
import json, pathlib, subprocess, sys
script, folder = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
path = folder / 'editor-enumeration.json'
tests = [f'MarkViewHostedTests/EditorHostTests/testCase{i}()' for i in range(17)]
def write(ids, errors=None):
    path.write_text(json.dumps({'errors': errors or [], 'values': [{'enabledTests': [{'identifier': x} for x in ids]}]}))
def run(shard, group='editor'):
    return subprocess.run([sys.executable, str(script), str(path), str(shard), '4', group], capture_output=True, text=True)
write(tests)
parts = [run(i) for i in range(4)]
assert all(p.returncode == 0 for p in parts)
actual = [line for p in parts for line in p.stdout.splitlines()]
assert sorted(actual) == sorted(tests) and len(actual) == len(set(actual))
write(tests + [tests[0]])
assert run(0).returncode != 0
write(tests, errors=['enumeration failed'])
assert run(0).returncode != 0
write(['OtherTests/Unexpected/testCase()'] * 4)
assert run(0).returncode != 0
general = [f'MarkViewHostedTests/Fixture{i % 3}/testCase{i}()' for i in range(17)]
write(general)
parts = [run(i, 'general') for i in range(4)]
assert all(p.returncode == 0 for p in parts)
actual = [line for p in parts for line in p.stdout.splitlines()]
assert sorted(actual) == sorted(general) and len(actual) == len(set(actual))
timings = json.loads(script.with_name('hosted-test-seconds.json').read_text())
measured = sorted(timings, key=lambda name: (-timings[name], name))[:4]
write(measured)
balanced = [run(i, 'general') for i in range(4)]
assert all(p.returncode == 0 for p in balanced)
assert all(len(p.stdout.splitlines()) == 1 for p in balanced)
assert sorted(line for p in balanced for line in p.stdout.splitlines()) == sorted(measured)
write(general + [tests[0]])
assert run(0, 'general').returncode != 0
write(general + ['MarkViewHostedTests/ManualProviderHostTests/testLive()'])
assert run(0, 'general').returncode != 0
PY
check $? "hosted shards cover every enumerated method exactly once and reject invalid enumerations"

# The prebuilt CI adapter must retain test selectors and reject build-affecting or mismatched inputs.
python3 - "$PWD/tools/ci/xcodebuild" "$work" <<'PY'
import json, os, pathlib, subprocess, sys
adapter, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
bin_dir = root / 'prebuilt-bin'; bin_dir.mkdir()
derived = root / 'prebuilt-derived'; products = derived / 'Build/Products'; products.mkdir(parents=True)
plan = products / 'MarkView_macosx26.0-arm64.xctestrun'; plan.touch()
capture = root / 'prebuilt-arguments.json'
fake = bin_dir / 'real-xcodebuild'
fake.write_text('#!/usr/bin/env python3\nimport json, os, sys\nopen(os.environ["MV_CAPTURE"],"w").write(json.dumps(sys.argv[1:]))\n')
fake.chmod(0o755)
xcrun = bin_dir / 'xcrun'; xcrun.write_text('#!/bin/bash\nprintf "%s\\n" "$MV_FAKE_XCODEBUILD"\n'); xcrun.chmod(0o755)
env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], MARKVIEW_PREBUILT_HOSTED='1',
           MARKVIEW_HOSTED_TEST_DERIVED_DATA=str(derived), MV_CAPTURE=str(capture), MV_FAKE_XCODEBUILD=str(fake))
base = ['-project', 'MarkView.xcodeproj', '-scheme', 'MarkView', '-configuration', 'HostedTests',
        '-derivedDataPath', str(derived), 'CODE_SIGNING_ALLOWED=NO']
selector = '-only-testing:MarkViewHostedTests/EditorHostTests/testOne()'
def run(extra):
    return subprocess.run([str(adapter), *base, *extra], env=env, capture_output=True, text=True)
assert run([selector, '-skip-testing:MarkViewHostedTests/Skipped', '-test-timeouts-enabled', 'YES', 'test']).returncode == 0
args = json.loads(capture.read_text())
assert args[0] == 'test-without-building' and args[args.index('-xctestrun') + 1] == str(plan)
assert selector in args and '-skip-testing:MarkViewHostedTests/Skipped' in args and '-project' not in args
assert run(['test']).returncode != 0
assert run([selector, 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=OTHER', 'test']).returncode != 0
assert subprocess.run([str(adapter), *base[:-2], '/wrong', *base[-1:], selector, 'test'], env=env, capture_output=True).returncode != 0
plan.unlink()
assert run([selector, 'test']).returncode != 0
PY
check $? "prebuilt adapter preserves selections and rejects unsafe or missing inputs"

# Every hosted selection belongs to exactly one lane, the suites of a lane run one after another, and a failure cannot hide
# later suites.
python3 - "$PWD/tools/ci/run-hosted-lane.sh" "$work" <<'PY'
import os, pathlib, subprocess, sys
script, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]) / 'lane-fixture'
runner = root / 'tools/tests/run.sh'; runner.parent.mkdir(parents=True)
runner.write_text('#!/bin/bash\npart=${MARKVIEW_QA_HOST_PART:-${MARKVIEW_STUDIO_TEST_PART:-$1}}\necho "ran $part"\n[[ "$part" != "${FAIL_SUITE:-}" ]]\n')
runner.chmod(0o755)
def run(lane, failure=''):
    return subprocess.run([str(script), str(lane)], cwd=root, env=dict(os.environ, FAIL_SUITE=failure), capture_output=True, text=True)
results = [run(i) for i in range(5)]
assert all(r.returncode == 0 for r in results)
actual = [line[4:] for r in results for line in r.stdout.splitlines() if line.startswith('ran ')]
expected = ['general-0', 'general-1', 'ui-studio-web-tests', 'project-ai-choice-tests',
            'session', 'recovery', 'terminal-host-tests', 'workflow-editor-layout-tests',
            'theme-web-tests', 'research-map-web-tests', 'editor-2', 'editor-3', 'isolated',
            'editor-0', 'editor-1', 'welcome-screen-tests', 'network']
assert sorted(actual) == sorted(expected) and len(actual) == len(set(actual))
assert [line[4:] for line in results[4].stdout.splitlines() if line.startswith('ran ')] == \
    ['editor-0', 'editor-1', 'welcome-screen-tests', 'network'], "a lane runs its suites in order, never two at once"
bad = run(0, 'general-0')
assert bad.returncode != 0 and 'ran project-ai-choice-tests' in bad.stdout
assert run(5).returncode != 0
PY
check $? "hosted lanes cover every suite once and continue after a failure"

if [ "$failures" -gt 0 ]; then
    echo "run.sh checks FAILED: $failures"
    exit 1
fi
echo "run.sh checks passed"
