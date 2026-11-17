#!/bin/bash
# BUG-108/112/115: exercise workflow layout and mouse interaction with the real app stores.
set -euo pipefail
cd "$(dirname "$0")/../.."
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  -only-testing:MarkViewHostedTests/WorkflowEditorLayoutHostTests test
