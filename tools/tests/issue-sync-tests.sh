#!/bin/bash
# Checks the Sync link, eligibility and report rules (MarkView/Models/IssueSync.swift). The app has
# no XCTest target: the module is compiled on its own with a test main and run.
#   tools/tests/issue-sync-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/IssueSyncTests.swift "$out/main.swift"
swiftc -O -o "$out/issue-sync-tests" MarkView/Models/IssueListing.swift MarkView/Models/IssueSync.swift "$out/main.swift"
"$out/issue-sync-tests"
