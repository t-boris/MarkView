#!/bin/bash
# Checks what Re-discover does to operations already in .markview/operations.json (BUG-036): an
# untouched operation is refreshed, every single-field edit survives, user-added and deleted
# operations are left alone, and the stored layout stays compatible. The app has no XCTest target:
# the model file is compiled on its own with a test main and run.
#   tools/tests/project-operation-merge-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ProjectOperationMergeTests.swift "$out/main.swift"
# The model keeps unknown JSON keys as AnyCodable (defined with the bridge); a copy stands in for it.
swiftc -O -o "$out/merge-tests" MarkView/Models/ProjectOperation.swift \
  tools/tests/ProjectOperationAnyCodableStub.swift "$out/main.swift"
"$out/merge-tests"
