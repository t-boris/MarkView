#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/completion-timeout-tests" \
    MarkView/Models/CLICompletion.swift MarkView/Models/ACPAssistant.swift \
    MarkView/Models/AgentProcesses.swift \
    tools/tests/CLICompletionTestSupport.swift tools/tests/CLICompletionTimeoutTests.swift
"$out/completion-timeout-tests"
