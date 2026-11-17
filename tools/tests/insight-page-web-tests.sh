#!/bin/bash
# FU-25: the cached and exported Insight page, in real WebKit with a hidden window. The shipping InsightHTMLTemplate writes a page
# into a real InsightCache (the bundled libraries copied into _assets/, as the app does) and the page is loaded from the cache
# folder: it renders (bootstrap by hash, Mermaid, Chart.js, lightbox) while an inline script, an inline handler and a javascript:
# link in the assistant's text or in a label do not run; the older policy runs them (control). The vendored libraries the cache
# copies from the bundle are the real ones, put next to the executable (a command-line tool's Bundle.main is its folder).
#   tools/tests/insight-page-web-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/InsightPageWebTests.swift "$out/main.swift"
mkdir -p "$out/Editor"
ln -s "$PWD/MarkView/Resources/Editor/vendor" "$out/Editor/vendor"
swiftc -suppress-warnings -o "$out/insight-page-web-tests" -target "$(uname -m)-apple-macos13.0" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Insight/InsightModels.swift MarkView/Models/Insight/InsightHTMLTemplate.swift MarkView/Models/Insight/InsightCache.swift \
     "$out/main.swift"
"$out/insight-page-web-tests"
