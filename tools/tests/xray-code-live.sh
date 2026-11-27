#!/bin/bash
# Manual: one X-Ray code analysis of this repository's committed source with a real assistant (its installed CLI login and
# normal allowance), on the app's path; prints each call's seconds and tokens and the size of the kept model (BUG-135).
# Usage: xray-code-live.sh [codex|claude] [x-ray model]
set -euo pipefail
cd "$(dirname "$0")/../.."
provider="${1:-codex}"; model="${2:-}"
case "$provider" in claude|codex) ;; *) echo "Unknown provider: $provider" >&2; exit 2;; esac
work=$(mktemp -d /tmp/mvxray.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir "$work/source"
git archive HEAD | tar -x -C "$work/source"
export TEST_RUNNER_MARKVIEW_MANUAL_XRAY_CODE=1 TEST_RUNNER_MARKVIEW_MANUAL_XRAY_PROVIDER="$provider"
export TEST_RUNNER_MARKVIEW_MANUAL_XRAY_ROOT="$work/source" TEST_RUNNER_MARKVIEW_MANUAL_XRAY_MODEL="$model"
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
MARKVIEW_SOCKET_DIR="$work" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$work" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled NO \
  -only-testing:MarkViewHostedTests/ManualProviderLiveHostTests/testManualXRayCodeAnalysis test 2>&1 | tee "$work/test.log" | grep -E "^X-Ray (call|analysis)|: error: |error: -\["
grep -F "Test Case '-[MarkViewHostedTests.ManualProviderLiveHostTests testManualXRayCodeAnalysis]' passed" "$work/test.log" >/dev/null || {
    echo "The manual X-Ray code analysis did not run successfully" >&2; exit 1;
}
