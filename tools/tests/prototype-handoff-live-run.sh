#!/bin/bash
# Manual live Claude check: capture and describe one prototype screen's changes.
#   bash tools/tests/prototype-handoff-live-run.sh <prototype folder> <screen id> <changed files, comma separated> <project root>
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "$#" -eq 4 ] && [ -d "$1" ] && [ -d "$4" ] || { echo "usage: $0 <prototype folder> <screen id> <changed files> <project root>"; exit 2; }
folder=$(cd "$1" && pwd -P)
root=$(cd "$4" && pwd -P)
export TEST_RUNNER_MARKVIEW_MANUAL_PROTOTYPE=handoff
export TEST_RUNNER_MARKVIEW_MANUAL_PROTOTYPE_FOLDER="$folder"
export TEST_RUNNER_MARKVIEW_MANUAL_PROTOTYPE_SCREEN="$2"
export TEST_RUNNER_MARKVIEW_MANUAL_PROTOTYPE_FILES="$3"
export TEST_RUNNER_MARKVIEW_MANUAL_PROTOTYPE_ROOT="$root"
unset TEST_RUNNER_MARKVIEW_MANUAL_CLAUDE_BIN
if [ -n "${CLAUDE_BIN:-}" ]; then export TEST_RUNNER_MARKVIEW_MANUAL_CLAUDE_BIN="$CLAUDE_BIN"; fi
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvprototype.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled NO \
  -only-testing:MarkViewHostedTests/ManualPrototypeLiveHostTests/testManualPrototypeHandoff test 2>&1 | tee "$socket_dir/test.log"
grep -F "Test Case '-[MarkViewHostedTests.ManualPrototypeLiveHostTests testManualPrototypeHandoff]' passed" "$socket_dir/test.log" >/dev/null || {
  echo "The manual prototype hand-off did not run successfully" >&2; exit 1;
}
