#!/bin/bash
# Feature workflow-flows, REQ-001: what "done" means in a process and where it disagrees with the project's Definition of Done
# (Models/Lifecycle/WorkflowDone.swift). Foundation only; compiled on its own with a test main (no XCTest target exists).
#   tools/tests/workflow-done-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/WorkflowDoneChecks.swift "$out/main.swift"
swiftc -O -o "$out/done" "$M/Lifecycle/FeatureVocabulary.swift" "$M/Lifecycle/IssueListing.swift" "$M/Lifecycle/ProjectWorkflow.swift" "$M/Lifecycle/IssueLifecycle.swift" \
    "$M/Lifecycle/DefinitionOfDone.swift" MarkView/Models/Workspace/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift "$M/Lifecycle/WorkflowDone.swift" "$out/main.swift"
"$out/done"
