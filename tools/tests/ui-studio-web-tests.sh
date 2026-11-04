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
  MarkView/Models/UIStudioJSON.swift MarkView/Models/UIStudioModels.swift MarkView/Models/UIStudioConnections.swift MarkView/Models/UIStudioSimulation.swift MarkView/Models/UIStudioAuthMock.swift \
  MarkView/Models/UIStudioRedaction.swift MarkView/Models/UIStudioBridge.swift MarkView/Models/UIStudioSelection.swift MarkView/Models/UIStudioChanges.swift \
  MarkView/Models/UIStudioPolicy.swift MarkView/Models/UIStudioGateway.swift \
  MarkView/Views/UIStudioPreviewHost.swift "$out/main.swift"
"$out/ui-studio-web-harness" MarkView/Resources/Editor/vendor/js/markview-ui-studio.js
