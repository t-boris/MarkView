#!/bin/bash
# Checks UI Studio's pure modules: simulation engine, rule validation, bounded preparation, redaction, bridge validation,
# change manager with selective undo (real git), code revision identity, scenarios, image comparison, feature packages,
# the development server's process group, the launch environment, the connection policy filters and the gateway's
# HTTP parser and serializer.
# The app has no XCTest target: the modules are compiled on their own with a test main and run.
#   tools/tests/ui-studio-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/UIStudioTests.swift "$out/main.swift"
swiftc -o "$out/ui-studio-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
  MarkView/Models/UIStudio/UIStudioJSON.swift MarkView/Models/UIStudio/UIStudioModels.swift MarkView/Models/UIStudio/UIStudioSimulation.swift MarkView/Models/UIStudio/UIStudioAuthMock.swift \
  MarkView/Models/UIStudio/UIStudioRedaction.swift MarkView/Models/UIStudio/UIStudioLog.swift MarkView/Models/UIStudio/UIStudioPreparation.swift MarkView/Models/UIStudio/UIStudioBridge.swift \
  MarkView/Models/UIStudio/UIStudioChanges.swift MarkView/Models/UIStudio/UIStudioStore.swift MarkView/Models/Workspace/SchemaVersionedStore.swift MarkView/Models/UIStudio/UIStudioEvidence.swift \
  MarkView/Models/UIStudio/UIStudioPrompts.swift MarkView/Models/UIStudio/UIStudioContext.swift MarkView/Models/UIStudio/UIStudioSelection.swift MarkView/Models/Browser/BrowserElementPick.swift \
  MarkView/Models/UIStudio/UIStudioPolicy.swift MarkView/Models/UIStudio/UIStudioGateway.swift MarkView/Models/UIStudio/UIStudioServer.swift MarkView/Models/UIStudio/UIStudioConnections.swift \
  MarkView/Models/UIStudio/UIStudioTracking.swift MarkView/Models/Lifecycle/BugReportWriter.swift MarkView/Models/Workspace/FrontMatter.swift \
  MarkView/Models/UIStudio/UIStudioEnvironmentMap.swift MarkView/Models/UIStudio/UIStudioEnvironmentMapper.swift \
  MarkView/Models/UIStudio/UIStudioGraphQL.swift MarkView/Models/UIStudio/UIStudioChannels.swift MarkView/Models/UIStudio/UIStudioGatewayStreams.swift \
  MarkView/Models/UIStudio/UIStudioRealtimePrompts.swift MarkView/Models/UIStudio/UIStudioDataFix.swift MarkView/Models/UIStudio/UIStudioRepair.swift MarkView/Models/UIStudio/UIStudioScreens.swift MarkView/Models/UIStudio/UIStudioReview.swift tools/tests/UIStudioAuthTests.swift tools/tests/UIStudioRepairTests.swift tools/tests/UIStudioScreensTests.swift tools/tests/UIStudioEnvelopeTests.swift tools/tests/StoreTestSupport.swift "$out/main.swift"
"$out/ui-studio-tests"
