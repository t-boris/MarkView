#!/bin/bash
# Feature x-ray-comparison-by-date (REQ-001, REQ-002): the commits of a calendar day, chosen by the committer
#   time in the user's time zone from every local branch, and the source id that names the chosen commit.
#   The app has no XCTest target: the module (MarkView/Models/HistoricalBaseline.swift) is compiled on its own
#   with a test main and run, including a group that runs real git in a temporary repository.
#   tools/tests/historical-baseline-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/HistoricalBaselineTests.swift "$out/main.swift"
swiftc -O -o "$out/historical-baseline-tests" MarkView/Models/HistoricalBaseline.swift "$out/main.swift"
"$out/historical-baseline-tests"
