#!/bin/bash
# Checks the per-window theme (MarkView/Models/WindowTheme.swift, Views/AppPalette.swift, Views/ThemePickerView.swift) without any
# visible window: two windows with two themes at once, accents per appearance, what a new window inherits, that a restored window is
# not a change, the NSWindow appearance each theme gives, the web payload, and SwiftUI views rendered off-screen with each palette.
#   tools/tests/window-theme-tests.sh [folder for picker pictures]
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/WindowThemeTests.swift "$out/main.swift"
swiftc -O -module-cache-path /private/tmp/markview-swift-cache -o "$out/window-theme-tests" \
  MarkView/Models/AppTheme.swift MarkView/Models/WindowTheme.swift MarkView/Models/AppFontScale.swift \
  MarkView/Views/AppPalette.swift MarkView/Views/ThemePickerView.swift "$out/main.swift"
"$out/window-theme-tests" "${1:-}"
