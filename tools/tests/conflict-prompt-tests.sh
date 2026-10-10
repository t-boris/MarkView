#!/bin/bash
# Checks the prompt that hands Git conflicts to the assistant (MarkView/Models/ConflictPrompt.swift).
#   tools/tests/conflict-prompt-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ConflictPromptTests.swift "$out/main.swift"
swiftc -O -o "$out/conflict-prompt-tests" MarkView/Models/ConflictPrompt.swift "$out/main.swift"
"$out/conflict-prompt-tests"
