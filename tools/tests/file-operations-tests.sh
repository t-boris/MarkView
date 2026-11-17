#!/bin/bash
# Creating, renaming, moving, copying, dropping and trashing files (MarkView/Models/Workspace/FileOperationsController.swift, AR-14 step 2):
# the shipping controller and FileTransfer on real temporary folders and the real TabsController (tabs that follow or close). The
# file tree is a counter; the Trash gets only files the check created, and the check removes them. Nothing is shown.
#   tools/tests/file-operations-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -o "$out/file-operations-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Workspace/FileOperationsController.swift MarkView/Models/Shared/ArchiveSupport.swift MarkView/Models/Workspace/FileTransfer.swift MarkView/Models/Shared/ProjectProviding.swift \
    MarkView/Models/Workspace/DocumentState.swift MarkView/Models/Architecture/XRayScope.swift MarkView/Models/Git/GitHubItem.swift MarkView/Models/Shared/FileType.swift MarkView/Models/Workspace/ToolRegistry.swift MarkView/Models/Workspace/TabClosing.swift \
    MarkView/Models/Workspace/BackgroundFileScans.swift MarkView/Models/Workspace/EditorDocumentRouting.swift \
    MarkView/Models/Workspace/DocumentScrollSideTable.swift MarkView/Models/Workspace/TabsController.swift MarkView/Models/Shared/UserPrompts.swift \
    MarkView/Models/Book/PDFReader.swift MarkView/Models/AI/OutputLanguage.swift tools/tests/TabsControllerStubs.swift \
    tools/tests/ProjectProvidingTestSupport.swift tools/tests/FileOperationsTests.swift
"$out/file-operations-tests"
