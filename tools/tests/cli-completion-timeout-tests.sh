#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Live Copilot remains an explicit manual mode; automatic checks use the isolated app host.
if [ -z "${MARKVIEW_COMPLETION_LIVE_COPILOT:-}" ]; then
    exec bash tools/tests/cli-completion-timeout-host-tests.sh
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/completion-timeout-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/AI/CLICompletion.swift MarkView/Models/AI/ACPAssistant.swift \
    MarkView/Models/AI/Providers/*.swift \
    Packages/MarkViewCore/Tests/TestSupport/SemanticDatabaseTestSupport.swift tools/tests/CLICompletionTestSupport.swift tools/tests/CLICompletionTimeoutTests.swift
"$out/completion-timeout-tests"
