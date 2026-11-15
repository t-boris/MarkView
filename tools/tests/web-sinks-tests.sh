#!/bin/bash
# FU-24 / FU-25: the style filter of the editor sanitiser and the values of untrusted files in the editor page, in real WebKit
# (hidden window): CSS escapes and comments no longer pass the inline-style filter, position is limited, url() stays inside the
# document, a .canvas colour and a code-navigation result kind cannot inject markup.
#   tools/tests/web-sinks-tests.sh [editor folder]     (default: MarkView/Resources/Editor)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/WebSinkTests.swift "$out/main.swift"
swiftc -O -o "$out/web-sink-tests" MarkView/Bridge/TypedWebBridge.swift "$out/main.swift"
"$out/web-sink-tests" "${1:-$PWD/MarkView/Resources/Editor}"
