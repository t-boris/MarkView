#!/bin/bash
# Phase 0 safety and correctness checks (AR-01 through AR-13).
set -euo pipefail
cd "$(dirname "$0")/../.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# The test runs the app's own EditorPage (nonce injection into the editor policy), so it is compiled with it.
cp tools/tests/Phase0SafetyTests.swift "$out/main.swift"
swiftc -target arm64-apple-macosx13.0 \
    MarkView/Models/Workspace/EditorPage.swift \
    "$out/main.swift" \
    -o "$out/phase0-safety-tests"

"$out/phase0-safety-tests"
