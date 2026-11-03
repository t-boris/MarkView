#!/bin/bash
# Checks the prototype reference handed to agents (MarkView/Models/PrototypeReference.swift): the reference
# string, every accepted form of a reference text and what is rejected. The module is compiled on its own
# with a test main and run.
#   tools/tests/prototype-reference-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeReferenceTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-reference-tests" MarkView/Models/PrototypeReference.swift "$out/main.swift"
"$out/prototype-reference-tests"
