#!/bin/bash
# Real offscreen WebKit rendering, screenshots and native input for BUG-125.
# Pass --system-window to reproduce the regression, or a directory to keep screenshots.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/QAWebWindowChecks.swift "$out/main.swift"
swiftc -o "$out/qa-web-window" MarkView/Models/QAWebWindow.swift "$out/main.swift"
"$out/qa-web-window" "$@"
