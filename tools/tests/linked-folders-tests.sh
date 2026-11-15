#!/bin/bash
# Checks linked folders (MarkView/Models/Workspace/LinkedFolders.swift, Task 59) and the project search
# index over them (MarkView/Models/Workspace/ProjectSearch.swift). The app has no XCTest target: the
# modules are compiled on their own with a test main and run.
#   tools/tests/linked-folders-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/LinkedFoldersTests.swift "$out/main.swift"
swiftc -O -o "$out/linked-folders-tests" MarkView/Models/Workspace/LinkedFolders.swift MarkView/Models/Appearance/ProjectColor.swift \
    MarkView/Models/Workspace/ProjectSearch.swift MarkView/Models/Workspace/ArchiveSupport.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift "$out/main.swift"
"$out/linked-folders-tests"
