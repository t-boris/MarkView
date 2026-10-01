#!/bin/bash
# Checks Preview Web App discovery, the terminal browser bridge (real zsh), dev server output parsing, web clips, the address field and
# the page-to-Markdown converter (run in a WKWebView). The app has no XCTest target: the modules
# are compiled on their own with a test main and run.
#   tools/tests/web-preview-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/WebPreviewTests.swift "$out/main.swift"
swiftc -O -o "$out/web-preview-tests" MarkView/Models/WebAppPreview.swift MarkView/Models/WebClip.swift \
  MarkView/Models/BrowserSession.swift MarkView/Models/TerminalBrowserBridge.swift MarkView/Models/FrontMatter.swift MarkView/Models/ResearchDocument.swift \
  "$out/main.swift"
"$out/web-preview-tests"
