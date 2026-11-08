#!/bin/bash
# Feature x-ray-comparison-by-date (REQ-001, REQ-003, REQ-004): the shipping X-Ray page in WebKit draws a comparison of the
# working copy with an earlier commit on the focused and on the full map, marks changed and removed files whatever overlay is
# on, and offers the date picker with its empty state. The app has no XCTest target: the page is loaded off-screen.
#   tools/tests/xray-comparison-web-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/XRayComparisonWebTests.swift "$out/main.swift"
swiftc -O -o "$out/web" "$out/main.swift"
"$out/web" "$PWD/MarkView/Resources/Editor"
