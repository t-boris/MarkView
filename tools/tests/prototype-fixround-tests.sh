#!/bin/bash
# Checks BUG-062: the files a preview problem points to, the fan-out limit of the fix round, and the text check for an App.load callback
# that clears the element its loader sits in (MarkView/Models/PrototypeAudit.swift). The app has no XCTest target: the module is compiled
# on its own with a test main and run.
#   tools/tests/prototype-fixround-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeFixRoundTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-fixround-tests" MarkView/Models/PrototypeAudit.swift "$out/main.swift"
"$out/prototype-fixround-tests"
