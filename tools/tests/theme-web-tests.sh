#!/bin/bash
# The window themes in the shipped web pages (editor, discussion thread, terminal), in real WebKit with hidden windows:
# every appearance paints the real elements with its tokens, text pairs are legible, an accent override and its reset
# work, a theme change restyles without reloading or losing text and scroll, two pages hold different appearances,
# and Classic Dark/Light still paint every sampled element as the page did before themes (DEC-003, DEC-004, DEC-006). The pages hold no
# colours of their own: the test sends them what the app sends (WindowTheme, built from the Themes folder copied next to the program),
# including two theme files with native colours only, written the way a person would (AR-32, DEC-003).
#   tools/tests/theme-web-tests.sh                       check the page in the working tree
#   tools/tests/theme-web-tests.sh <editor folder>       check another copy of the editor folder
#   tools/tests/theme-web-tests.sh capture <editor folder> <out.json>
#       write the computed colours of the Classic appearances (how Tests/Fixtures/themes/classic-computed.json was made,
#       from the editor folder of origin/main before the themes existed)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir "$out/web"
cp tools/tests/ThemeWebTests.swift "$out/web/main.swift"
swiftc -O -module-cache-path /private/tmp/markview-swift-cache -o "$out/theme-web-tests" \
  Packages/MarkViewCore/Sources/MarkViewCore/Settings.swift Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift MarkView/Models/Appearance/WebThemeArguments.swift Packages/MarkViewCore/Sources/MarkViewCore/JS.swift MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift \
  MarkView/Models/Appearance/WindowTheme.swift MarkView/Models/Appearance/AppFontScale.swift MarkView/Views/Appearance/AppFontScaleView.swift \
  MarkView/Views/Appearance/AppPalette.swift MarkView/Views/Appearance/ThemePickerView.swift "$out/web/main.swift"
cp -R MarkView/Resources/Themes "$out/Themes"
if [ "${1:-}" = "capture" ]; then
  "$out/theme-web-tests" capture "$2" "$3"
else
  "$out/theme-web-tests" "${1:-$PWD/MarkView/Resources/Editor}" "$PWD/Tests/Fixtures/themes/classic-computed.json"
fi
