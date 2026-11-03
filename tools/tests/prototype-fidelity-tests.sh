#!/bin/bash
# Checks BUG-059: the labels of a source file, the source set of a screen, the share of the labels a screen shows and the
# repair request for a thin screen (MarkView/Models/PrototypeFidelity.swift). The module is pure: it is compiled on its own
# with a test main and run.
#   tools/tests/prototype-fidelity-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeFidelityTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-fidelity-tests" MarkView/Models/PrototypeFidelity.swift "$out/main.swift"
"$out/prototype-fidelity-tests"
