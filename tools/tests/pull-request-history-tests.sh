#!/bin/bash
# BUG-034: "I Need to Understand" ran `gh pr list` while the GitHub integration was off.
#   The pull-request part of the history context (MarkView/Models/PullRequestHistory.swift) must not call
#   `gh` unless the integration is on, and must say that no PR data was available otherwise.
#   The app has no XCTest target: the module is compiled on its own with a test main and run.
#   tools/tests/pull-request-history-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PullRequestHistoryTests.swift "$out/main.swift"
swiftc -O -o "$out/pull-request-history-tests" MarkView/Models/PullRequestHistory.swift "$out/main.swift"
"$out/pull-request-history-tests"
