#!/bin/bash
# The panels of one window (Models/Workspace/WindowChrome.swift): toggles that never hide the last panel, per-window state, and the
# panels a window session saves and restores.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -o "$out/window-chrome-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Appearance/ThemeCatalog.swift \
    MarkView/Models/Appearance/WelcomeBackdrop.swift MarkView/Models/Appearance/BackdropRegistry.swift MarkView/Models/Appearance/ProjectBackdrop.swift \
    MarkView/Models/Workspace/PanelLayout.swift MarkView/Models/Shared/SchemaVersionedStore.swift MarkView/Models/Workspace/ToolRegistry.swift \
    MarkView/Models/Workspace/WindowSession.swift MarkView/Models/Workspace/WindowUIState.swift MarkView/Models/Workspace/WindowChrome.swift \
    MarkView/Models/Git/GitHubItem.swift tools/tests/WindowChromeTests.swift
cp -R MarkView/Resources/Themes "$out/Themes"
"$out/window-chrome-tests"
