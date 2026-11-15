#!/bin/bash
# Checks the control tools an outside agent uses to run MarkView (MarkView/Models/AgentTools/ControlAgentTools.swift): tool list,
# window and terminal choice, keys, waits, the advice on what to do next, MCP answers, and real --mcp-control processes
# against stand-ins for the app (no app, one app, two running MarkViews). The modules are compiled on their own with a
# test main and run.
#   tools/tests/control-agent-tools-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ControlAgentToolsTests.swift "$out/main.swift"
swiftc -O -o "$out/control-agent-tools-tests" Packages/MarkViewCore/Sources/MarkViewCore/PrivateSocket.swift MarkView/Models/AgentTools/BrowserAgentTools.swift MarkView/Models/Lifecycle/FeatureVocabulary.swift MarkView/Models/AgentTools/DeploymentAgentTools.swift MarkView/Models/AgentTools/DiscussionAgentTools.swift MarkView/Models/Lifecycle/IssueListing.swift MarkView/Models/Lifecycle/ProjectWorkflow.swift MarkView/Models/Lifecycle/IssueLifecycle.swift MarkView/Models/Lifecycle/IssueTransitionLog.swift MarkView/Models/Lifecycle/IssueLifecycleContext.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/Lifecycle/WorkflowEvents.swift MarkView/Models/Lifecycle/WorkflowDescription.swift MarkView/Models/AgentTools/ProjectAgentTools.swift MarkView/Models/AgentTools/ControlAgentTools.swift "$out/main.swift"
# The control sockets live in one folder: a private one keeps a MarkView running on this Mac out of the checks.
mkdir "$out/sockets"
MARKVIEW_SOCKET_DIR="$out/sockets" "$out/control-agent-tools-tests"
