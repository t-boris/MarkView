#!/bin/bash
# BUG-115: a workflow transition in plain words (Models/WorkflowTransitionStory.swift): the label of an arrow, what each actor may do
# and on which event, and what the processes require. Foundation only; compiled on its own with a test main (no XCTest target exists).
#   tools/tests/workflow-story-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/WorkflowStoryChecks.swift "$out/main.swift"
swiftc -O -o "$out/story" "$M/FeatureVocabulary.swift" "$M/IssueListing.swift" "$M/ProjectWorkflow.swift" "$M/IssueLifecycle.swift" \
    "$M/WorkflowDiagramLayout.swift" "$M/WorkflowTransitionStory.swift" "$out/main.swift"
"$out/story"
