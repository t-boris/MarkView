#!/bin/bash
# Checks the Issues list filter and sort rules (MarkView/Models/IssueListing.swift): status
# mapping, filter combination, date and priority order, persisted values. The app has no XCTest
# target: the module is compiled on its own with a test main and run.
#   tools/tests/issue-listing-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/IssueListingTests.swift "$out/main.swift"
swiftc -O -o "$out/issue-listing-tests" MarkView/Models/IssueListing.swift "$out/main.swift"
"$out/issue-listing-tests"
