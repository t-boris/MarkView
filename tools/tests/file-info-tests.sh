#!/bin/bash
# Checks the file facts of the Contents panel (MarkView/Models/FileInfo.swift).
#   tools/tests/file-info-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/FileInfoTests.swift "$out/main.swift"
swiftc -O -o "$out/file-info-tests" MarkView/Models/FileInfo.swift "$out/main.swift"
"$out/file-info-tests"
