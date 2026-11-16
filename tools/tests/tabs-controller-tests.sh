#!/bin/bash
# The window's tabs on real temporary files (Models/Workspace/TabsController.swift): open, edit, save, close prompts, Close Documents,
# files changed on disk, moved files, the scroll table, and which change redraws what.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -o "$out/tabs-controller-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Workspace/DocumentState.swift MarkView/Models/Workspace/ToolRegistry.swift MarkView/Models/Workspace/TabClosing.swift \
    MarkView/Models/Workspace/BackgroundFileScans.swift MarkView/Models/Workspace/EditorDocumentRouting.swift \
    MarkView/Models/Workspace/DocumentScrollSideTable.swift MarkView/Models/Workspace/TabsController.swift \
    MarkView/Models/Book/PDFReader.swift MarkView/Models/AI/OutputLanguage.swift tools/tests/TabsControllerStubs.swift tools/tests/ArchiveStub.swift tools/tests/TabsControllerTests.swift
"$out/tabs-controller-tests"
