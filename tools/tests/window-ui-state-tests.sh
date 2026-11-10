#!/bin/bash
# Checks that one window's interface state never reaches another window: WindowUIState (behind @WindowStorage), the editor page's own
# choices (EditorWindowPrefs) and the per-project excluded folders. The app has no XCTest target: the production modules are
# compiled on their own with a test main and run.
#   tools/tests/window-ui-state-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/WindowUIStateTests.swift "$out/main.swift"
swiftc -suppress-warnings -target "$(uname -m)-apple-macos13.0" -o "$out/window-ui-state-tests" \
    MarkView/Models/WindowUIState.swift MarkView/Views/WindowStorage.swift MarkView/Models/EditorWindowPrefs.swift \
    MarkView/Models/ExcludedFolders.swift "$out/main.swift"
"$out/window-ui-state-tests"
