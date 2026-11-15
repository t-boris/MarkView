#!/bin/bash
# Checks the project tools agents use to read and extend a MarkView project (MarkView/Models/AgentTools/ProjectAgentTools.swift):
# tool list, guide, validation, file bodies, MCP answers, real --mcp-project and --project-call processes, and
# "no app, no tools". The modules are compiled on their own with a test main and run.
#   tools/tests/project-agent-tools-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ProjectAgentToolsTests.swift "$out/main.swift"
swiftc -O -o "$out/project-agent-tools-tests" Packages/MarkViewCore/Sources/MarkViewCore/PrivateSocket.swift MarkView/Models/AgentTools/BrowserAgentTools.swift MarkView/Models/Lifecycle/FeatureVocabulary.swift MarkView/Models/AgentTools/DeploymentAgentTools.swift MarkView/Models/AgentTools/DiscussionAgentTools.swift MarkView/Models/Lifecycle/IssueListing.swift MarkView/Models/Lifecycle/ProjectWorkflow.swift MarkView/Models/Lifecycle/IssueLifecycle.swift MarkView/Models/Lifecycle/IssueTransitionLog.swift MarkView/Models/Lifecycle/IssueLifecycleContext.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/Lifecycle/WorkflowEvents.swift MarkView/Models/Lifecycle/WorkflowDescription.swift MarkView/Models/AgentTools/ProjectAgentTools.swift "$out/main.swift"
# The control sockets live in one folder: a private one keeps a MarkView running on this Mac out of the checks.
mkdir "$out/sockets"
MARKVIEW_SOCKET_DIR="$out/sockets" "$out/project-agent-tools-tests"
