#!/bin/bash
# Checks the Implement / Fix with AI prompts (MarkView/Models/HandoffPrompt.swift, BUG-011). The app
# has no XCTest target: the module is compiled on its own with a test main and run.
#   tools/tests/handoff-prompt-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/HandoffPromptTests.swift "$out/main.swift"
swiftc -O -o "$out/handoff-prompt-tests" MarkView/Models/HandoffPrompt.swift "$out/main.swift"
"$out/handoff-prompt-tests"
