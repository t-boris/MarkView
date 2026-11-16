#!/bin/bash
# Translating a whole document (MarkView/Models/Workspace/DocumentTranslator.swift, AR-14 step 1): the shipping translator on the real
# TabsController, MarkdownDocumentChunker and AIOperation, with a scripted assistant in place of the CLI. Nothing is started or shown.
#   tools/tests/document-translator-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -o "$out/document-translator-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Workspace/DocumentTranslator.swift MarkView/Models/Insight/SemanticUsage.swift MarkView/Models/Workspace/MarkdownDocumentChunker.swift MarkView/Models/Shared/ProjectProviding.swift \
    MarkView/Models/AI/AIOperation.swift MarkView/Models/AI/CLICompletion.swift MarkView/Models/AI/ACPAssistant.swift \
    MarkView/Models/AI/AgentProcesses.swift MarkView/Models/AI/Providers/*.swift tools/tests/CLICompletionTestSupport.swift \
    MarkView/Models/Workspace/DocumentState.swift MarkView/Models/Architecture/XRayScope.swift MarkView/Models/Git/GitHubItem.swift MarkView/Models/Shared/FileType.swift MarkView/Models/Workspace/ToolRegistry.swift MarkView/Models/Workspace/TabClosing.swift \
    MarkView/Models/Workspace/BackgroundFileScans.swift MarkView/Models/Workspace/EditorDocumentRouting.swift \
    MarkView/Models/Workspace/DocumentScrollSideTable.swift MarkView/Models/Workspace/TabsController.swift MarkView/Models/Shared/UserPrompts.swift \
    MarkView/Models/Book/PDFReader.swift MarkView/Models/AI/OutputLanguage.swift tools/tests/TabsControllerStubs.swift tools/tests/ArchiveStub.swift \
    tools/tests/DocumentTranslatorTests.swift
"$out/document-translator-tests"
