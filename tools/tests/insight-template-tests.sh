#!/bin/bash
# The Insight page template and the saved node tree (AR-16 split of InsightSession): the shipping InsightHTMLTemplate and
# InsightTreeSnapshot over real values — escaping, byte-identical output, a saved tree restored (also from an older root-only
# snapshot). No window, session or assistant.
#   tools/tests/insight-template-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/InsightTemplateTests.swift "$out/main.swift"
swiftc -o "$out/insight-template-tests" -target "$(uname -m)-apple-macos13.0" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Insight/InsightModels.swift MarkView/Models/Insight/InsightHTMLTemplate.swift MarkView/Models/Insight/InsightTreeSnapshot.swift \
    MarkView/Models/Insight/InsightCache.swift tools/tests/ProjectOperationAnyCodableStub.swift "$out/main.swift"
"$out/insight-template-tests"
