#!/bin/bash
# Checks the workspace window title (MarkView/Models/WindowTitle.swift): format, fallbacks and
# folder display names. The app has no XCTest target: the module is compiled on its own with a
# test main and run.
#   tools/tests/window-title-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/WindowTitleTests.swift "$out/main.swift"
swiftc -O -o "$out/window-title-tests" MarkView/Models/WindowTitle.swift "$out/main.swift"
"$out/window-title-tests"
