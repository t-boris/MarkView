#!/bin/bash
# The browser of a window (AR-14 step 9): the shipping BrowserHost (browser tabs and their names, pages opened by programs and local HTML
# files, the window it offers to agents, Preview Web App with its dev server, and the cancellation of the wait when the window closes)
# over the shipping TabsController, panels and web-app discovery, on temporary folders and real loopback ports. The tab itself (a WebKit
# view), the terminals and the stores the control tools reach are compile-time stand-ins (BrowserHostStubs.swift); the control window is
# the real BrowserControlServer.Window declaration. No page is loaded, nothing is shown.
#   tools/tests/browser-host-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
python3 - "$out" <<'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
server = pathlib.Path('MarkView/Models/Browser/BrowserControlServer.swift').read_text()
window = server.split('    struct Window {')[1].split('\n    }\n')[0]
(out / 'BrowserControlServer.swift').write_text(
    'import Foundation\nenum BrowserControlServer {\n    struct Window {' + window + '\n    }\n'
    '    nonisolated(unsafe) static var registered: [UUID: Window] = [:]\n'
    '    static func register(_ id: UUID, _ window: Window) { registered[id] = window }\n}\n')
PY
cp tools/tests/BrowserHostTests.swift "$out/BrowserHostTests.swift"
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -o "$out/browser-host-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Browser/BrowserHost.swift MarkView/Models/Browser/WebPreview.swift MarkView/Models/Browser/BrowserElementPick.swift \
    MarkView/Models/Workspace/WebAppPreview.swift MarkView/Models/AgentTools/BrowserAgentTools.swift MarkView/Models/Workspace/ProjectProviding.swift \
    MarkView/Models/Workspace/DocumentState.swift MarkView/Models/Workspace/ToolRegistry.swift MarkView/Models/Workspace/TabClosing.swift \
    MarkView/Models/Workspace/BackgroundFileScans.swift MarkView/Models/Workspace/EditorDocumentRouting.swift \
    MarkView/Models/Workspace/DocumentScrollSideTable.swift MarkView/Models/Workspace/TaskBag.swift MarkView/Models/Workspace/TabsController.swift \
    MarkView/Models/Book/PDFReader.swift MarkView/Models/AI/OutputLanguage.swift \
    MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift \
    MarkView/Models/Appearance/WelcomeBackdrop.swift MarkView/Models/Appearance/BackdropRegistry.swift MarkView/Models/Appearance/ProjectBackdrop.swift \
    MarkView/Models/Workspace/PanelLayout.swift MarkView/Models/Workspace/SchemaVersionedStore.swift \
    MarkView/Models/Workspace/WindowSession.swift MarkView/Models/Workspace/WindowUIState.swift MarkView/Models/Workspace/WindowChrome.swift \
    "$out/BrowserControlServer.swift" tools/tests/BrowserHostStubs.swift "$out/BrowserHostTests.swift" 2>&1 | { grep -E "error:" -A3 || true; } | head -60
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/browser-host-tests"
