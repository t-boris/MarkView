#!/bin/bash
# Checks the AI side of research maps (MarkView/Models/ResearchMapRun.swift): the node-line parser,
# the guards that set the limits, and the prompts. Compiled on its own with a test main.
#   tools/tests/research-map-run-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ResearchMapRunTests.swift "$out/main.swift"
swiftc -O -o "$out/research-map-run-tests" MarkView/Models/FrontMatter.swift MarkView/Models/ResearchDocument.swift \
    MarkView/Models/ResearchMapDocument.swift MarkView/Models/ResearchMapRun.swift "$out/main.swift"
"$out/research-map-run-tests"
