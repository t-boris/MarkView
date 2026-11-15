#!/bin/bash
# Layout presets (AR-33, DEC-002): the shipped presets, the validator and the loader of a person's folder, and applying a preset to one
# window's PanelLayout without touching another's. The app has no XCTest target: the production modules are compiled on their own with a
# test main and run.
#   tools/tests/layout-preset-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/LayoutPresetTests.swift "$out/main.swift"
swiftc -suppress-warnings -target "$(uname -m)-apple-macos13.0" -o "$out/layout-preset-tests" \
    MarkView/Models/Workspace/LayoutPreset.swift MarkView/Models/Workspace/LayoutCatalog.swift MarkView/Models/Workspace/PanelLayout.swift \
    MarkView/Models/Workspace/ToolRegistry.swift MarkView/Models/Appearance/WelcomeBackdrop.swift MarkView/Models/Appearance/ProjectBackdrop.swift \
    "$out/main.swift"
"$out/layout-preset-tests" "$PWD/MarkView/Resources/Layouts"
