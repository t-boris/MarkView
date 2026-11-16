#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/UnderstandingAnswerTests.swift "$out/main.swift"
swiftc -O -o "$out/understanding-answer-tests" MarkView/Models/Workspace/FrontMatter.swift MarkView/Models/Architecture/UnderstandingAnswer.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift "$out/main.swift"
"$out/understanding-answer-tests"
