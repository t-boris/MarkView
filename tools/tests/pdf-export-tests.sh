#!/bin/bash
# The PDF export of a single document (PDFExporter.render over the PDF-book engine in its "document" mode), in real WebKit with
# the bundled engine page: the size of every page, the title page, the contents, running header and footer, bookmarks and links,
# the background of each style, margins that stay empty (nothing is cut or runs past the page), pictures, diagrams, tables and code
# that arrive whole, and a document with a picture that cannot be read.
#   tools/tests/pdf-export-tests.sh [output folder]     (the PDFs are kept there for a look)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -module-cache-path /private/tmp/markview-swift-cache \
  MarkView/Models/BookPDFSource.swift MarkView/Bridge/BookPDFRenderer.swift MarkView/Bridge/PDFExporter.swift \
  MarkView/Models/DocumentFiles.swift MarkView/Bridge/DocumentFileSchemeHandler.swift \
  tools/tests/PDFExportTests.swift -o "$out/pdf-export-tests"
"$out/pdf-export-tests" "$PWD/MarkView/Resources/Editor/book.html" "${1:-/private/tmp/markview-pdf-export-checks}" "$PWD/Tests/Fixtures/pdf-export"
