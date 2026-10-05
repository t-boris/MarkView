#!/bin/bash
# Checks the data viewers (tables with SQL, Parquet, SQLite, Excel, HAR, logs) and JSON/YAML editing
# in a real WKWebView with the shipping editor page and bundles. Needs a GUI session.
#   tools/tests/data-viewers-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DataViewersTests.swift "$out/main.swift"
swiftc -O -o "$out/data-viewers-tests" "$out/main.swift"
"$out/data-viewers-tests" "$PWD/MarkView/Resources/Editor" "$PWD/tools/tests/fixtures/data"
