#!/bin/bash
# Manual check against the REAL assistant (not part of the automatic checks): runs a real UI Studio session on a COPY of an application
# and prints what Studio repaired by itself (REQ-020) or prepared ahead (REQ-021), how long it took and what the assistant cost.
#   tools/tests/ui-studio-live-run.sh <project copy> repair|screens|load [scenario name]
#   load: only opens the scenario, then prints the page text, the problems and each saved scenario's compatibility (no assistant call).
# Make the copy with `cp -cR <project> <copy>` (an APFS clone: instant, and nothing in the original is touched). The assistant is the one
# the app uses (`~/Library/Application Support/MarkView/ai-calls.jsonl` records every call).
set -euo pipefail
cd "$(dirname "$0")/../.."
[ $# -ge 2 ] || { echo "usage: $0 <project copy> repair|screens|load [scenario name]"; exit 2; }
export PYTHONDONTWRITEBYTECODE=1
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/UIStudioLiveRun.swift "$out/main.swift"
swiftc -o "$out/ui-studio-live-run" \
  MarkView/Models/UIStudioJSON.swift MarkView/Models/UIStudioModels.swift MarkView/Models/UIStudioSimulation.swift MarkView/Models/UIStudioAuthMock.swift \
  MarkView/Models/UIStudioRedaction.swift MarkView/Models/UIStudioLog.swift MarkView/Models/UIStudioPreparation.swift MarkView/Models/UIStudioBridge.swift \
  MarkView/Models/UIStudioChanges.swift MarkView/Models/UIStudioStore.swift MarkView/Models/UIStudioEvidence.swift \
  MarkView/Models/UIStudioPrompts.swift MarkView/Models/UIStudioContext.swift MarkView/Models/UIStudioSelection.swift MarkView/Models/UIStudioPolicy.swift \
  MarkView/Models/UIStudioGateway.swift MarkView/Models/UIStudioServer.swift MarkView/Models/UIStudioConnections.swift MarkView/Models/UIStudioAgents.swift \
  MarkView/Models/UIStudioSession.swift MarkView/Models/BrowserElementPick.swift MarkView/Models/WebAppPreview.swift \
  MarkView/Models/FrontMatter.swift MarkView/Models/FeatureVocabulary.swift MarkView/Models/IssueListing.swift MarkView/Models/ProjectWorkflow.swift MarkView/Models/IssueLifecycle.swift MarkView/Models/IssueTransitionLog.swift MarkView/Models/BugReportWriter.swift MarkView/Models/UIStudioTracking.swift MarkView/Models/UIStudioSession+Tracking.swift \
  MarkView/Models/ImageAttachments.swift \
  MarkView/Models/UIStudioEnvironmentMap.swift MarkView/Models/UIStudioEnvironmentMapper.swift \
  MarkView/Models/UIStudioGraphQL.swift MarkView/Models/UIStudioChannels.swift \
  MarkView/Models/UIStudioGatewayStreams.swift MarkView/Models/UIStudioRealtimePrompts.swift MarkView/Models/UIStudioDataFix.swift MarkView/Models/UIStudioRepair.swift MarkView/Models/UIStudioScreens.swift MarkView/Models/UIStudioSession+Repair.swift MarkView/Models/UIStudioSession+Screens.swift \
  MarkView/Views/UIStudioPreviewHost.swift MarkView/Models/AIAssistants.swift MarkView/Models/ProjectColor.swift MarkView/Models/LinkedFolders.swift MarkView/Models/AICallLog.swift \
  MarkView/Models/CLICompletion.swift MarkView/Models/ACPAssistant.swift MarkView/Models/AgentProcesses.swift \
  tools/tests/UIStudioLiveStubs.swift "$out/main.swift"
"$out/ui-studio-live-run" "$PWD/MarkView/Resources/Editor/vendor/js/markview-ui-studio.js" "$@"
