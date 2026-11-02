#!/bin/bash
# BUG-031: Cmd+S wrote one tab's text over another tab's file.
#   1. Which tab a message from the editor page is applied to (MarkView/Models/EditorDocumentRouting.swift).
#      The app has no XCTest target: the module is compiled on its own with a test main and run.
#   2. The shipped editor page names the tab whose document it shows in every message (real WebKit, headless).
#   tools/tests/editor-document-routing-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/EditorDocumentRoutingTests.swift "$out/main.swift"
swiftc -O -o "$out/editor-document-routing-tests" MarkView/Models/EditorDocumentRouting.swift "$out/main.swift"
"$out/editor-document-routing-tests"
mkdir "$out/web"
cp tools/tests/EditorDocumentIdWebTests.swift "$out/web/main.swift"
swiftc -O -o "$out/editor-document-id-web-tests" "$out/web/main.swift"
"$out/editor-document-id-web-tests" "$PWD/MarkView/Resources/Editor"
