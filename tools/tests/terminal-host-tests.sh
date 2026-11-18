#!/bin/bash
# Terminal and editor WebKit checks run in separate app-host processes so a
# timed-out PTY fixture cannot continue into the editor-navigation checks.
set -euo pipefail
cd "$(dirname "$0")/../.."
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvtermhost.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
for test_class in TerminalLayoutHostTests TerminalLinkHostTests; do
    MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
      -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled YES \
      -only-testing:MarkViewHostedTests/"$test_class" test 2>&1 | tee "$socket_dir/$test_class.log"
    grep -F "Test Suite '$test_class' passed" "$socket_dir/$test_class.log" >/dev/null || {
        echo "The $test_class suite did not complete successfully" >&2; exit 1;
    }
done
for method in testPTYChildClosesInheritedDescriptors testPTYChildTerminationAndReaping testTerminalLinks testEditorLineLinks; do
    grep -F "Test Case '-[MarkViewHostedTests.TerminalLinkHostTests $method]' passed" "$socket_dir/TerminalLinkHostTests.log" >/dev/null || {
        echo "The terminal host test $method did not complete successfully" >&2; exit 1;
    }
done
grep -F "Test Case '-[MarkViewHostedTests.TerminalLayoutHostTests testLayoutAndLivePTY]' passed" "$socket_dir/TerminalLayoutHostTests.log" >/dev/null || {
    echo "The terminal layout test did not complete successfully" >&2; exit 1;
}
