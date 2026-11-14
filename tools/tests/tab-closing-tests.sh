#!/bin/bash
# Which tab is active after several tabs close at once (Models/TabClosing.swift).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/TabClosingChecks.swift "$out/main.swift"
swiftc -o "$out/checks" MarkView/Models/TabClosing.swift "$out/main.swift"
"$out/checks"
