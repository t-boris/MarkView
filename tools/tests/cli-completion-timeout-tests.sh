#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/completion-timeout-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/AI/CLICompletion.swift MarkView/Models/AI/ACPAssistant.swift \
    MarkView/Models/AI/Providers/*.swift \
    tools/tests/CLICompletionTestSupport.swift tools/tests/CLICompletionTimeoutTests.swift
"$out/completion-timeout-tests"
