#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/markview-remote-test-modules" -o "$out/remote-codex-context-tests" \
    MarkView/Models/Remote/RemoteProtocol.swift MarkView/Models/Remote/RemoteCommand.swift \
    MarkView/Models/Terminal/PTYWriter.swift MarkView/Models/AI/AgentProcesses.swift \
    Packages/MarkViewCore/Sources/MarkViewCore/PrivateSocket.swift \
    MarkView/Models/AgentTools/BrowserAgentTools.swift \
    MarkView/Models/Remote/RemoteWorkspaceTools.swift MarkView/Models/Remote/RemoteProviderConfiguration.swift \
    MarkView/Models/Remote/RemoteCodexContext.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift tools/tests/RemoteCodexContextTests.swift
"$out/remote-codex-context-tests"
