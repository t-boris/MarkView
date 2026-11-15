#!/bin/bash
# The Markdown report of a research map (REQ-007): numbering, findings, links, connections, incomplete note.
#   tools/tests/research-map-export-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ResearchMapExportTests.swift "$out/main.swift"
swiftc -O -o "$out/research-map-export-tests" MarkView/Models/Workspace/FrontMatter.swift MarkView/Models/Research/ResearchDocument.swift \
    MarkView/Models/Research/ResearchMapDocument.swift MarkView/Models/Research/ResearchMapExport.swift "$out/main.swift"
"$out/research-map-export-tests"
