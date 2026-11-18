#!/bin/bash
# Manual UI Studio check on a project COPY; repair, screens and review may call an assistant.
# Usage: tools/tests/ui-studio-live-run.sh <project copy> repair|screens|load|review [scenario name]
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "$#" -ge 2 ] && [ "$#" -le 3 ] && [ -d "$1" ] || { echo "usage: $0 <project copy> repair|screens|load|review [scenario name]"; exit 2; }
case "$2" in repair|screens|load|review) ;; *) echo "Unknown mode: $2" >&2; exit 2;; esac
project=$(cd "$1" && pwd -P)
export TEST_RUNNER_MARKVIEW_MANUAL_STUDIO=1
export TEST_RUNNER_MARKVIEW_MANUAL_STUDIO_PROJECT="$project"
export TEST_RUNNER_MARKVIEW_MANUAL_STUDIO_MODE="$2"
export TEST_RUNNER_MARKVIEW_MANUAL_STUDIO_JS="$PWD/MarkView/Resources/Editor/js"
unset TEST_RUNNER_MARKVIEW_MANUAL_STUDIO_SCENARIO TEST_RUNNER_STUDIO_EVAL TEST_RUNNER_STUDIO_DIALOG TEST_RUNNER_STUDIO_DIALOG_BUTTON
if [ "$#" -eq 3 ]; then export TEST_RUNNER_MARKVIEW_MANUAL_STUDIO_SCENARIO="$3"; fi
if [ "${STUDIO_EVAL+x}" ]; then export TEST_RUNNER_STUDIO_EVAL="$STUDIO_EVAL"; fi
if [ "${STUDIO_DIALOG+x}" ]; then export TEST_RUNNER_STUDIO_DIALOG="$STUDIO_DIALOG"; fi
if [ "${STUDIO_DIALOG_BUTTON+x}" ]; then export TEST_RUNNER_STUDIO_DIALOG_BUTTON="$STUDIO_DIALOG_BUTTON"; fi
export PYTHONPATH="$PWD/tools/tests/studio-python${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1 TEST_RUNNER_PYTHONPATH="$PYTHONPATH" TEST_RUNNER_PYTHONDONTWRITEBYTECODE=1
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvstudio.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled NO \
  -only-testing:MarkViewHostedTests/ManualUIStudioLiveHostTests/testManualUIStudio test 2>&1 | tee "$socket_dir/test.log"
grep -F "Test Case '-[MarkViewHostedTests.ManualUIStudioLiveHostTests testManualUIStudio]' passed" "$socket_dir/test.log" >/dev/null || {
    echo "The manual UI Studio test did not run successfully" >&2; exit 1;
}
