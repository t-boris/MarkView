#!/bin/bash
# BUG-112: the geometry of the transition state diagram (Models/WorkflowDiagramLayout.swift): lanes, states, arrows, hit testing and
# what an arrow drawn between two states means. Foundation only; compiled on its own with a test main (no XCTest target exists).
#   tools/tests/workflow-diagram-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/WorkflowDiagramChecks.swift "$out/main.swift"
swiftc -O -o "$out/diagram" "$M/FeatureVocabulary.swift" "$M/IssueListing.swift" "$M/ProjectWorkflow.swift" "$M/IssueLifecycle.swift" \
    "$M/WorkflowDiagramLayout.swift" "$out/main.swift"
"$out/diagram"
