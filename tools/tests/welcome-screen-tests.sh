#!/bin/bash
# Welcome screen, accessibility and optional fixture snapshots in an isolated app host.
set -euo pipefail
cd "$(dirname "$0")/../.."
unset TEST_RUNNER_SNAPSHOT_DIR TEST_RUNNER_WELCOME_SCROLL_ONLY
if [[ ${SNAPSHOT_DIR+x} ]]; then
  export TEST_RUNNER_SNAPSHOT_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$SNAPSHOT_DIR")"
fi
if [[ ${WELCOME_SCROLL_ONLY+x} ]]; then export TEST_RUNNER_WELCOME_SCROLL_ONLY="$WELCOME_SCROLL_ONLY"; fi
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvwelcomehost.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled YES \
  -only-testing:MarkViewHostedTests/WelcomeScreenHostTests test
