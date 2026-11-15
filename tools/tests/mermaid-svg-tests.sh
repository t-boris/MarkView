#!/bin/bash
# FU-20: Mermaid keeps its theme in a <style> element inside every SVG. The shipped editor page (MarkView/Resources/Editor)
# draws real diagrams in real WebKit (hidden window): they keep the colours and labels Mermaid drew, sixteen kinds of diagram
# lose no declaration, hostile SVG is neutralised, and <style> stays forbidden in the Markdown, Book, Discussion and Insight
# profiles.
#   tools/tests/mermaid-svg-tests.sh [editor folder]     (default: MarkView/Resources/Editor)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/MermaidSvgWebTests.swift "$out/main.swift"
swiftc -O -o "$out/mermaid-svg-web-tests" "$out/main.swift"
"$out/mermaid-svg-web-tests" "${1:-$PWD/MarkView/Resources/Editor}"
