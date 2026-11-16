#!/bin/bash
# A window's session taken and restored (Models/Workspace/WindowSessionSnapshotter.swift) on the real tabs controller, panels,
# layout, interface state and session storage, with a fake host for what only the workspace manager can open.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -o "$out/window-session-snapshotter-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift \
    MarkView/Models/Appearance/WelcomeBackdrop.swift MarkView/Models/Appearance/BackdropRegistry.swift MarkView/Models/Appearance/ProjectBackdrop.swift \
    MarkView/Models/Workspace/DocumentState.swift MarkView/Models/Workspace/ToolRegistry.swift MarkView/Models/Workspace/TabClosing.swift \
    MarkView/Models/Workspace/BackgroundFileScans.swift MarkView/Models/Workspace/EditorDocumentRouting.swift \
    MarkView/Models/Workspace/DocumentScrollSideTable.swift MarkView/Models/Workspace/TabsController.swift \
    MarkView/Models/Workspace/PanelLayout.swift MarkView/Models/Workspace/SchemaVersionedStore.swift MarkView/Models/Workspace/WindowSession.swift \
    MarkView/Models/Workspace/WindowUIState.swift MarkView/Models/Workspace/WindowChrome.swift MarkView/Models/Workspace/WindowSessionSnapshotter.swift \
    MarkView/Models/Book/PDFReader.swift MarkView/Models/AI/OutputLanguage.swift tools/tests/TabsControllerStubs.swift tools/tests/WindowSessionSnapshotterTests.swift
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/window-session-snapshotter-tests"
