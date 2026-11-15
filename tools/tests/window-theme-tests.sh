#!/bin/bash
# Checks the per-window theme (MarkView/Models/Appearance/WindowTheme.swift, Views/AppPalette.swift, Views/ThemePickerView.swift) without any
# visible window: two windows with two themes at once, accents per appearance, what a new window inherits, that a restored window is
# not a change, the NSWindow appearance each theme gives, the web payload (the theme's own data), SwiftUI views rendered off-screen with
# each palette, a theme file of the person's own, and a stored theme that is missing and comes back. The shipped Themes folder is copied
# next to the program, where the app's bundle lookup finds it.
#   tools/tests/window-theme-tests.sh [folder for picker pictures]
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/WindowThemeTests.swift "$out/main.swift"
swiftc -O -module-cache-path /private/tmp/markview-swift-cache -o "$out/window-theme-tests" \
  MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift \
  MarkView/Models/Appearance/WindowTheme.swift MarkView/Models/Appearance/WebThemeArguments.swift Packages/MarkViewCore/Sources/MarkViewCore/JS.swift MarkView/Models/Appearance/AppFontScale.swift MarkView/Views/Appearance/AppFontScaleView.swift \
  MarkView/Views/Appearance/AppPalette.swift MarkView/Views/Appearance/ThemePickerView.swift "$out/main.swift"
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/window-theme-tests" "${1:-}"
