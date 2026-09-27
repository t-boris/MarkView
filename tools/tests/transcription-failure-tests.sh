#!/bin/bash
# Checks how failed transcriptions are explained (TranscriptionFailure in
# MarkView/Models/WhisperClient.swift, BUG-009): readable text, a next step and a short tag,
# never raw JSON or the API's echoed key. Only the struct is compiled, not the app.
#   tools/tests/transcription-failure-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
{ echo 'import Foundation'; awk '/^struct TranscriptionFailure/,0' MarkView/Models/WhisperClient.swift; } > "$out/Failure.swift"
cp tools/tests/TranscriptionFailureTests.swift "$out/main.swift"
swiftc -O -o "$out/transcription-failure-tests" "$out/Failure.swift" "$out/main.swift"
"$out/transcription-failure-tests"
