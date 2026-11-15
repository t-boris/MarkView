#!/bin/bash
# AR-28: one declared bridge contract (MarkView/Resources/Editor/js/bridge-contract.json) used by both sides of the bridge.
#   Both directions (every handler in the contract, every contract message with a handler), real delivery through the typed
#   handlers, refusals logged without values, and the page's validator (mv-kit.js in JavaScriptCore) against the app's validator
#   on the same cases. The window-less part; the shipped pages are driven by bridge-contract-web-tests.sh.
#   tools/tests/bridge-contract-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BridgeContractTests.swift "$out/main.swift"
swiftc -O -o "$out/bridge-contract-tests" Packages/MarkViewCore/Sources/MarkViewCore/JS.swift Packages/MarkViewCore/Sources/MarkViewCore/WebHost.swift \
    MarkView/Bridge/TypedWebBridge.swift MarkView/Bridge/PageMessages.swift MarkView/Bridge/WebViewBridge.swift \
    MarkView/Bridge/DataFileSchemeHandler.swift MarkView/Models/Workspace/EditorDocumentRouting.swift \
    MarkView/Models/Workspace/EditorWindowPrefs.swift MarkView/Models/Insight/SemanticModels.swift \
    MarkView/Models/Insight/InsightModels.swift MarkView/Models/Appearance/AppFontScale.swift \
    MarkView/Views/Discussion/DiscussionThreadView.swift tools/tests/BridgeContractSupport.swift "$out/main.swift"
"$out/bridge-contract-tests" "$PWD/MarkView/Resources/Editor"
