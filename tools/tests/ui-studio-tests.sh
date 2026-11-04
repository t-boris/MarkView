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
swiftc -o "$out/ui-studio-tests" \
  MarkView/Models/UIStudioJSON.swift MarkView/Models/UIStudioModels.swift MarkView/Models/UIStudioSimulation.swift \
  MarkView/Models/UIStudioRedaction.swift MarkView/Models/UIStudioLog.swift MarkView/Models/UIStudioPreparation.swift MarkView/Models/UIStudioBridge.swift \
  MarkView/Models/UIStudioChanges.swift MarkView/Models/UIStudioStore.swift MarkView/Models/UIStudioEvidence.swift \
  MarkView/Models/UIStudioPrompts.swift MarkView/Models/UIStudioContext.swift MarkView/Models/UIStudioSelection.swift MarkView/Models/BrowserElementPick.swift \
  MarkView/Models/UIStudioPolicy.swift MarkView/Models/UIStudioGateway.swift MarkView/Models/UIStudioServer.swift MarkView/Models/UIStudioConnections.swift \
  MarkView/Models/UIStudioTracking.swift MarkView/Models/BugReportWriter.swift MarkView/Models/FrontMatter.swift \
  "$out/main.swift"
"$out/ui-studio-tests"
