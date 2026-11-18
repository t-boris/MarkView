#!/bin/bash
# Exercise completion deadlines, ACP continuation or provider extension in an isolated app host.
set -euo pipefail
cd "$(dirname "$0")/../.."
if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--continuation" && "$1" != "--extension" ]]; }; then
    echo "usage: $0 [--continuation|--extension]" >&2; exit 2
fi
fixture_source=Tests/Fixtures/assistant-cli-timeout.py
fixture_name=timeout.py
test_class=CLICompletionTimeoutHostTests
test_method=testCompletionDeadlinesAndCancellation
if (( $# == 1 )) && [[ "$1" == "--continuation" ]]; then
    fixture_source=Tests/Fixtures/assistant-acp-continuation.py
    fixture_name=continuation.py
    test_class=ACPContinuationHostTests
    test_method=testContinuationsAndPermissions
fi
if (( $# == 1 )) && [[ "$1" == "--extension" ]]; then
    fixture_source=Tests/Fixtures/assistant-provider-extension.py
    fixture_name=extension.py
    test_class=AssistantExtensionHostTests
    test_method=testProviderExtension
fi
scratch=$(mktemp -d /tmp/mvcli-test-XXXXXX)
mkdir -p "$scratch/home" "$scratch/scratch"
cp "$fixture_source" "$scratch/$fixture_name"
chmod 755 "$scratch/$fixture_name"
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
                *"/$tag/$fixture_name"*)
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
export TEST_RUNNER_MARKVIEW_CLI_TEST_SCRATCH="$scratch/scratch"
export TEST_RUNNER_MARKVIEW_CLI_TEST_FIXTURE="$scratch/$fixture_name"
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
MARKVIEW_SOCKET_DIR="$scratch" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled YES \
  -only-testing:MarkViewHostedTests/"$test_class"/"$test_method" test 2>&1 | tee "$scratch/test.log"
grep -F "Test Case '-[MarkViewHostedTests.$test_class $test_method]' passed" "$scratch/test.log" >/dev/null || {
    echo "The $test_class test did not run successfully" >&2; exit 1;
}
