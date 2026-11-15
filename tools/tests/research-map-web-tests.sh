#!/bin/bash
# The research map view (DEC-009) in the shipped editor page, in real WebKit with a hidden window and a stubbed bridge:
# a type: research-map document shows the map, a pushed snapshot is drawn, and every click, drag and keystroke reaches
# Swift as the exact researchMap message of the contract. No window is ever shown.
#   tools/tests/research-map-web-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir "$out/web"
cp tools/tests/ResearchMapWebTests.swift "$out/web/main.swift"
swiftc -O -module-cache-path /private/tmp/markview-swift-cache -o "$out/research-map-web-tests" \
  MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift "$out/web/main.swift"
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/research-map-web-tests" "$PWD/MarkView/Resources/Editor"
