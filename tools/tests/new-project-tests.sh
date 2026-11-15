#!/bin/bash
# Checks the rules of Start a Project from Scratch (MarkView/Models/Workspace/NewProject.swift): draft record,
# folder and repository names, the confirmation gate, README/.gitignore, origin and publication
# checks. The app has no XCTest target: the module is compiled on its own with a test main and run.
#   tools/tests/new-project-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/NewProjectTests.swift "$out/main.swift"
swiftc -O -o "$out/new-project-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Workspace/NewProject.swift MarkView/Models/Workspace/ProjectDraftStore.swift MarkView/Models/Workspace/SchemaVersionedStore.swift \
    MarkView/Models/Git/GitHubClient.swift MarkView/Models/Lifecycle/EvidenceTimings.swift \
    MarkView/Models/Lifecycle/LifecycleCapture.swift tools/tests/CLIToolLocatorStub.swift tools/tests/StoreTestSupport.swift "$out/main.swift"
"$out/new-project-tests"
