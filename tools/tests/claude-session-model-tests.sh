#!/bin/bash
# Checks how the model of a running Claude Code session is read from its log lines
# (ClaudeSessionModel in MarkView/Models/ClaudeSessionModel.swift): replies of the session,
# /model confirmations, subagents, lines from before the agent started. Only the pure enum is
# compiled, not the app.
#   tools/tests/claude-session-model-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp MarkView/Models/ClaudeSessionModel.swift "$out/Model.swift"
cp tools/tests/ClaudeSessionModelTests.swift "$out/main.swift"
swiftc -O -o "$out/claude-session-model-tests" "$out/Model.swift" "$out/main.swift"
"$out/claude-session-model-tests"
