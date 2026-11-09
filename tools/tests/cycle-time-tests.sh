#!/bin/bash
# Feature cycle-time-as-a-view-over-the-workflow: the folding of journal records into stays and rounds, the metrics by role, the
# pace and the report (Models/CycleTime.swift, CycleTimeReport.swift) and the delivery evidence (EvidenceTimings.swift). Foundation only; compiled on its own with a test main (no
# XCTest target exists).
#   tools/tests/cycle-time-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/CycleTimeChecks.swift "$out/main.swift"
swiftc -O -o "$out/cycle-time" "$M/FeatureVocabulary.swift" "$M/IssueListing.swift" "$M/ProjectWorkflow.swift" "$M/IssueLifecycle.swift" \
    "$M/DefinitionOfDone.swift" "$M/WorkflowDone.swift" "$M/WorkflowDiagramLayout.swift" "$M/WorkflowTransitionStory.swift" "$M/WorkflowFlow.swift" \
    "$M/IssueTransitionLog.swift" "$M/EvidenceTimings.swift" "$M/CycleTime.swift" "$M/CycleTimeReport.swift" tools/tests/IssueChecksSupport.swift "$out/main.swift"
"$out/cycle-time"
