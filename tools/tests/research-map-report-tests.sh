#!/bin/bash
# Checks the narrative report of a research map (MarkView/Models/ResearchMapReport.swift): the request to the model, the
# reading of its answer, the guards (coverage, citations, placeholders, not a node-by-node list, nothing invented) and the
# assembly with the Sources list. ResearchMapExport.swift is compiled too: the old one-to-one report is the shape the guards
# must reject. The module is compiled on its own with a test main and run.
#   tools/tests/research-map-report-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ResearchMapReportTests.swift "$out/main.swift"
swiftc -O -o "$out/research-map-report-tests" MarkView/Models/FrontMatter.swift MarkView/Models/ResearchDocument.swift \
    MarkView/Models/ResearchMapDocument.swift MarkView/Models/ResearchMapExport.swift MarkView/Models/ResearchMapReport.swift "$out/main.swift"
"$out/research-map-report-tests"
