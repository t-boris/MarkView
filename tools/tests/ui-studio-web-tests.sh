#!/bin/bash
# Runs UI Studio's page runtime in a real WKWebView (a window of a small test app): simulated fetch and XHR through the
# validated bridge, seeded random numbers and clock, select mode, zoom that keeps the page's viewport, replayed steps,
# the build error overlay report, the rejection of stale messages and the connection policy as a content rule list.
#   tools/tests/ui-studio-web-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/UIStudioWebHarness.swift "$out/main.swift"
swiftc -o "$out/ui-studio-web-harness" \
  MarkView/Models/UIStudio/UIStudioJSON.swift MarkView/Models/UIStudio/UIStudioModels.swift MarkView/Models/UIStudio/UIStudioConnections.swift MarkView/Models/UIStudio/UIStudioSimulation.swift MarkView/Models/UIStudio/UIStudioAuthMock.swift \
  MarkView/Models/UIStudio/UIStudioRedaction.swift MarkView/Models/UIStudio/UIStudioBridge.swift MarkView/Models/UIStudio/UIStudioSelection.swift MarkView/Models/UIStudio/UIStudioChanges.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift \
  MarkView/Models/UIStudio/UIStudioPolicy.swift MarkView/Models/UIStudio/UIStudioGateway.swift MarkView/Models/UIStudio/UIStudioGatewayStreams.swift \
  MarkView/Models/UIStudio/UIStudioGraphQL.swift MarkView/Models/UIStudio/UIStudioChannels.swift MarkView/Models/UIStudio/UIStudioEnvironmentMap.swift \
  MarkView/Views/UIStudio/UIStudioPreviewHost.swift "$out/main.swift"
"$out/ui-studio-web-harness" MarkView/Resources/Editor/js/markview-ui-studio.js
