#!/bin/bash
# Checks that PTYWriter (MarkView/Models/PTYWriter.swift) delivers long pastes to a real PTY
# completely and in order while the reader is slower than the writer (BUG-002).
#   tools/tests/pty-writer-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PTYWriterTests.swift "$out/main.swift"
swiftc -module-cache-path /private/tmp/markview-swift-cache -o "$out/pty-writer-tests" \
    MarkView/Models/PTYWriter.swift "$out/main.swift"
"$out/pty-writer-tests"
