#!/bin/bash
# Checks archive support (MarkView/Models/ArchiveSupport.swift) on real archives made with zip, tar
# and Python: listing, one entry, extraction, zip-slip refusal, compress.
#   tools/tests/archive-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ArchiveTests.swift "$out/main.swift"
swiftc -O -o "$out/archive-tests" MarkView/Models/ArchiveSupport.swift "$out/main.swift"
"$out/archive-tests"
