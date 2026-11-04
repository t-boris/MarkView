#!/bin/bash
# BUG-063 in a real WKWebView: a site whose stylesheet is the Tailwind source gets rules for its utility classes once MarkView adds the
# browser build (MarkView/Models/PrototypeTailwind.swift), served through the preview's scheme handler. Run from anywhere in the repository.
#   tools/tests/prototype-tailwind-render-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeTailwindRenderTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-tailwind-render-tests" MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeStyles.swift MarkView/Models/PrototypeTailwind.swift MarkView/Models/PrototypeThemes.swift \
    MarkView/Bridge/PrototypeSchemeHandler.swift "$out/main.swift"
"$out/prototype-tailwind-render-tests"
