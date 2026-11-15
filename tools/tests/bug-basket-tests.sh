#!/bin/bash
# Checks the batch Fix with AI rules (MarkView/Models/Lifecycle/BugBasket.swift): basket membership and
# cleanup, the batch prompt, starting a batch (the `fixing` marks and their undo), and the "Suggest
# similar" answer. The app has no XCTest target: the module is compiled on its own (with
# HandoffPrompt.swift, DefinitionOfDone.swift and IssueListing.swift, which it uses) and run.
#   tools/tests/bug-basket-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BugBasketTests.swift "$out/main.swift"
swiftc -O -o "$out/bug-basket-tests" Packages/MarkViewCore/Sources/MarkViewCore/Settings.swift Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift MarkView/Models/Lifecycle/BugBasket.swift MarkView/Models/Lifecycle/HandoffPrompt.swift MarkView/Models/Lifecycle/DefinitionOfDone.swift MarkView/Models/Workspace/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/Lifecycle/IssueListing.swift MarkView/Models/AI/Providers/*.swift "$out/main.swift"
"$out/bug-basket-tests"
