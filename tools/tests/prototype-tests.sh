#!/bin/bash
# Checks the file rules of Prototype Studio (MarkView/Models/PrototypeFiles.swift): path validation,
# edits, versions and the manifest. The module is compiled on its own with a test main and run.
#   tools/tests/prototype-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-tests" MarkView/Models/PrototypeFiles.swift "$out/main.swift"
"$out/prototype-tests"
