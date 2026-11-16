#!/bin/bash
# AR-04 in real WebKit (hidden windows): hostile values (quotes, backslashes, U+2028/U+2029, `</script>`, code in a quote, a template
# literal, control characters, emoji, a 1 MB string) sent through the real WebViewBridge to the shipping editor page, and through the
# real TerminalSession to the shipping terminal page, reach the page unchanged and run nothing.
#   tools/tests/js-call-web-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# The editor bridge.
cp tools/tests/JSCallEditorWebTests.swift "$out/main.swift"
swiftc -O -module-cache-path /private/tmp/markview-swift-cache -o "$out/js-call-editor-web-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Bridge/TypedWebBridge.swift MarkView/Bridge/PageMessages.swift MarkView/Bridge/WebViewBridge.swift MarkView/Models/Appearance/WebThemeArguments.swift \
    MarkView/Bridge/DataFileSchemeHandler.swift MarkView/Models/Workspace/EditorDocumentRouting.swift \
    MarkView/Models/Workspace/EditorWindowPrefs.swift MarkView/Models/Insight/SemanticModels.swift \
    MarkView/Models/Insight/InsightModels.swift MarkView/Models/Appearance/AppFontScale.swift \
    tools/tests/BridgeContractSupport.swift "$out/main.swift"
"$out/js-call-editor-web-tests" "$PWD/MarkView/Resources/Editor"

# The terminal paths (the real session and the real xterm page).
rm -f "$out/main.swift"
python3 - "$out" <<'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
source = pathlib.Path('MarkView/Models/Workspace/DocumentState.swift').read_text()
(out / 'FileType.swift').write_text(source.split('/// Represents a table of contents heading entry')[0])
(out / 'main.swift').write_text(pathlib.Path('tools/tests/JSCallTerminalWebTests.swift').read_text())
(out / 'fixtures').mkdir()
PY
swiftc -O -module-cache-path /private/tmp/markview-swift-cache -o "$out/js-call-terminal-web-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Bridge/TypedWebBridge.swift MarkView/Bridge/PageMessages.swift MarkView/Models/Appearance/AppFontScale.swift \
    MarkView/Views/Appearance/AppFontScaleView.swift MarkView/Models/Terminal/TerminalLink.swift MarkView/Models/Remote/RemoteConnectionState.swift \
    MarkView/Models/Terminal/TerminalSession.swift MarkView/Models/Appearance/WebThemeArguments.swift MarkView/Models/Terminal/TerminalProfile.swift MarkView/Models/AI/Providers/*.swift MarkView/Models/Terminal/TerminalChildProcess.swift \
    MarkView/Models/Terminal/TerminalBrowserBridge.swift MarkView/Models/Terminal/PTYWriter.swift "$out/FileType.swift" \
    MarkView/Models/Workspace/ArchiveSupport.swift "$out/main.swift"
"$out/js-call-terminal-web-tests" "$PWD/MarkView/Resources/Editor/terminal.html" "$out/fixtures"
