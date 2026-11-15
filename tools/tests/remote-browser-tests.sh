#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/remote-browser-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/AgentTools/BrowserAgentTools.swift MarkView/Models/AgentTools/AgentToolServer.swift MarkView/Models/AgentTools/AgentToolWindow.swift \
    MarkView/Models/Browser/BrowserAgentTabs.swift MarkView/Models/Browser/BrowserAgentExecutor.swift MarkView/Models/AI/AgentToolsSetting.swift MarkView/Models/AI/Providers/AssistantMCP.swift MarkView/Models/Remote/RemoteBrowserRelay.swift \
    MarkView/Models/Remote/RemoteProtocol.swift MarkView/Models/Remote/RemoteWorkspaceTools.swift \
    MarkView/Models/Remote/RemoteWorkspace.swift MarkView/Models/Remote/RemoteCommand.swift \
    MarkView/Models/Terminal/PTYWriter.swift MarkView/Models/AI/AgentProcesses.swift \
    MarkView/Models/Cockpit/CockpitPlan.swift MarkView/Models/Cockpit/CockpitHostBridge.swift MarkView/Models/Cockpit/CockpitStepPolicy.swift \
    MarkView/Models/Cockpit/CockpitSupervisor.swift MarkView/Models/Cockpit/CockpitAgentRegistry.swift tools/tests/RemoteBrowserTests.swift
# Isolate browser preferences and control sockets from the user's running MarkView.
MARKVIEW_SOCKET_DIR="$out" "$out/remote-browser-tests" -ApplePersistenceIgnoreState YES
