#!/bin/bash
# Checks the agent usage rules (MarkView/Models/AI/Providers/AgentUsage.swift) and the local log reader
# (MarkView/Models/AI/Providers/AgentUsageLogs.swift). The app has no XCTest target: the modules are compiled
# on their own with a test main and run.
#   tools/tests/agent-usage-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/AgentUsageTests.swift "$out/main.swift"
swiftc -O -o "$out/agent-usage-tests" MarkView/Models/AI/Providers/*.swift "$out/main.swift"
"$out/agent-usage-tests"
