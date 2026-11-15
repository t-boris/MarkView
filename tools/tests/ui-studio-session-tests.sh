#!/bin/bash
# Runs a real UI Studio session (StudioSession and its page runtime) against a real development server
# (python3 -m http.server) in a temporary git project, with the assistant answered by the harness: readiness, simulated
# state and Reset, selection, a read-only question, verified source changes, selective undo and its conflicts, a broken
# build, preparation of unknown requests, captures, feature export with revalidation, and server ownership on close.
#   tools/tests/ui-studio-session-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
# Record the unmodified lookup time so CI output distinguishes resolver delays from slow session behavior.
if [ "${CI:-}" = "true" ]; then
  python3 -c 'import socket,time; start=time.monotonic(); socket.getfqdn("127.0.0.1"); print("Loopback reverse lookup: %.2f s" % (time.monotonic()-start))'
fi
# Python's HTTPServer resolves the bind address with getfqdn during startup. Reverse DNS for loopback can take tens of
# seconds on hosted macOS runners, even though these fixtures only serve local clients. Avoid that external dependency.
export PYTHONPATH="$PWD/tools/tests/studio-python${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/UIStudioSessionHarness.swift "$out/main.swift"
swiftc -o "$out/ui-studio-session-harness" \
  MarkView/Models/UIStudio/UIStudioJSON.swift MarkView/Models/UIStudio/UIStudioModels.swift MarkView/Models/UIStudio/UIStudioSimulation.swift MarkView/Models/UIStudio/UIStudioAuthMock.swift \
  MarkView/Models/UIStudio/UIStudioRedaction.swift MarkView/Models/UIStudio/UIStudioLog.swift MarkView/Models/UIStudio/UIStudioPreparation.swift MarkView/Models/UIStudio/UIStudioBridge.swift \
  MarkView/Models/UIStudio/UIStudioChanges.swift MarkView/Models/UIStudio/UIStudioStore.swift MarkView/Models/Workspace/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/UIStudio/UIStudioEvidence.swift \
  MarkView/Models/UIStudio/UIStudioPrompts.swift MarkView/Models/UIStudio/UIStudioContext.swift MarkView/Models/UIStudio/UIStudioSelection.swift MarkView/Models/UIStudio/UIStudioPolicy.swift \
  MarkView/Models/UIStudio/UIStudioGateway.swift MarkView/Models/UIStudio/UIStudioServer.swift MarkView/Models/UIStudio/UIStudioConnections.swift MarkView/Models/UIStudio/UIStudioAgents.swift \
  MarkView/Models/UIStudio/UIStudioSession.swift MarkView/Models/Browser/BrowserElementPick.swift MarkView/Models/Workspace/WebAppPreview.swift \
  MarkView/Models/Workspace/FrontMatter.swift MarkView/Models/Lifecycle/FeatureVocabulary.swift MarkView/Models/Lifecycle/IssueListing.swift MarkView/Models/Lifecycle/ProjectWorkflow.swift MarkView/Models/Lifecycle/IssueLifecycle.swift MarkView/Models/Lifecycle/IssueTransitionLog.swift MarkView/Models/Lifecycle/BugReportWriter.swift MarkView/Models/UIStudio/UIStudioTracking.swift MarkView/Models/UIStudio/UIStudioSession+Tracking.swift \
  MarkView/Models/Workspace/ImageAttachments.swift \
  MarkView/Models/UIStudio/UIStudioEnvironmentMap.swift MarkView/Models/UIStudio/UIStudioEnvironmentMapper.swift \
  MarkView/Models/UIStudio/UIStudioGraphQL.swift MarkView/Models/UIStudio/UIStudioChannels.swift \
  MarkView/Models/UIStudio/UIStudioGatewayStreams.swift MarkView/Models/UIStudio/UIStudioRealtimePrompts.swift MarkView/Models/UIStudio/UIStudioDataFix.swift MarkView/Models/UIStudio/UIStudioRepair.swift MarkView/Models/UIStudio/UIStudioScreens.swift MarkView/Models/UIStudio/UIStudioReview.swift MarkView/Models/UIStudio/UIStudioSession+Repair.swift MarkView/Models/UIStudio/UIStudioSession+Screens.swift MarkView/Models/UIStudio/UIStudioSession+Review.swift \
  MarkView/Views/UIStudio/UIStudioPreviewHost.swift tools/tests/UIStudioSessionStubs.swift tools/tests/UIStudioAuthHarness.swift "$out/main.swift"
"$out/ui-studio-session-harness" MarkView/Resources/Editor/js/markview-ui-studio.js
