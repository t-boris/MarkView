#!/bin/bash
# Feature end-to-end-qa: the scenario graph and its branches (Models/QAScenario.swift), the outcome of each check and the run report
# (QARun.swift), where scenarios and runs live (QAStore.swift) the reading of what the AI wrote (QAGeneration.swift) and the tries to get it right (QAGenerator.swift), what a run would do and the gate that approves it (QAPlan.swift, QAGate.swift), what the assistant is asked at each turn of a step and the run itself (QAActions.swift, QARunner.swift), the edits of a scenario (QAScenarioEdit.swift) and where its steps are drawn (QAGraphLayout.swift). Foundation only; compiled on its own with a test main (no XCTest
# target exists).
#   tools/tests/qa-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/QAChecks.swift "$out/main.swift"
swiftc -O -o "$out/qa" "$M/QA/QAAPI.swift" "$M/QA/QAScenario.swift" "$M/QA/QARun.swift" "$M/QA/QAStore.swift" MarkView/Models/Workspace/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift "$M/QA/QAGeneration.swift" "$M/QA/QAGenerator.swift" "$M/AI/AIOperation.swift" tools/tests/AIOperationStub.swift "$M/QA/QAPlan.swift" "$M/QA/QAGate.swift" "$M/Cockpit/CockpitPlan.swift" "$M/Cockpit/CockpitQAReview.swift" "$M/QA/QAEffort.swift" "$M/QA/QATriage.swift" "$M/QA/QAInputMark.swift" "$M/QA/QAActions.swift" "$M/QA/QARunner.swift" "$M/QA/QALanguage.swift" "$M/QA/QAPageEvidence.swift" "$M/QA/QACredentials.swift" "$M/QA/QAScenarioEdit.swift" "$M/QA/QAAttachments.swift" "$M/QA/QAGraphLayout.swift" tools/tests/IssueChecksSupport.swift tools/tests/StoreTestSupport.swift "$out/main.swift"
"$out/qa"
