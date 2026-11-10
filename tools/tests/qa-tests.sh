#!/bin/bash
# Feature end-to-end-qa: the scenario graph and its branches (Models/QAScenario.swift), the outcome of each check and the run report
# (QARun.swift) and where scenarios and runs live (QAStore.swift). Foundation only; compiled on its own with a test main (no XCTest
# target exists).
#   tools/tests/qa-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/QAChecks.swift "$out/main.swift"
swiftc -O -o "$out/qa" "$M/QAScenario.swift" "$M/QARun.swift" "$M/QAStore.swift" tools/tests/IssueChecksSupport.swift "$out/main.swift"
"$out/qa"
