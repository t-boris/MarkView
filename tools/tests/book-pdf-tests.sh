#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -module-cache-path /private/tmp/markview-swift-cache \
  MarkView/Models/Book/BookPDFSource.swift MarkView/Models/Book/BookPDFTransform.swift \
  MarkView/Bridge/BookPDFRenderer.swift Packages/MarkViewCore/Sources/MarkViewCore/WebHost.swift tools/tests/BookPDFTests.swift -o "$out/book-pdf-tests"
"$out/book-pdf-tests" "$PWD/MarkView/Resources/Editor/book.html" "${1:-/private/tmp/markview-book-pdf-checks}"
