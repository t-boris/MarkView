#!/bin/bash
# Checks that quitting stops the assistants of headless runs (MarkView/Models/AgentProcesses.swift): a normal
# process ends at once, one that ignores SIGTERM is killed after the grace period, finished ones are forgotten.
#   tools/tests/agent-processes-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/AgentProcessesTests.swift "$out/main.swift"
swiftc -O -o "$out/agent-processes-tests" MarkView/Models/AgentProcesses.swift "$out/main.swift"
"$out/agent-processes-tests"
