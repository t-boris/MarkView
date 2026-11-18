#!/bin/bash
# Run the remote workspace checks in their own app host and process registry.
set -euo pipefail
cd "$(dirname "$0")/../.."
if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--core-only" ]]; }; then
    echo "usage: $0 [--core-only]" >&2; exit 2
fi
scratch=$(mktemp -d /tmp/mvremotehost.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
unset MARKVIEW_REMOTE_CORE_ONLY TEST_RUNNER_MARKVIEW_REMOTE_CORE_ONLY
if (( $# == 1 )); then export TEST_RUNNER_MARKVIEW_REMOTE_CORE_ONLY=1; fi
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
MARKVIEW_SOCKET_DIR="$scratch" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled YES \
  -only-testing:MarkViewHostedTests/RemoteWorkspaceHostTests/testRemoteWorkspace test 2>&1 | tee "$scratch/test.log"
grep -F "Test Case '-[MarkViewHostedTests.RemoteWorkspaceHostTests testRemoteWorkspace]' passed" "$scratch/test.log" >/dev/null || {
    echo "The remote workspace test did not run successfully" >&2; exit 1;
}
