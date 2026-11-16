#!/bin/bash
# BUG-107: the shipping "Observed file changes" tab, hosted off screen (a borderless window far outside the display, never
# shown), measured at the widths a person has it: the file list stays narrow and the changes get the rest (BUG-109 made it a tab).
# The view is compiled as it ships; the model and the workspace are stand-ins inside the test file (no XCTest target exists).
#   tools/tests/project-change-review-layout-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ProjectChangeReviewLayoutTests.swift "$out/main.swift"
swiftc -target "$(uname -m)-apple-macos13.0" \
    Packages/MarkViewCore/Sources/MarkViewCore/Settings.swift Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift MarkView/Models/Appearance/WebThemeArguments.swift Packages/MarkViewCore/Sources/MarkViewCore/JS.swift MarkView/Views/Architecture/ProjectChangeReviewView.swift MarkView/Models/Workspace/ToolRegistry.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/Architecture/TextDiff.swift MarkView/Models/Architecture/ChangeExplanation.swift MarkView/Models/AI/OutputLanguage.swift MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/StoredJSON.swift Packages/MarkViewCore/Sources/MarkViewCore/TaskBag.swift MarkView/Models/Appearance/WindowTheme.swift \
    MarkView/Views/Appearance/AppPalette.swift "$out/main.swift" -o "$out/layout-tests"
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/layout-tests"
