#!/bin/bash
# The window made of parts (AR-17): the shipping WindowComposition builds every part of a window in one place (each part made once, with the
# window's own project, tabs and task bag, and only when it is first used), joins the parts that react to each other's events (a saved
# file, a reloaded tab, a closed terminal or Insight tab, the GitHub repository, the app coming to the front) and ends everything the
# window started when it closes, over the shipping TaskBag. The parts and the window are compile-time stand-ins named like the real ones
# that keep what they were given and record what the window asked of them (WindowCompositionStubs.swift). Nothing is shown or started.
#   tools/tests/window-composition-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -o "$out/window-composition-tests" \
    MarkView/Models/Workspace/FileNode.swift MarkView/Models/Shared/FileType.swift MarkView/Models/Shared/ArchiveSupport.swift MarkView/Models/Workspace/WindowComposition.swift Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Shared/UserPrompts.swift tools/tests/ScriptedPrompts.swift \
    Packages/MarkViewCore/Tests/TestSupport/InsightSessionTestSupport.swift Packages/MarkViewCore/Tests/TestSupport/FeatureStoreTestSupport.swift tools/tests/WindowCompositionStubs.swift tools/tests/WindowCompositionTests.swift 2>&1 | head -80
"$out/window-composition-tests"
