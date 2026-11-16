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
swiftc -O -o "$out/cycle-time" "$M/Lifecycle/FeatureVocabulary.swift" "$M/Lifecycle/IssueListing.swift" "$M/Lifecycle/ProjectWorkflow.swift" "$M/Lifecycle/IssueLifecycle.swift" \
    "$M/Lifecycle/DefinitionOfDone.swift" MarkView/Models/Shared/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/StoredJSON.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift "$M/Lifecycle/WorkflowDone.swift" "$M/Lifecycle/WorkflowDiagramLayout.swift" "$M/Lifecycle/WorkflowTransitionStory.swift" "$M/Lifecycle/WorkflowFlow.swift" \
    "$M/Lifecycle/IssueTransitionLog.swift" "$M/Lifecycle/EvidenceTimings.swift" "$M/Lifecycle/CycleTime.swift" "$M/Lifecycle/CycleTimeReport.swift" tools/tests/IssueChecksSupport.swift tools/tests/StoreTestSupport.swift "$out/main.swift"
"$out/cycle-time"
