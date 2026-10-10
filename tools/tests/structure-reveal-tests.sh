#!/bin/bash
# Runs the editor page's revealStructure (MarkView/Resources/Editor/vendor/js/markview-structured.js)
# against a tree shaped like the JSON / YAML viewer's output, in a WKWebView.
#   tools/tests/structure-reveal-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/StructureRevealTests.swift "$out/main.swift"
swiftc -O -o "$out/structure-reveal-tests" "$out/main.swift"
"$out/structure-reveal-tests"
