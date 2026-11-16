#!/bin/bash
# Checks who owns what the operations of a project write to disk (AR-19): the shipping ProjectOperationWrites over a temporary project
# folder, with the real operations file and the real run history. Edits asked for at once are all kept, a failing edit stops none of
# the others, a run's records are kept in the order asked for, and `drain()` returns when everything is on disk.
#   tools/tests/project-operation-writes-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# The model keeps unknown JSON keys as AnyCodable (defined with the bridge); a copy stands in for it.
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -o "$out/project-operation-writes-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/ProjectOps/ProjectOperation.swift \
    MarkView/Models/ProjectOps/ProjectOperationHistory.swift MarkView/Models/ProjectOps/ProjectOperationWrites.swift \
    tools/tests/ProjectOperationAnyCodableStub.swift tools/tests/ProjectOperationWritesTests.swift
"$out/project-operation-writes-tests"
