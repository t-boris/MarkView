#!/bin/bash
# Feature workflow-templates, REQ-001..003: the template document and the shared folder that holds it (Models/Lifecycle/WorkflowTemplate.swift).
# Foundation only; compiled on its own with a test main (no XCTest target exists). It works in a temporary folder and never touches
# ~/Library/Application Support/MarkView.
#   tools/tests/workflow-template-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/WorkflowTemplateChecks.swift "$out/main.swift"
swiftc -O -o "$out/template" "$M/Lifecycle/FeatureVocabulary.swift" "$M/Lifecycle/IssueListing.swift" "$M/Lifecycle/ProjectWorkflow.swift" "$M/Lifecycle/IssueLifecycle.swift" \
    "$M/Lifecycle/DefinitionOfDone.swift" MarkView/Models/Workspace/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift "$M/Lifecycle/WorkflowDone.swift" "$M/Lifecycle/WorkflowDiagramLayout.swift" "$M/Lifecycle/WorkflowTransitionStory.swift" "$M/Lifecycle/WorkflowFlow.swift" "$M/Lifecycle/WorkflowTemplate.swift" "$out/main.swift"
"$out/template"
