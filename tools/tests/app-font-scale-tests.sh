#!/bin/bash
# Checks the application font scale rules (MarkView/Models/AppFontScale.swift): range, step,
# fallback to 100%, text-style sizes and the editor slider mirror. The app has no XCTest target:
# the module is compiled on its own with a test main and run.
#   tools/tests/app-font-scale-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/AppFontScaleTests.swift "$out/main.swift"
swiftc -O -o "$out/app-font-scale-tests" MarkView/Models/AppFontScale.swift "$out/main.swift"
"$out/app-font-scale-tests"
