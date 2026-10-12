#!/bin/bash
# Checks that a window.open popup keeps its opener link and closes itself (BrowserPopup.swift).
#   tools/tests/browser-popup-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BrowserPopupTests.swift "$out/main.swift"
swiftc -o "$out/browser-popup-tests" MarkView/Views/BrowserPopup.swift "$out/main.swift"
"$out/browser-popup-tests"
