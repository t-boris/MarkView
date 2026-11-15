#!/bin/bash
# Manual check against the REAL assistant (not part of the automatic checks): runs a real UI Studio session on a COPY of an application
# and prints what Studio repaired by itself (REQ-020) or prepared ahead (REQ-021), how long it took and what the assistant cost.
#   tools/tests/ui-studio-live-run.sh <project copy> repair|screens|load|review [scenario name]
#   load: only opens the scenario, then prints the page text, the problems and each saved scenario's compatibility (no assistant call).
# Make the copy with `cp -cR <project> <copy>` (an APFS clone: instant, and nothing in the original is touched). The assistant is the one
# the app uses (`~/Library/Application Support/MarkView/ai-calls.jsonl` records every call).
set -euo pipefail
cd "$(dirname "$0")/../.."
[ $# -ge 2 ] || { echo "usage: $0 <project copy> repair|screens|load|review [scenario name]"; exit 2; }
export PYTHONDONTWRITEBYTECODE=1
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/UIStudioLiveRun.swift "$out/main.swift"
swiftc -o "$out/ui-studio-live-run" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
  MarkView/Models/UIStudio/UIStudioJSON.swift MarkView/Models/UIStudio/UIStudioModels.swift MarkView/Models/UIStudio/UIStudioSimulation.swift MarkView/Models/UIStudio/UIStudioAuthMock.swift \
  MarkView/Models/UIStudio/UIStudioRedaction.swift MarkView/Models/UIStudio/UIStudioLog.swift MarkView/Models/UIStudio/UIStudioPreparation.swift MarkView/Models/UIStudio/UIStudioBridge.swift \
  MarkView/Models/UIStudio/UIStudioChanges.swift MarkView/Models/UIStudio/UIStudioStore.swift MarkView/Models/Workspace/SchemaVersionedStore.swift MarkView/Models/UIStudio/UIStudioEvidence.swift \
  MarkView/Models/UIStudio/UIStudioPrompts.swift MarkView/Models/UIStudio/UIStudioContext.swift MarkView/Models/UIStudio/UIStudioSelection.swift MarkView/Models/UIStudio/UIStudioPolicy.swift \
  MarkView/Models/UIStudio/UIStudioGateway.swift MarkView/Models/UIStudio/UIStudioServer.swift MarkView/Models/UIStudio/UIStudioConnections.swift MarkView/Models/UIStudio/UIStudioAgents.swift \
  MarkView/Models/UIStudio/UIStudioSession.swift MarkView/Models/Browser/BrowserElementPick.swift MarkView/Models/Workspace/WebAppPreview.swift \
  MarkView/Models/Workspace/FrontMatter.swift MarkView/Models/Lifecycle/FeatureVocabulary.swift MarkView/Models/Lifecycle/IssueListing.swift MarkView/Models/Lifecycle/ProjectWorkflow.swift MarkView/Models/Lifecycle/IssueLifecycle.swift MarkView/Models/Lifecycle/IssueTransitionLog.swift MarkView/Models/Lifecycle/BugReportWriter.swift MarkView/Models/UIStudio/UIStudioTracking.swift MarkView/Models/UIStudio/UIStudioSession+Tracking.swift \
  MarkView/Models/Workspace/ImageAttachments.swift \
  MarkView/Models/UIStudio/UIStudioEnvironmentMap.swift MarkView/Models/UIStudio/UIStudioEnvironmentMapper.swift \
  MarkView/Models/UIStudio/UIStudioGraphQL.swift MarkView/Models/UIStudio/UIStudioChannels.swift \
  MarkView/Models/UIStudio/UIStudioGatewayStreams.swift MarkView/Models/UIStudio/UIStudioRealtimePrompts.swift MarkView/Models/UIStudio/UIStudioDataFix.swift MarkView/Models/UIStudio/UIStudioRepair.swift MarkView/Models/UIStudio/UIStudioScreens.swift MarkView/Models/UIStudio/UIStudioReview.swift MarkView/Models/UIStudio/UIStudioSession+Repair.swift MarkView/Models/UIStudio/UIStudioSession+Screens.swift MarkView/Models/UIStudio/UIStudioSession+Review.swift \
  MarkView/Views/UIStudio/UIStudioPreviewHost.swift MarkView/Models/AI/AIAssistants.swift MarkView/Models/AI/Providers/*.swift MarkView/Models/Appearance/ProjectColor.swift MarkView/Models/Workspace/LinkedFolders.swift MarkView/Models/AI/AICallLog.swift \
  MarkView/Models/AI/AIOperation.swift MarkView/Models/AI/CLICompletion.swift MarkView/Models/AI/ACPAssistant.swift MarkView/Models/AI/AgentProcesses.swift \
  tools/tests/UIStudioLiveStubs.swift "$out/main.swift"
"$out/ui-studio-live-run" "$PWD/MarkView/Resources/Editor/js" "$@"
