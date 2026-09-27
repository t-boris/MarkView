#!/bin/bash
# Checks the batch Fix with AI rules (MarkView/Models/BugBasket.swift): basket membership and
# cleanup, the batch prompt, and the "Suggest similar" answer. The app has no XCTest target: the
# module is compiled on its own (with IssueListing.swift for the status vocabulary) and run.
#   tools/tests/bug-basket-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BugBasketTests.swift "$out/main.swift"
swiftc -O -o "$out/bug-basket-tests" MarkView/Models/BugBasket.swift MarkView/Models/IssueListing.swift "$out/main.swift"
"$out/bug-basket-tests"
