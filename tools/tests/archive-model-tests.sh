#!/bin/bash
# The archive tab's model (MarkView/Models/Workspace/ArchiveModel.swift, AR-19) on a real zip: load, unpack one entry, unpack all, a second
# request while one runs, and a model that is let go. Nothing is shown.
#   tools/tests/archive-model-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ArchiveModelTests.swift "$out/main.swift"
swiftc -target "$(uname -m)-apple-macos13.0" -o "$out/archive-model-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Workspace/ArchiveSupport.swift MarkView/Models/Workspace/ArchiveModel.swift "$out/main.swift"
"$out/archive-model-tests"
