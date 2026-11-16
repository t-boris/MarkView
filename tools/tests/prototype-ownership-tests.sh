#!/bin/bash
# Checks who owns the work Prototype Studio starts (AR-19): the shipping PrototypeSession (the sync status check, the sync preview, the
# hand-off preparation) over a prototype saved in a temporary project, and the shipping PrototypeHandoffRun (the creation of the feature,
# with the feature store and its writer replaced by stand-ins). MarkViewCore is built as the module the app links, because the session
# imports it. Nothing is rendered and no assistant is asked.
#   tools/tests/prototype-ownership-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
target="$(uname -m)-apple-macos13.0"
swiftc -parse-as-library -wmo -target "$target" -module-name MarkViewCore -emit-module -emit-module-path "$out/MarkViewCore.swiftmodule" \
    -c Packages/MarkViewCore/Sources/MarkViewCore/*.swift -o "$out/MarkViewCore.o"
P=MarkView/Models/Prototype
cp tools/tests/PrototypeOwnershipTests.swift "$out/main.swift"
swiftc -O -target "$target" -I "$out" -o "$out/prototype-ownership-tests" "$out/MarkViewCore.o" \
    $P/PrototypeFiles.swift $P/PrototypeStyles.swift $P/PrototypeShellStructure.swift $P/PrototypeEmbedded.swift MarkView/Models/AI/AIOperation.swift \
    $P/PrototypeAI.swift $P/PrototypePrompts.swift $P/PrototypeSchemas.swift $P/PrototypePlan.swift $P/PrototypeProgress.swift $P/PrototypeExport.swift \
    $P/PrototypeAI+Handoff.swift $P/PrototypeRuntime.swift $P/PrototypeAudit.swift $P/PrototypeThemes.swift $P/PrototypeBaseline.swift \
    $P/PrototypeTailwind.swift $P/PrototypeHandoff.swift $P/PrototypeHandoffDraft.swift MarkView/Models/Shared/ImageAttachments.swift \
    $P/PrototypeImages.swift MarkView/Bridge/PrototypeScreenshots.swift MarkView/Bridge/PrototypeSchemeHandler.swift tools/tests/PrototypeCLIStub.swift \
    $P/PrototypeSession.swift $P/PrototypeHandoffRun.swift $P/PrototypeFidelity.swift $P/PrototypeReference.swift MarkView/Models/Browser/WebAppPreview.swift \
    tools/tests/PrototypeOwnershipStubs.swift "$out/main.swift"
"$out/prototype-ownership-tests"
