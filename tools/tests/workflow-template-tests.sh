#!/bin/bash
# Feature workflow-templates, REQ-001..003: the template document and the shared folder that holds it (Models/WorkflowTemplate.swift).
# Foundation only; compiled on its own with a test main (no XCTest target exists). It works in a temporary folder and never touches
# ~/Library/Application Support/MarkView.
#   tools/tests/workflow-template-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/WorkflowTemplateChecks.swift "$out/main.swift"
swiftc -O -o "$out/template" "$M/FeatureVocabulary.swift" "$M/IssueListing.swift" "$M/ProjectWorkflow.swift" "$M/IssueLifecycle.swift" \
    "$M/DefinitionOfDone.swift" "$M/WorkflowDone.swift" "$M/WorkflowDiagramLayout.swift" "$M/WorkflowTransitionStory.swift" "$M/WorkflowFlow.swift" "$M/WorkflowTemplate.swift" "$out/main.swift"
"$out/template"
