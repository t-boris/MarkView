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
  MarkView/Models/UIStudioJSON.swift MarkView/Models/UIStudioModels.swift MarkView/Models/UIStudioSimulation.swift MarkView/Models/UIStudioAuthMock.swift \
  MarkView/Models/UIStudioRedaction.swift MarkView/Models/UIStudioLog.swift MarkView/Models/UIStudioPreparation.swift MarkView/Models/UIStudioBridge.swift \
  MarkView/Models/UIStudioChanges.swift MarkView/Models/UIStudioStore.swift MarkView/Models/UIStudioEvidence.swift \
  MarkView/Models/UIStudioPrompts.swift MarkView/Models/UIStudioContext.swift MarkView/Models/UIStudioSelection.swift MarkView/Models/UIStudioPolicy.swift \
  MarkView/Models/UIStudioGateway.swift MarkView/Models/UIStudioServer.swift MarkView/Models/UIStudioConnections.swift MarkView/Models/UIStudioAgents.swift \
  MarkView/Models/UIStudioSession.swift MarkView/Models/BrowserElementPick.swift MarkView/Models/WebAppPreview.swift \
  MarkView/Models/FrontMatter.swift MarkView/Models/FeatureVocabulary.swift MarkView/Models/IssueListing.swift MarkView/Models/IssueLifecycle.swift MarkView/Models/IssueTransitionLog.swift MarkView/Models/BugReportWriter.swift MarkView/Models/UIStudioTracking.swift MarkView/Models/UIStudioSession+Tracking.swift \
  MarkView/Models/ImageAttachments.swift \
  MarkView/Models/UIStudioEnvironmentMap.swift MarkView/Models/UIStudioEnvironmentMapper.swift \
  MarkView/Models/UIStudioGraphQL.swift MarkView/Models/UIStudioChannels.swift \
  MarkView/Models/UIStudioGatewayStreams.swift MarkView/Models/UIStudioRealtimePrompts.swift MarkView/Models/UIStudioDataFix.swift \
  MarkView/Views/UIStudioPreviewHost.swift tools/tests/UIStudioSessionStubs.swift tools/tests/UIStudioAuthHarness.swift "$out/main.swift"
"$out/ui-studio-session-harness" MarkView/Resources/Editor/vendor/js/markview-ui-studio.js
