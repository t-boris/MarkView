#!/bin/bash
# Checks the research map format and rules (MarkView/Models/ResearchMapDocument.swift): the Markdown
# file, parsing of hand-edited files, every operation of the map, layouts and the page snapshot.
# The app has no XCTest target: the module is compiled on its own with a test main and run.
#   tools/tests/research-map-document-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ResearchMapDocumentTests.swift "$out/main.swift"
swiftc -O -o "$out/research-map-document-tests" MarkView/Models/FrontMatter.swift MarkView/Models/ResearchDocument.swift \
    MarkView/Models/ResearchMapDocument.swift "$out/main.swift"
"$out/research-map-document-tests"
