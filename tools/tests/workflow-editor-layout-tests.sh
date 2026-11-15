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
    MarkView/Views/Lifecycle/WorkflowTabView.swift MarkView/Views/Lifecycle/WorkflowProposalBanner.swift MarkView/Models/Lifecycle/WorkflowProposal.swift MarkView/Models/Lifecycle/WorkflowDescription.swift MarkView/Models/Lifecycle/WorkflowEvents.swift MarkView/Views/Lifecycle/WorkflowDiagramView.swift MarkView/Models/Lifecycle/WorkflowDiagramLayout.swift MarkView/Models/Lifecycle/WorkflowTransitionStory.swift MarkView/Models/Lifecycle/WorkflowDone.swift MarkView/Models/Lifecycle/WorkflowFlow.swift MarkView/Models/Lifecycle/DefinitionOfDone.swift MarkView/Models/Workspace/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Views/Lifecycle/WorkflowDonePanel.swift MarkView/Views/Lifecycle/WorkflowFlowPicker.swift MarkView/Models/Lifecycle/WorkflowTemplate.swift MarkView/Models/Lifecycle/WorkflowTemplateLibrary.swift MarkView/Views/Lifecycle/WorkflowTemplatesSettings.swift MarkView/Views/Lifecycle/WorkflowProcessControls.swift MarkView/Models/Lifecycle/WorkflowEditorModel.swift MarkView/Models/Lifecycle/ProjectWorkflow.swift MarkView/Models/Lifecycle/ProjectWorkflowStore.swift \
    MarkView/Models/Lifecycle/IssueLifecycle.swift MarkView/Models/Lifecycle/FeatureVocabulary.swift MarkView/Models/Lifecycle/IssueLifecycleDisplay.swift MarkView/Models/Lifecycle/IssueLifecycleEvidence.swift MarkView/Models/Lifecycle/IssueTransitionLog.swift MarkView/Models/Lifecycle/IssueListing.swift MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift \
    MarkView/Models/Appearance/WindowTheme.swift MarkView/Views/Appearance/AppPalette.swift "$out/main.swift" -o "$out/layout-tests"
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/layout-tests"
