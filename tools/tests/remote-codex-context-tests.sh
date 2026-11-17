#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/markview-remote-test-modules" -o "$out/remote-codex-context-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Remote/RemoteProtocol.swift MarkView/Models/Remote/RemoteCommand.swift \
    MarkView/Models/Terminal/PTYWriter.swift \
    MarkView/Models/AgentTools/BrowserAgentTools.swift \
    MarkView/Models/Remote/RemoteWorkspaceTools.swift MarkView/Models/Remote/RemoteProviderConfiguration.swift MarkView/Models/AI/Providers/*.swift \
    MarkView/Models/Remote/RemoteCodexContext.swift tools/tests/RemoteCodexContextTests.swift
"$out/remote-codex-context-tests"
