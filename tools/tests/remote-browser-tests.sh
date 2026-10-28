#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/remote-browser-tests" \
    MarkView/Models/BrowserAgentTools.swift MarkView/Models/BrowserControlServer.swift \
    MarkView/Models/Remote/RemoteProtocol.swift MarkView/Models/Remote/RemoteWorkspaceTools.swift \
    MarkView/Models/Remote/RemoteWorkspace.swift MarkView/Models/Remote/RemoteCommand.swift \
    MarkView/Models/PTYWriter.swift MarkView/Models/AgentProcesses.swift tools/tests/RemoteBrowserTests.swift
# Isolate browser preferences and control sockets from the user's running MarkView.
MARKVIEW_SOCKET_DIR="$out" "$out/remote-browser-tests" -ApplePersistenceIgnoreState YES
