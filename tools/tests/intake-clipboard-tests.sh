#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/IntakeClipboardTests.swift "$out/main.swift"
swiftc -O -o "$out/intake-clipboard-tests" MarkView/Views/IntakeTextEditor.swift "$out/main.swift"
"$out/intake-clipboard-tests" "$@"
