#!/bin/bash
# BUG-063 in a real WKWebView: a site whose stylesheet is the Tailwind source gets rules for its utility classes once MarkView adds the
# browser build (MarkView/Models/Prototype/PrototypeTailwind.swift), served through the preview's scheme handler. Run from anywhere in the repository.
#   tools/tests/prototype-tailwind-render-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeTailwindRenderTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-tailwind-render-tests" MarkView/Models/Prototype/PrototypeFiles.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/StoredJSON.swift MarkView/Models/Prototype/PrototypeStyles.swift MarkView/Models/Prototype/PrototypeTailwind.swift MarkView/Models/Prototype/PrototypeThemes.swift \
    MarkView/Bridge/PrototypeSchemeHandler.swift "$out/main.swift"
"$out/prototype-tailwind-render-tests"
