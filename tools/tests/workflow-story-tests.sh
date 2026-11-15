#!/bin/bash
# BUG-115: a workflow transition in plain words (Models/Lifecycle/WorkflowTransitionStory.swift): the label of an arrow, what each actor may do
# and on which event, and what the processes require. Foundation only; compiled on its own with a test main (no XCTest target exists).
#   tools/tests/workflow-story-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/WorkflowStoryChecks.swift "$out/main.swift"
swiftc -O -o "$out/story" "$M/Lifecycle/FeatureVocabulary.swift" "$M/Lifecycle/IssueListing.swift" "$M/Lifecycle/ProjectWorkflow.swift" "$M/Lifecycle/IssueLifecycle.swift" \
    "$M/Lifecycle/WorkflowDiagramLayout.swift" "$M/Lifecycle/WorkflowTransitionStory.swift" "$out/main.swift"
"$out/story"
