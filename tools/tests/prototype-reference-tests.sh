#!/bin/bash
# Checks the prototype reference handed to agents (MarkView/Models/Prototype/PrototypeReference.swift): the reference
# string, every accepted form of a reference text and what is rejected. The module is compiled with
# PrototypeFiles.swift (the storage folders) and a test main, then run.
#   tools/tests/prototype-reference-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeReferenceTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-reference-tests" MarkView/Models/Prototype/PrototypeFiles.swift MarkView/Models/Prototype/PrototypeReference.swift "$out/main.swift"
"$out/prototype-reference-tests"
