#!/bin/bash
# BUG-109: the line diff behind the review of observed file changes (hunks, line numbers, location, section) and the request for
# the assistant's explanation of each change.
#   tools/tests/text-diff-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/TextDiffChecks.swift "$out/main.swift"
swiftc -suppress-warnings -O -target "$(uname -m)-apple-macos13.0" MarkView/Models/TextDiff.swift MarkView/Models/ChangeExplanation.swift MarkView/Models/OutputLanguage.swift "$out/main.swift" -o "$out/text-diff-tests"
"$out/text-diff-tests"
