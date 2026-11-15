#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
python3 - "$out/WorkspaceRouting.swift" <<'PY'
from pathlib import Path
import sys
source = Path("MarkView/Models/Workspace/WorkspaceManager.swift").read_text()
store = source.split("@MainActor\nfinal class WorkspaceTabsStore:")[1].split("\nenum WorkspaceAITool:")[0]
def method(signature):
    start = source.index("    " + signature)
    end = source.index("\n    }\n", start) + len("\n    }\n")
    return source[start:end]
ingest = Path("MarkView/Models/Lifecycle/FeatureIngest.swift").read_text()
start = ingest.index("    nonisolated static func readableText(of url: URL) async -> String {")
end = ingest.index("\n    }\n", start) + len("\n    }\n")
Path(sys.argv[1]).write_text(
    "import Foundation\nimport SwiftUI\nimport PDFKit\nimport UniformTypeIdentifiers\n@MainActor\nfinal class WorkspaceTabsStore:" + store
    + "\nextension PDFReaderRoutingHarness {\n"
    + method("func openFile(_ url: URL) {") + method("func saveActiveFile() {") + "\n}\n"
    + "\nenum ExistingPDFIngest {\n" + ingest[start:end] + "\n}\n"
)
PY
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library \
    MarkView/Models/Workspace/DocumentState.swift MarkView/Models/Workspace/TabClosing.swift MarkView/Models/Book/PDFReader.swift \
    MarkView/Views/Book/PDFReaderView.swift MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift MarkView/Models/Appearance/WindowTheme.swift MarkView/Views/Appearance/AppPalette.swift "$out/WorkspaceRouting.swift" \
    tools/tests/PDFReaderRoutingTests.swift tools/tests/TabClosingStoreTests.swift tools/tests/PDFReaderViewTests.swift tools/tests/PDFReaderTests.swift \
    -o "$out/pdf-reader-tests"
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/pdf-reader-tests"
