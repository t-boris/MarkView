#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/markview-remote-test-modules" -o "$out/remote-codex-context-tests" \
    MarkView/Models/Remote/RemoteProtocol.swift MarkView/Models/Remote/RemoteCommand.swift \
    MarkView/Models/PTYWriter.swift MarkView/Models/AgentProcesses.swift MarkView/Models/BrowserAgentTools.swift \
    MarkView/Models/Remote/RemoteWorkspaceTools.swift MarkView/Models/Remote/RemoteProviderConfiguration.swift \
    MarkView/Models/Remote/RemoteCodexContext.swift tools/tests/RemoteCodexContextTests.swift
"$out/remote-codex-context-tests"
