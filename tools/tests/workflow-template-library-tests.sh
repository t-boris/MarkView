#!/bin/bash
# The workflow templates as the windows see them (AR-19): the shipping WorkflowTemplateLibrary over a real WorkflowTemplateStore in a
# temporary folder. A change (save, delete, choose the default) is started and returns at once, its answer comes when the folder was
# written and the list read again, and a change of the same kind asked for meanwhile replaces it. The real folder of the app is never read.
#   tools/tests/workflow-template-library-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -o "$out/library-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    "$M/Lifecycle/FeatureVocabulary.swift" "$M/Lifecycle/IssueListing.swift" "$M/Lifecycle/ProjectWorkflow.swift" "$M/Lifecycle/IssueLifecycle.swift" \
    "$M/Lifecycle/DefinitionOfDone.swift" "$M/Shared/SchemaVersionedStore.swift" "$M/Lifecycle/WorkflowDone.swift" \
    "$M/Lifecycle/WorkflowDiagramLayout.swift" "$M/Lifecycle/WorkflowTransitionStory.swift" "$M/Lifecycle/WorkflowFlow.swift" \
    "$M/Lifecycle/WorkflowTemplate.swift" "$M/Lifecycle/WorkflowTemplateLibrary.swift" tools/tests/WorkflowTemplateLibraryChecks.swift
"$out/library-tests"
