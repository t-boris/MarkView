#!/bin/bash
# The rule that decides which pictures next to a document the editor page may be given (BUG-061):
# the native policy (swiftc), the page's address mapping (node, no packages) and the page and the scheme handler in a real WKWebView.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -module-cache-path /private/tmp/markview-swift-cache \
  MarkView/Models/DocumentFiles.swift tools/tests/DocumentFilesTests.swift -o "$out/document-files-tests"
"$out/document-files-tests"
node tools/tests/document-files.test.js
swiftc -parse-as-library -module-cache-path /private/tmp/markview-swift-cache \
  tools/tests/DocumentFilesPageTests.swift -o "$out/document-files-page-tests"
"$out/document-files-page-tests" "$PWD/MarkView/Resources/Editor/vendor/js/markview-document-files.js"
swiftc -parse-as-library -module-cache-path /private/tmp/markview-swift-cache \
  MarkView/Models/DocumentFiles.swift MarkView/Bridge/DocumentFileSchemeHandler.swift \
  tools/tests/DocumentFileSchemeHandlerTests.swift -o "$out/document-handler-tests"
"$out/document-handler-tests"
