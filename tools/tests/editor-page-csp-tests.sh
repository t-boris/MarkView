#!/bin/bash
# FU-26: the editor page's Content-Security-Policy takes the per-load nonce through EditorPage (the function EditorView calls),
# the page loads the way the app loads it in real WebKit (hidden window), the Insight frame runs under that policy, and a page
# whose policy cannot take the nonce fails closed instead of leaving the Insight view blank without a trace.
#   tools/tests/editor-page-csp-tests.sh [editor folder]     (default: MarkView/Resources/Editor)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/EditorPageCSPTests.swift "$out/main.swift"
swiftc -suppress-warnings -target "$(uname -m)-apple-macos13.0" -o "$out/editor-page-csp-tests" \
    MarkView/Models/Workspace/EditorPage.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift MarkView/Models/Workspace/EditorWindowPrefs.swift "$out/main.swift"
"$out/editor-page-csp-tests" "${1:-$PWD/MarkView/Resources/Editor}"
