#!/bin/bash
# The browser of a window (AR-14 step 9): the shipping BrowserHost (browser tabs and their names, pages opened by programs and local HTML
# files, the window it offers to agents, Preview Web App with its dev server, and the cancellation of the wait when the window closes)
# over the shipping TabsController, panels and web-app discovery, on temporary folders and real loopback ports. The tab itself (a WebKit
# view), the terminals and the stores the control tools reach are compile-time stand-ins (BrowserHostStubs.swift); the control window and the browser tool
# it hands to agents are the real AgentToolWindow and BrowserAgentTabs. No page is loaded, nothing is shown.
#   tools/tests/browser-host-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BrowserHostTests.swift "$out/BrowserHostTests.swift"
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -o "$out/browser-host-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Browser/BrowserHost.swift MarkView/Models/Browser/BrowserAgentTabs.swift MarkView/Models/AgentTools/AgentToolWindow.swift MarkView/Models/Browser/WebPreview.swift MarkView/Models/Browser/BrowserElementPick.swift \
    MarkView/Models/Workspace/WebAppPreview.swift MarkView/Models/AgentTools/BrowserAgentTools.swift MarkView/Models/Workspace/ProjectProviding.swift \
    MarkView/Models/Workspace/DocumentState.swift MarkView/Models/Workspace/ToolRegistry.swift MarkView/Models/Workspace/TabClosing.swift \
    MarkView/Models/Workspace/BackgroundFileScans.swift MarkView/Models/Workspace/EditorDocumentRouting.swift \
    MarkView/Models/Workspace/DocumentScrollSideTable.swift MarkView/Models/Workspace/TabsController.swift \
    MarkView/Models/Book/PDFReader.swift MarkView/Models/AI/OutputLanguage.swift \
    MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift \
    MarkView/Models/Appearance/WelcomeBackdrop.swift MarkView/Models/Appearance/BackdropRegistry.swift MarkView/Models/Appearance/ProjectBackdrop.swift \
    MarkView/Models/Workspace/PanelLayout.swift MarkView/Models/Workspace/SchemaVersionedStore.swift \
    MarkView/Models/Workspace/WindowSession.swift MarkView/Models/Workspace/WindowUIState.swift MarkView/Models/Workspace/WindowChrome.swift \
    tools/tests/BrowserHostStubs.swift "$out/BrowserHostTests.swift" 2>&1 | { grep -E "error:" -A3 || true; } | head -60
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/browser-host-tests"
