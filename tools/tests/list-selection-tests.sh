#!/bin/bash
# Checks the Finder-like list selection (MarkView/Models/ListSelection.swift) and renaming in place
# (MarkView/Models/FileTransfer.swift). The app has no XCTest target: the modules are compiled on
# their own with a test main and run.
#   tools/tests/list-selection-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ListSelectionTests.swift "$out/main.swift"
swiftc -O -o "$out/list-selection-tests" MarkView/Models/ListSelection.swift MarkView/Models/FileTransfer.swift "$out/main.swift"
"$out/list-selection-tests"
