#!/bin/bash
# Checks the decision table of the automatic code analysis refresh
# (MarkView/Models/AutoAnalysisScheduler.swift, DEC-003 of automatic-code-architecture).
# The app has no XCTest target: the module is compiled on its own with a test main and run.
#   tools/tests/auto-analysis-scheduler-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/AutoAnalysisSchedulerTests.swift "$out/main.swift"
swiftc -O -o "$out/scheduler-tests" MarkView/Models/AutoAnalysisScheduler.swift "$out/main.swift"
"$out/scheduler-tests"
