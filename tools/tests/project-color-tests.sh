#!/bin/bash
# Checks project colors (MarkView/Models/ProjectColor.swift): palette, project key, stable
# automatic color and persisted choices. The app has no XCTest target: the module is compiled on
# its own with a test main and run.
#   tools/tests/project-color-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ProjectColorTests.swift "$out/main.swift"
swiftc -O -o "$out/project-color-tests" MarkView/Models/ProjectColor.swift "$out/main.swift"
"$out/project-color-tests"
