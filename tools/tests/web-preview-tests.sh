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
swiftc -O -o "$out/web-preview-tests" MarkView/Models/Workspace/WebAppPreview.swift MarkView/Models/Workspace/WebClip.swift \
  MarkView/Models/Browser/BrowserSession.swift MarkView/Models/Browser/WebPreview.swift MarkView/Models/Browser/BrowserPasswords.swift MarkView/Models/Browser/BrowserPasswordScript.swift \
  MarkView/Models/Browser/BrowserDownloads.swift MarkView/Models/Browser/BrowserPagePDF.swift MarkView/Models/Terminal/TerminalBrowserBridge.swift MarkView/Models/Workspace/FrontMatter.swift MarkView/Models/Research/ResearchDocument.swift \
  MarkView/Models/Browser/BrowserElementPick.swift MarkView/Views/Browser/BrowserPopup.swift MarkView/Models/Browser/BrowserAgentExecutor.swift MarkView/Models/AgentTools/BrowserAgentTools.swift Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
  "$out/main.swift"
"$out/web-preview-tests"
