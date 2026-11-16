#!/bin/bash
# The lifetime of a UI Studio session against the work its parts started (AR-16 lifetime rule): a real session (StudioSession and
# its parts) is closed and every reference to it dropped while an automatic repair, a click's data fix, a request of the page,
# a request of the request box, a capture or a pick is still in flight. The work then ends (cancelled, or answered late) and
# must neither crash (a part's task reading its unowned session after the session was released), nor write anything after
# close, nor keep the session alive.
#   tools/tests/ui-studio-lifetime-tests.sh [part of a scenario's name ...]
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
cp tools/tests/UIStudioLifetimeHarness.swift "$out/main.swift"
swiftc -o "$out/ui-studio-lifetime-harness" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
  MarkView/Models/UIStudio/UIStudioJSON.swift MarkView/Models/UIStudio/UIStudioModels.swift MarkView/Models/UIStudio/UIStudioSimulation.swift MarkView/Models/UIStudio/UIStudioAuthMock.swift \
  MarkView/Models/UIStudio/UIStudioRedaction.swift MarkView/Models/UIStudio/UIStudioLog.swift MarkView/Models/UIStudio/UIStudioPreparation.swift MarkView/Models/UIStudio/UIStudioBridge.swift \
  MarkView/Models/UIStudio/UIStudioChanges.swift MarkView/Models/UIStudio/UIStudioStore.swift MarkView/Models/Shared/SchemaVersionedStore.swift MarkView/Models/UIStudio/UIStudioEvidence.swift \
  MarkView/Models/UIStudio/UIStudioPrompts.swift MarkView/Models/UIStudio/UIStudioContext.swift MarkView/Models/UIStudio/UIStudioSelection.swift MarkView/Models/UIStudio/UIStudioPolicy.swift \
  MarkView/Models/UIStudio/UIStudioGateway.swift MarkView/Models/UIStudio/UIStudioServer.swift MarkView/Models/UIStudio/UIStudioConnections.swift MarkView/Models/UIStudio/UIStudioAgents.swift \
  MarkView/Models/UIStudio/UIStudioSession.swift MarkView/Models/UIStudio/UIStudioKeptData.swift MarkView/Models/UIStudio/UIStudioElementPicker.swift MarkView/Models/UIStudio/UIStudioRepairing.swift MarkView/Models/UIStudio/UIStudioRequestPath.swift MarkView/Models/UIStudio/UIStudioChangeFlow.swift MarkView/Models/UIStudio/UIStudioWork.swift MarkView/Models/UIStudio/UIStudioHistory.swift MarkView/Models/UIStudio/UIStudioCaptures.swift MarkView/Models/UIStudio/UIStudioPackages.swift MarkView/Models/UIStudio/UIStudioMessageHandler.swift MarkView/Models/UIStudio/UIStudioSourceResolution.swift MarkView/Models/UIStudio/UIStudioFeatureWriter.swift MarkView/Models/UIStudio/UIStudioReply.swift MarkView/Models/Browser/BrowserElementPick.swift MarkView/Models/Browser/WebAppPreview.swift \
  MarkView/Models/Shared/FrontMatter.swift MarkView/Models/Lifecycle/FeatureVocabulary.swift MarkView/Models/Lifecycle/IssueListing.swift MarkView/Models/Lifecycle/ProjectWorkflow.swift MarkView/Models/Lifecycle/IssueLifecycle.swift MarkView/Models/Lifecycle/IssueTransitionLog.swift MarkView/Models/Lifecycle/BugReportWriter.swift MarkView/Models/UIStudio/UIStudioTracking.swift MarkView/Models/UIStudio/UIStudioSession+Tracking.swift \
  MarkView/Models/Shared/ImageAttachments.swift \
  MarkView/Models/UIStudio/UIStudioEnvironmentMap.swift MarkView/Models/UIStudio/UIStudioEnvironmentMapper.swift \
  MarkView/Models/UIStudio/UIStudioGraphQL.swift MarkView/Models/UIStudio/UIStudioChannels.swift \
  MarkView/Models/UIStudio/UIStudioGatewayStreams.swift MarkView/Models/UIStudio/UIStudioRealtimePrompts.swift MarkView/Models/UIStudio/UIStudioDataFix.swift MarkView/Models/UIStudio/UIStudioRepair.swift MarkView/Models/UIStudio/UIStudioScreens.swift MarkView/Models/UIStudio/UIStudioReview.swift MarkView/Models/UIStudio/UIStudioSession+Screens.swift MarkView/Models/UIStudio/UIStudioSession+Review.swift \
  MarkView/Models/AI/AIOperation.swift MarkView/Views/UIStudio/UIStudioPreviewHost.swift tools/tests/UIStudioSessionStubs.swift "$out/main.swift"
"$out/ui-studio-lifetime-harness" MarkView/Resources/Editor/js "$@"
