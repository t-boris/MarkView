#!/bin/bash
# Checks the message pasted for an element picked in the browser tab (BrowserElementPick.swift).
#   tools/tests/browser-element-pick-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BrowserElementPickTests.swift "$out/main.swift"
swiftc -o "$out/browser-element-pick-tests" MarkView/Models/BrowserElementPick.swift "$out/main.swift"
"$out/browser-element-pick-tests"
