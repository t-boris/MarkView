#!/bin/bash
# Checks the pure part of translating a research map (MarkView/Models/Research/ResearchMapTranslation.swift, REQ-014, DEC-015):
# the request, reading and checking the AI's answer, applying it without touching the map's structure, the Mermaid skeleton
# and the file names of a translated map. The app has no XCTest target: the module is compiled on its own with a test main.
#   tools/tests/research-map-translation-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ResearchMapTranslationTests.swift "$out/main.swift"
swiftc -O -o "$out/research-map-translation-tests" MarkView/Models/Workspace/FrontMatter.swift MarkView/Models/Research/ResearchDocument.swift \
    MarkView/Models/Research/ResearchMapDocument.swift MarkView/Models/Research/ResearchMapTranslation.swift MarkView/Models/AI/AIOperation.swift tools/tests/AIOperationStub.swift "$out/main.swift"
"$out/research-map-translation-tests"
