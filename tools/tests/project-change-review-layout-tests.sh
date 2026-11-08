#!/bin/bash
# BUG-107: the shipping "Observed file changes" sheet, hosted off screen (a borderless window far outside the display, never
# shown), measured at the sizes a person sees it: the file list stays narrow and the Before and Current versions get the rest.
# The view is compiled as it ships; the model and the workspace are stand-ins inside the test file (no XCTest target exists).
#   tools/tests/project-change-review-layout-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ProjectChangeReviewLayoutTests.swift "$out/main.swift"
swiftc -target "$(uname -m)-apple-macos13.0" \
    MarkView/Views/ProjectChangeReviewView.swift MarkView/Models/AppTheme.swift MarkView/Models/WindowTheme.swift \
    MarkView/Views/AppPalette.swift "$out/main.swift" -o "$out/layout-tests"
"$out/layout-tests"
