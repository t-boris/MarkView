#!/bin/bash
# Checks the research document format (MarkView/Models/ResearchDocument.swift): path, template,
# fact/inference labels, follow-ups, retries, status and comment sections. The app has no XCTest
# target: the module is compiled on its own with a test main and run.
#   tools/tests/research-document-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ResearchDocumentTests.swift "$out/main.swift"
swiftc -O -o "$out/research-document-tests" MarkView/Models/FrontMatter.swift MarkView/Models/ResearchDocument.swift "$out/main.swift"
"$out/research-document-tests"
