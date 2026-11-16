#!/bin/bash
# Checks the Finder-like list selection (MarkView/Models/Workspace/ListSelection.swift) and renaming in place
# (MarkView/Models/Workspace/FileTransfer.swift). The app has no XCTest target: the modules are compiled on
# their own with a test main and run.
#   tools/tests/list-selection-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ListSelectionTests.swift "$out/main.swift"
swiftc -O -o "$out/list-selection-tests" MarkView/Models/Workspace/ListSelection.swift MarkView/Models/Workspace/FileTransfer.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift "$out/main.swift"
"$out/list-selection-tests"
