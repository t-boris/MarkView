#!/bin/bash
# Exercise the packaged Cockpit runtime in its own app-hosted XCTest process.
# MARKVIEW_TEST_RUNTIME may point to the runtime built by the dedicated CI job.
set -euo pipefail
cd "$(dirname "$0")/../.."
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvcockpit.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
if [ -n "${MARKVIEW_TEST_RUNTIME:-}" ]; then
  export TEST_RUNNER_MARKVIEW_TEST_RUNTIME="$MARKVIEW_TEST_RUNTIME"
else
  unset TEST_RUNNER_MARKVIEW_TEST_RUNTIME
fi
MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled YES \
  -only-testing:MarkViewHostedTests/CockpitRuntimeIntegrationHostTests/testPackagedCockpitRuntime \
  -only-testing:MarkViewHostedTests/CockpitRuntimeIntegrationHostTests/testGroupMembersRunTogetherThroughThePackagedRuntime test
