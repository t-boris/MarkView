#!/bin/bash
# Foundation-only checks for the GitHub activity prompt and weekday time-window arithmetic.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/GitHubActivityPromptTests.swift "$out/main.swift"
swiftc -o "$out/github-activity-prompt-tests" Packages/MarkViewCore/Sources/MarkViewCore/Settings.swift Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift MarkView/Models/AI/AIPrompts.swift \
    MarkView/Models/AI/OutputLanguage.swift "$out/main.swift"
"$out/github-activity-prompt-tests"
