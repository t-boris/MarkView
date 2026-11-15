#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/IntakeClipboardTests.swift "$out/main.swift"
swiftc -O -o "$out/intake-clipboard-tests" Packages/MarkViewCore/Sources/MarkViewCore/Settings.swift Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift MarkView/Models/Appearance/AppFontScale.swift MarkView/Views/Appearance/AppFontScaleView.swift MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift MarkView/Models/Appearance/WindowTheme.swift MarkView/Models/Appearance/WebThemeArguments.swift Packages/MarkViewCore/Sources/MarkViewCore/JS.swift MarkView/Views/Appearance/AppPalette.swift MarkView/Views/Lifecycle/IntakeTextEditor.swift "$out/main.swift"
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/intake-clipboard-tests" "$@"
