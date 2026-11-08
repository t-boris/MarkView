#!/bin/bash
# Checks the theme model (MarkView/Models/AppTheme.swift): the six appearances, the palettes and their legibility, the accent rules,
# per-appearance accent memory, the settings codec, the upgrade from the old light / dark / system setting and what a new window inherits.
# The module is Foundation-only and is compiled on its own with a test main.
#   tools/tests/theme-model-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ThemeModelTests.swift "$out/main.swift"
swiftc -O -module-cache-path /private/tmp/markview-swift-cache -o "$out/theme-model-tests" MarkView/Models/AppTheme.swift "$out/main.swift"
"$out/theme-model-tests"
