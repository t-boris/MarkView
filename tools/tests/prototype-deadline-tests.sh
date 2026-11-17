#!/bin/bash
# Prototype generation and recovery through the app's scoped assistant boundary.
set -euo pipefail
cd "$(dirname "$0")/../.."
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  -only-testing:MarkViewHostedTests/PrototypeDeadlineHostTests test
