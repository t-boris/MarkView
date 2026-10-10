#!/bin/bash
# Checks the JSON / YAML outline of the Contents panel (MarkView/Models/StructureOutline.swift).
#   tools/tests/structure-outline-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/StructureOutlineTests.swift "$out/main.swift"
swiftc -O -o "$out/structure-outline-tests" MarkView/Models/StructureOutline.swift "$out/main.swift"
"$out/structure-outline-tests"
