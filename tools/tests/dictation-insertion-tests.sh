#!/bin/bash
# Checks how a dictated transcript is inserted into a text field (DictationInsertion in
# MarkView/Views/DictationViews.swift). Hidden NSTextView fixtures supply selections; no recording or app activation.
# Only the enum is compiled, not the app.
#   tools/tests/dictation-insertion-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
{ echo 'import AppKit'; awk '/^enum DictationInsertion/,0' MarkView/Views/DictationViews.swift; } > "$out/Insertion.swift"
cp tools/tests/DictationInsertionTests.swift "$out/main.swift"
swiftc -O -o "$out/dictation-insertion-tests" "$out/Insertion.swift" "$out/main.swift"
"$out/dictation-insertion-tests"
