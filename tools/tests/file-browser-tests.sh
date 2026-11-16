#!/bin/bash
# Checks the rules of the Files panel (MarkView/Models/Workspace/FileBrowserModel.swift): views' filters, sort, the
# Workspace level, the tree and its recursive search, and the viewer classification
# (FileType.hasViewer). The app has no XCTest target: the production modules are compiled on their own
# with a test main and run.
#   tools/tests/file-browser-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/FileBrowserTests.swift "$out/main.swift"
swiftc -o "$out/file-browser-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Shared/FileType.swift MarkView/Models/Shared/ArchiveSupport.swift \
    MarkView/Models/Workspace/FileNode.swift MarkView/Models/Workspace/WindowUIState.swift MarkView/Models/Workspace/FileBrowserModel.swift "$out/main.swift"
"$out/file-browser-tests"
