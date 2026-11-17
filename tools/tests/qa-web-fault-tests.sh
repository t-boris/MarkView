#!/bin/bash
# Real app-hosted WebKit fault filtering and editor rendering, with production types.
set -euo pipefail
cd "$(dirname "$0")/../.."
# UI Studio's hosted lifetime scenarios start local Python servers; avoid slow loopback reverse DNS.
export PYTHONPATH="$PWD/tools/tests/studio-python${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
unset MARKVIEW_STUDIO_LIFETIME_FILTER
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvhost.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  -test-timeouts-enabled YES \
  -only-testing:MarkViewHostedTests -skip-testing:MarkViewHostedTests/UIStudioSessionHostTests \
  -skip-testing:MarkViewHostedTests/WorkflowEditorLayoutHostTests test
