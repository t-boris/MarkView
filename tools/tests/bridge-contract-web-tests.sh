#!/bin/bash
# AR-28 in real WebKit (hidden windows): the shipped editor and discussion pages send through mvBridge, the typed handlers take
# what bridge-contract.json allows and refuse what it does not (logging type and field names, never values).
#   tools/tests/bridge-contract-web-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BridgeContractWebTests.swift "$out/main.swift"
swiftc -O -o "$out/bridge-contract-web-tests" \
    MarkView/Bridge/TypedWebBridge.swift MarkView/Bridge/PageMessages.swift MarkView/Bridge/WebViewBridge.swift \
    MarkView/Bridge/DataFileSchemeHandler.swift MarkView/Models/Workspace/EditorDocumentRouting.swift \
    MarkView/Models/Workspace/EditorWindowPrefs.swift MarkView/Models/Insight/SemanticModels.swift \
    MarkView/Models/Insight/InsightModels.swift MarkView/Models/Appearance/AppFontScale.swift \
    MarkView/Views/Discussion/DiscussionThreadView.swift tools/tests/BridgeContractSupport.swift "$out/main.swift"
"$out/bridge-contract-web-tests" "$PWD/MarkView/Resources/Editor"
