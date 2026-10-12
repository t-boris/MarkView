#!/bin/bash
# Checks the readers of the assistants' session logs (MarkView/Models/AgentActivity.swift).
#   tools/tests/agent-activity-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/AgentActivityTests.swift "$out/main.swift"
swiftc -o "$out/agent-activity-tests" -lsqlite3 MarkView/Models/AgentActivity.swift "$out/main.swift"
"$out/agent-activity-tests"
