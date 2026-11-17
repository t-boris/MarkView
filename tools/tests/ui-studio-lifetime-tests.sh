#!/bin/bash
# UI Studio session lifetime against the shipping types in the isolated app host.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PYTHONPATH="$PWD/tools/tests/studio-python${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
if (( $# )); then
  MARKVIEW_STUDIO_LIFETIME_FILTER=$(printf '%s\n' "$@")
  export MARKVIEW_STUDIO_LIFETIME_FILTER
else
  unset MARKVIEW_STUDIO_LIFETIME_FILTER
fi
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  -only-testing:MarkViewHostedTests/UIStudioLifetimeHostTests test
