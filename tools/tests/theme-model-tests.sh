#!/bin/bash
# Checks the theme model (MarkView/Models/Appearance/AppTheme.swift, ThemeDefinition.swift, ThemeCatalog.swift): the themes that ship as
# files in MarkView/Resources/Themes, what each file gives (native palette, complete web tokens), user theme files from a folder (derivation,
# legibility, every unusable file reported with its reason), the accent rules, per-appearance accent memory, every stored name an earlier
# version wrote, the upgrade from the old light / dark / system setting and what a new window inherits.
# The model is Foundation-only and is compiled on its own with a test main; the Themes folder is copied next to the program, where the app's
# bundle lookup finds it.
#   tools/tests/theme-model-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ThemeModelTests.swift "$out/main.swift"
swiftc -O -module-cache-path /private/tmp/markview-swift-cache -o "$out/theme-model-tests" \
  MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift "$out/main.swift"
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/theme-model-tests"
