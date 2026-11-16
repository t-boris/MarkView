#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
python3 - "$out/ExistingPDFIngest.swift" <<'PY'
from pathlib import Path
import sys
ingest = Path("MarkView/Models/Lifecycle/FeatureIngest.swift").read_text()
start = ingest.index("    nonisolated static func readableText(of url: URL) async -> String {")
end = ingest.index("\n    }\n", start) + len("\n    }\n")
Path(sys.argv[1]).write_text(
    "import Foundation\nimport SwiftUI\nimport PDFKit\nimport UniformTypeIdentifiers\n"
    + "enum ExistingPDFIngest {\n" + ingest[start:end] + "\n}\n"
)
PY
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library \
    MarkView/Models/Appearance/WebThemeArguments.swift Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Workspace/DocumentState.swift MarkView/Models/Architecture/XRayScope.swift MarkView/Models/Git/GitHubItem.swift MarkView/Models/Shared/FileType.swift MarkView/Models/Workspace/ToolRegistry.swift MarkView/Models/Workspace/TabClosing.swift MarkView/Models/Workspace/BackgroundFileScans.swift \
    MarkView/Models/Workspace/EditorDocumentRouting.swift MarkView/Models/Workspace/DocumentScrollSideTable.swift MarkView/Models/Workspace/TabsController.swift \
    MarkView/Models/Book/PDFReader.swift MarkView/Models/AI/OutputLanguage.swift \
    MarkView/Views/Book/PDFReaderView.swift MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift MarkView/Models/Appearance/WindowTheme.swift MarkView/Views/Appearance/AppPalette.swift "$out/ExistingPDFIngest.swift" \
    tools/tests/TabsControllerStubs.swift tools/tests/PDFReaderRoutingTests.swift tools/tests/TabClosingStoreTests.swift tools/tests/PDFReaderViewTests.swift tools/tests/PDFReaderTests.swift \
    -o "$out/pdf-reader-tests"
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/pdf-reader-tests"
