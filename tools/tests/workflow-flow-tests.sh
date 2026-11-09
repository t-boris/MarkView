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
swiftc -O -o "$out/flow" "$M/FeatureVocabulary.swift" "$M/IssueListing.swift" "$M/ProjectWorkflow.swift" "$M/IssueLifecycle.swift" \
    "$M/DefinitionOfDone.swift" "$M/WorkflowDone.swift" "$M/WorkflowDiagramLayout.swift" "$M/WorkflowTransitionStory.swift" "$M/WorkflowFlow.swift" "$out/main.swift"
"$out/flow"
