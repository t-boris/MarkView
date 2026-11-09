#!/bin/bash
# BUG-108: the shipping Workflow tab of the project window, hosted off screen (a borderless window far outside the display, never shown),
# measured at the sizes a person sees it. The view and the workflow model are compiled as they ship; the store is a stand-in
# inside the test file (no XCTest target exists).
#   tools/tests/workflow-editor-layout-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/WorkflowEditorLayoutTests.swift "$out/main.swift"
swiftc -suppress-warnings -target "$(uname -m)-apple-macos13.0" \
    MarkView/Views/WorkflowTabView.swift MarkView/Views/WorkflowDiagramView.swift MarkView/Models/WorkflowDiagramLayout.swift MarkView/Models/WorkflowTransitionStory.swift MarkView/Models/WorkflowDone.swift MarkView/Models/WorkflowFlow.swift MarkView/Models/DefinitionOfDone.swift MarkView/Views/WorkflowDonePanel.swift MarkView/Views/WorkflowFlowPicker.swift MarkView/Views/WorkflowProcessControls.swift MarkView/Models/WorkflowEditorModel.swift MarkView/Models/ProjectWorkflow.swift MarkView/Models/ProjectWorkflowStore.swift \
    MarkView/Models/IssueLifecycle.swift MarkView/Models/FeatureVocabulary.swift MarkView/Models/IssueLifecycleDisplay.swift MarkView/Models/IssueLifecycleEvidence.swift MarkView/Models/IssueTransitionLog.swift MarkView/Models/IssueListing.swift MarkView/Models/AppTheme.swift \
    MarkView/Models/WindowTheme.swift MarkView/Views/AppPalette.swift "$out/main.swift" -o "$out/layout-tests"
"$out/layout-tests"
