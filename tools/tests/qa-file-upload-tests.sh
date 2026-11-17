#!/bin/bash
# End-to-End QA file upload on the production path: a real BrowserSession in an off-screen QA window, the real snapshot and native click of
# BrowserAgentExecutor, real WebKit. A click on a file field (or the label of a hidden one) is answered with the built-in test image.
#   tools/tests/qa-file-upload-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/QAFileUploadTests.swift "$out/main.swift"
swiftc -O -o "$out/qa-file-upload-tests" MarkView/Models/Browser/BrowserAddress.swift MarkView/Models/Browser/BrowserSession.swift MarkView/Models/Browser/WebPreview.swift MarkView/Models/Browser/WebAppPreview.swift \
  MarkView/Models/Browser/BrowserPasswords.swift MarkView/Models/Browser/BrowserPasswordScript.swift MarkView/Models/Shared/UserPrompts.swift \
  MarkView/Models/Browser/BrowserDownloads.swift MarkView/Models/Browser/BrowserPagePDF.swift \
  MarkView/Views/Browser/BrowserPopup.swift MarkView/Models/Browser/BrowserAgentExecutor.swift MarkView/Models/AgentTools/BrowserAgentTools.swift \
  Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/QA/QATestImage.swift MarkView/Views/QA/QAWebWindow.swift \
  "$out/main.swift"
"$out/qa-file-upload-tests"
