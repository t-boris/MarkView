#!/bin/bash
# Feature workflow-flows, REQ-003: the catalogue of classic flows (Models/WorkflowFlow.swift). Foundation only; compiled on its own
# with a test main (no XCTest target exists).
#   tools/tests/workflow-flow-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/WorkflowFlowChecks.swift "$out/main.swift"
swiftc -O -o "$out/flow" "$M/Lifecycle/FeatureVocabulary.swift" "$M/Lifecycle/IssueListing.swift" "$M/Lifecycle/ProjectWorkflow.swift" "$M/Lifecycle/IssueLifecycle.swift" \
    "$M/Lifecycle/DefinitionOfDone.swift" MarkView/Models/Workspace/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift "$M/Lifecycle/WorkflowDone.swift" "$M/Lifecycle/WorkflowDiagramLayout.swift" "$M/Lifecycle/WorkflowTransitionStory.swift" "$M/Lifecycle/WorkflowFlow.swift" "$out/main.swift"
"$out/flow"
