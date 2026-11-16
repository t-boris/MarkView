#!/bin/bash
# Checks linked folders (MarkView/Models/Shared/LinkedFolderStore.swift and Workspace/LinkedFolders.swift, Task 59) and the project search
# index over them (MarkView/Models/Shared/ProjectSearch.swift). The app has no XCTest target: the
# modules are compiled on their own with a test main and run.
#   tools/tests/linked-folders-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/LinkedFoldersTests.swift "$out/main.swift"
swiftc -O -o "$out/linked-folders-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Shared/LinkedFolders.swift MarkView/Models/Shared/LinkedFolderStore.swift MarkView/Models/AI/Providers/*.swift MarkView/Models/Appearance/ProjectColor.swift \
    MarkView/Models/Shared/ProjectSearch.swift MarkView/Models/Shared/ArchiveSupport.swift "$out/main.swift"
"$out/linked-folders-tests"
