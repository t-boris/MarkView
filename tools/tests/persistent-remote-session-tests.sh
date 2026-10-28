#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
relay_pid=''
trap 'if [[ -n "$relay_pid" ]]; then kill "$relay_pid"; wait "$relay_pid" || true; fi; rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/persistent-remote-session-tests" \
    MarkView/Models/BrowserAgentTools.swift MarkView/Models/Remote/RemoteProtocol.swift \
    MarkView/Models/Remote/RemoteConnectionState.swift MarkView/Models/Remote/RemoteChannel.swift \
    MarkView/Models/Remote/RemoteFraming.swift MarkView/Models/Remote/RemoteWorkspace.swift \
    MarkView/Models/Remote/RemoteCommand.swift MarkView/Models/PTYWriter.swift MarkView/Models/AgentProcesses.swift \
    MarkView/Models/Remote/RemoteWorkspaceTools.swift MarkView/Models/Remote/RemoteToolBridge.swift \
    MarkView/Models/Remote/RemoteToolRequests.swift MarkView/Models/Remote/RemoteProviderConfiguration.swift \
    MarkView/Models/Remote/RemoteHostController.swift MarkView/Models/Remote/RemoteTerminalConnection.swift \
    tools/tests/PersistentRemoteSessionTests.swift
node tools/tests/persistent-remote-relay.mjs > "$out/relay.log" 2>&1 &
relay_pid=$!
for i in {1..50}; do
    if curl -sf http://127.0.0.1:16393/healthz >/dev/null; then break; fi
    sleep 0.1
done
"$out/persistent-remote-session-tests"
