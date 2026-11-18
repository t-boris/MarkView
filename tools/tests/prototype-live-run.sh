#!/bin/bash
# Manual live Claude check: build a prototype in a new unique folder, revise it and pack it.
#   bash tools/tests/prototype-live-run.sh <project root> <source path relative to the root>
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "$#" -eq 2 ] && [ -d "$1" ] || { echo "usage: $0 <project root> <source path relative to the root>"; exit 2; }
root=$(cd "$1" && pwd -P)
export TEST_RUNNER_MARKVIEW_MANUAL_PROTOTYPE=build
export TEST_RUNNER_MARKVIEW_MANUAL_PROTOTYPE_ROOT="$root"
export TEST_RUNNER_MARKVIEW_MANUAL_PROTOTYPE_SOURCE="$2"
unset TEST_RUNNER_MARKVIEW_MANUAL_CLAUDE_BIN
if [ -n "${CLAUDE_BIN:-}" ]; then export TEST_RUNNER_MARKVIEW_MANUAL_CLAUDE_BIN="$CLAUDE_BIN"; fi
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvprototype.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled NO \
  -only-testing:MarkViewHostedTests/ManualPrototypeLiveHostTests/testManualPrototypeBuild test 2>&1 | tee "$socket_dir/test.log"
grep -F "Test Case '-[MarkViewHostedTests.ManualPrototypeLiveHostTests testManualPrototypeBuild]' passed" "$socket_dir/test.log" >/dev/null || {
  echo "The manual prototype build did not run successfully" >&2; exit 1;
}
