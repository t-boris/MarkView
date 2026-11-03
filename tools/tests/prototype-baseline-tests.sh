#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeBaselineTests.swift "$out/main.swift"
swiftc -o "$out/prototype-baseline-tests" MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeBaseline.swift "$out/main.swift"
"$out/prototype-baseline-tests"
