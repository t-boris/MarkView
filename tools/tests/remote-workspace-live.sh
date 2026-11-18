#!/bin/bash
# Manual: connects to a real relay and launches the selected providers.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $# -lt 3 || $# -gt 5 ]]; then
    echo 'Usage: remote-workspace-live.sh <HTTPS relay URL> <access-key file> <MarkView.app> [claude|codex|both] [--natural-edit]' >&2
    exit 64
fi
relay=$1; key_file=$2; app=$3/Contents/MacOS/MarkView; selection=${4:-both}; scenario=0
if [[ $# -eq 5 ]]; then
    [[ "$5" == '--natural-edit' ]] || { echo 'Unknown scenario.' >&2; exit 64; }
    scenario=1
fi
if [[ ! -x "$app" || ! -r "$key_file" ]]; then
    echo 'Provide a built MarkView.app and a readable private relay access-key file.' >&2
    exit 64
fi
case "$selection" in
    claude|codex) providers=("$selection") ;;
    both) providers=(claude codex) ;;
    *) echo 'Choose claude, codex or both.' >&2; exit 64 ;;
esac
key_dir=$(cd "$(dirname "$key_file")" && pwd -P); key_file="$key_dir/$(basename "$key_file")"
app_dir=$(cd "$(dirname "$app")" && pwd -P); app="$app_dir/$(basename "$app")"
export TEST_RUNNER_MARKVIEW_MANUAL_REMOTE_PROVIDER=1 TEST_RUNNER_MARKVIEW_MANUAL_REMOTE_RELAY="$relay"
export TEST_RUNNER_MARKVIEW_MANUAL_REMOTE_KEY_FILE="$key_file" TEST_RUNNER_MARKVIEW_MANUAL_REMOTE_APP="$app"
export TEST_RUNNER_MARKVIEW_MANUAL_REMOTE_NATURAL_EDIT="$scenario"
unset TEST_RUNNER_MARKVIEW_LIVE_RESUME_FIXTURE TEST_RUNNER_MARKVIEW_LIVE_MODEL
if [[ -n "${MARKVIEW_LIVE_RESUME_FIXTURE:-}" ]]; then export TEST_RUNNER_MARKVIEW_LIVE_RESUME_FIXTURE="$MARKVIEW_LIVE_RESUME_FIXTURE"; fi
if [[ -n "${MARKVIEW_LIVE_MODEL:-}" ]]; then export TEST_RUNNER_MARKVIEW_LIVE_MODEL="$MARKVIEW_LIVE_MODEL"; fi
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvremote.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
for provider in "${providers[@]}"; do
    executable=$(command -v "$provider")
    export TEST_RUNNER_MARKVIEW_MANUAL_REMOTE_PROVIDER_NAME="$provider" TEST_RUNNER_MARKVIEW_MANUAL_REMOTE_EXECUTABLE="$executable"
    MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
      -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled NO \
      -only-testing:MarkViewHostedTests/ManualRemoteProviderHostTests/testManualRemoteProvider test 2>&1 | tee "$socket_dir/test.log"
    grep -F "Test Case '-[MarkViewHostedTests.ManualRemoteProviderHostTests testManualRemoteProvider]' passed" "$socket_dir/test.log" >/dev/null || {
        echo "The manual remote-provider test did not run successfully" >&2; exit 1;
    }
done
