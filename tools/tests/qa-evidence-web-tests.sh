#!/bin/bash
# Feature end-to-end-qa, REQ-008: the script that measures a page for the step-by-step review (QAPageEvidence.script) run in a real
# WKWebView against fixture pages: tiny text, weak contrast, clipped content, small click targets, a page wider than the window, controls
# with no name, skipped headings, and a check that nothing a person typed ever leaves the page. The window is never shown.
#   tools/tests/qa-evidence-web-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/QAEvidenceWebHarness.swift "$out/main.swift"
swiftc -o "$out/qa-evidence-web" MarkView/Models/QAPageEvidence.swift "$out/main.swift"
"$out/qa-evidence-web"
