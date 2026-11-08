#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
python3 - "$out/WorkspaceRouting.swift" <<'PY'
from pathlib import Path
import sys
source = Path("MarkView/Models/WorkspaceManager.swift").read_text()
store = source.split("@MainActor\nfinal class WorkspaceTabsStore:")[1].split("\nenum WorkspaceAITool:")[0]
def method(signature):
    start = source.index("    " + signature)
    end = source.index("\n    }\n", start) + len("\n    }\n")
    return source[start:end]
ingest = Path("MarkView/Models/FeatureIngest.swift").read_text()
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
    MarkView/Models/DocumentState.swift MarkView/Models/PDFReader.swift \
    MarkView/Views/PDFReaderView.swift MarkView/Models/AppTheme.swift MarkView/Models/WindowTheme.swift MarkView/Views/AppPalette.swift "$out/WorkspaceRouting.swift" \
    tools/tests/PDFReaderRoutingTests.swift tools/tests/PDFReaderViewTests.swift tools/tests/PDFReaderTests.swift \
    -o "$out/pdf-reader-tests"
"$out/pdf-reader-tests"
