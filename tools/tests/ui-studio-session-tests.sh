#!/bin/bash
# Full UI Studio session against shipping types in the isolated app host.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PYTHONPATH="$PWD/tools/tests/studio-python${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvstudiohost.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
case "${MARKVIEW_STUDIO_TEST_PART:-all}" in
  all) selection=MarkViewHostedTests/UIStudioSessionHostTests ;;
  session) selection=MarkViewHostedTests/UIStudioSessionHostTests/testSession ;;
  network) selection=MarkViewHostedTests/UIStudioSessionHostTests/testEnvironmentAndNetworking ;;
  recovery) selection=MarkViewHostedTests/UIStudioSessionHostTests/testAuthenticationAndRecovery ;;
  *) echo "Unknown UI Studio test part: $MARKVIEW_STUDIO_TEST_PART" >&2; exit 2 ;;
esac
MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  "-only-testing:$selection" test
