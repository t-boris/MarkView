#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/markview-remote-test-modules" -o "$out/remote-workspace-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Remote/RemoteProtocol.swift \
    MarkView/Models/Remote/RemoteFraming.swift \
    MarkView/Models/Remote/RemoteWorkspace.swift \
    MarkView/Models/Remote/RemoteCommand.swift \
    \
    MarkView/Models/AgentTools/BrowserAgentTools.swift \
    MarkView/Models/Remote/RemoteWorkspaceTools.swift \
    MarkView/Models/Remote/RemoteToolBridge.swift \
    MarkView/Models/Remote/RemoteProviderConfiguration.swift MarkView/Models/AI/Providers/*.swift \
    tools/tests/RemoteWorkspaceTests.swift
"$out/remote-workspace-tests" "$@"
swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/markview-remote-test-modules" -o "$out/remote-channel-tests" \
    MarkView/Models/Remote/RemoteProtocol.swift MarkView/Models/Remote/RemoteFraming.swift \
    MarkView/Models/Remote/RemoteChannel.swift MarkView/Models/Remote/RemoteToolRequests.swift tools/tests/RemoteChannelTests.swift
"$out/remote-channel-tests"
if [ "${MARKVIEW_REMOTE_SKIP_DUPLICATE_PURE:-0}" != 1 ]; then
    bash tools/tests/remote-relay-settings-tests.sh
fi
bash tools/tests/terminal-child-tests.sh
node --test tools/remote-relay/*.test.mjs
