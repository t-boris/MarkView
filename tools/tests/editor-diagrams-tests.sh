#!/bin/bash
# BUG-105: a Markdown document with hundreds of Mermaid diagrams froze the editor page for about a minute.
# The shipped editor page (MarkView/Resources/Editor) draws the diagrams of a large document in real WebKit (headless):
# every diagram is drawn, the page keeps answering, a broken diagram does not stop the others, a document that replaces
# another stops the drawing of the old one, and the reading position survives.
#   tools/tests/editor-diagrams-tests.sh [editor folder]     (default: MarkView/Resources/Editor)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/EditorDiagramsWebTests.swift "$out/main.swift"
swiftc -O -o "$out/editor-diagrams-web-tests" "$out/main.swift"
"$out/editor-diagrams-web-tests" "${1:-$PWD/MarkView/Resources/Editor}"
