#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeThemesTests.swift "$out/main.swift"
swiftc -o "$out/prototype-themes-tests" MarkView/Models/Prototype/PrototypeFiles.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/StoredJSON.swift MarkView/Models/Prototype/PrototypeThemes.swift "$out/main.swift"
"$out/prototype-themes-tests"
