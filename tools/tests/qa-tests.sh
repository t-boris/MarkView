#!/bin/bash
# Feature end-to-end-qa: the scenario graph and its branches (Models/QAScenario.swift), the outcome of each check and the run report
# (QARun.swift), where scenarios and runs live (QAStore.swift) the reading of what the AI wrote (QAGeneration.swift) and the tries to get it right (QAGenerator.swift), the edits of a scenario (QAScenarioEdit.swift) and where its steps are drawn (QAGraphLayout.swift). Foundation only; compiled on its own with a test main (no XCTest
# target exists).
#   tools/tests/qa-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/QAChecks.swift "$out/main.swift"
swiftc -O -o "$out/qa" "$M/QAScenario.swift" "$M/QARun.swift" "$M/QAStore.swift" "$M/QAGeneration.swift" "$M/QAGenerator.swift" "$M/QAScenarioEdit.swift" "$M/QAGraphLayout.swift" tools/tests/IssueChecksSupport.swift "$out/main.swift"
"$out/qa"
