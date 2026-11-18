#!/bin/bash
# Exercise completion deadlines against a local fixture in an isolated app host.
set -euo pipefail
cd "$(dirname "$0")/../.."
if (( $# )); then echo "usage: $0" >&2; exit 2; fi
scratch=$(mktemp -d /tmp/mvcli-test-XXXXXX)
mkdir -p "$scratch/home"
cp Tests/Fixtures/assistant-cli-timeout.py "$scratch/timeout.py"
chmod 755 "$scratch/timeout.py"
cleanup() {
    local status=$? pid command group tag
    trap - EXIT INT TERM
    set +e
    tag=$(basename "$scratch")
    if [ -f "$scratch/children.pid" ]; then
        while IFS= read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            command=$(ps -p "$pid" -o command= 2>/dev/null)
            case "$command" in
                *"/$tag/timeout.py"*)
                    group=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d ' ')
                    if [[ "$group" == "$pid" ]]; then kill -KILL -- "-$pid" 2>/dev/null; else kill -KILL "$pid" 2>/dev/null; fi
                    ;;
            esac
        done < "$scratch/children.pid"
    fi
    rm -rf "$scratch"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset MARKVIEW_COMPLETION_LIVE_COPILOT TEST_RUNNER_MARKVIEW_COMPLETION_LIVE_COPILOT
export TEST_RUNNER_CFFIXED_USER_HOME="$scratch/home"
export TEST_RUNNER_MARKVIEW_CLI_TEST_HOME="$scratch/home"
export TEST_RUNNER_MARKVIEW_CLI_TEST_FIXTURE="$scratch/timeout.py"
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
MARKVIEW_SOCKET_DIR="$scratch" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled YES \
  -only-testing:MarkViewHostedTests/CLICompletionTimeoutHostTests/testCompletionDeadlinesAndCancellation test 2>&1 | tee "$scratch/test.log"
grep -F "Test Case '-[MarkViewHostedTests.CLICompletionTimeoutHostTests testCompletionDeadlinesAndCancellation]' passed" "$scratch/test.log" >/dev/null || {
    echo "The completion deadline test did not run successfully" >&2; exit 1;
}
