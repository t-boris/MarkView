#!/bin/bash
# Checks the definition-of-done checklist (MarkView/Models/Lifecycle/DefinitionOfDone.swift): the built-in items, the
# goal text for each mode, storage in .dde/, and how it joins the Implement with AI prompt. The app has no
# XCTest target: the modules are compiled on their own with a test main and run.
#   tools/tests/definition-of-done-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DefinitionOfDoneTests.swift "$out/main.swift"
swiftc -O -o "$out/definition-of-done-tests" MarkView/Models/Lifecycle/DefinitionOfDone.swift MarkView/Models/Workspace/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/Lifecycle/HandoffPrompt.swift tools/tests/StoreTestSupport.swift "$out/main.swift"
"$out/definition-of-done-tests"
