#!/bin/bash
# Exercise the production relay, control socket, workspace and WebKit in the isolated app host.
set -euo pipefail
cd "$(dirname "$0")/../.."
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvhost.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  -only-testing:MarkViewHostedTests/RemoteBrowserHostTests test
