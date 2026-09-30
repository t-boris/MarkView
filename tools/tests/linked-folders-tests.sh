#!/bin/bash
# Checks linked folders (MarkView/Models/LinkedFolders.swift, Task 59) and the project search
# index over them (MarkView/Models/ProjectSearch.swift). The app has no XCTest target: the
# modules are compiled on their own with a test main and run.
#   tools/tests/linked-folders-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/LinkedFoldersTests.swift "$out/main.swift"
swiftc -O -o "$out/linked-folders-tests" MarkView/Models/LinkedFolders.swift MarkView/Models/ProjectColor.swift \
    MarkView/Models/ProjectSearch.swift "$out/main.swift"
"$out/linked-folders-tests"
