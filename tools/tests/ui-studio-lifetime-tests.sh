#!/bin/bash
# UI Studio session lifetime against the shipping types in the isolated app host.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PYTHONPATH="$PWD/tools/tests/studio-python${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
export TEST_RUNNER_PYTHONPATH="$PYTHONPATH"
export TEST_RUNNER_PYTHONDONTWRITEBYTECODE=1
if (( $# )); then
  MARKVIEW_STUDIO_LIFETIME_FILTER=$(printf '%s\n' "$@")
  export MARKVIEW_STUDIO_LIFETIME_FILTER
  export TEST_RUNNER_MARKVIEW_STUDIO_LIFETIME_FILTER="$MARKVIEW_STUDIO_LIFETIME_FILTER"
else
  unset MARKVIEW_STUDIO_LIFETIME_FILTER TEST_RUNNER_MARKVIEW_STUDIO_LIFETIME_FILTER
fi
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvstudiohost.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  -only-testing:MarkViewHostedTests/UIStudioLifetimeHostTests test
