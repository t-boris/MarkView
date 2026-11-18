#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Real Copilot remains explicit manual mode; normal checks use the local fixture.
if [ -z "${MARKVIEW_COMPLETION_LIVE_COPILOT:-}" ]; then
    exec bash tools/tests/cli-completion-timeout-host-tests.sh "$@"
fi
[ "$#" -eq 0 ] && [ -x "$MARKVIEW_COMPLETION_LIVE_COPILOT" ] || {
    echo "Set MARKVIEW_COMPLETION_LIVE_COPILOT to an executable path and pass no arguments" >&2; exit 2;
}
binary_dir=$(cd "$(dirname "$MARKVIEW_COMPLETION_LIVE_COPILOT")" && pwd -P)
export TEST_RUNNER_MARKVIEW_MANUAL_COPILOT=1
export TEST_RUNNER_MARKVIEW_MANUAL_COPILOT_BINARY="$binary_dir/$(basename "$MARKVIEW_COMPLETION_LIVE_COPILOT")"
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvcopilot.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled NO \
  -only-testing:MarkViewHostedTests/ManualProviderLiveHostTests/testManualCopilot test 2>&1 | tee "$socket_dir/test.log"
grep -F "Test Case '-[MarkViewHostedTests.ManualProviderLiveHostTests testManualCopilot]' passed" "$socket_dir/test.log" >/dev/null || {
    echo "The manual Copilot test did not run successfully" >&2; exit 1;
}
