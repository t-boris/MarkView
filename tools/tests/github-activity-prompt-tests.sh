#!/bin/bash
# Foundation-only checks for the GitHub activity prompt and weekday time-window arithmetic.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/GitHubActivityPromptTests.swift "$out/main.swift"
swiftc -o "$out/github-activity-prompt-tests" MarkView/Models/AIPrompts.swift \
    MarkView/Models/OutputLanguage.swift "$out/main.swift"
"$out/github-activity-prompt-tests"
