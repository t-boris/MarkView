#!/bin/bash
# The welcome screen (feature welcome-screen-with-action-tiles-and-a-falling): the scenes of the four animated backdrops, the list of
# actions, the Core Animation layers a scene becomes, and the shipping WelcomeScreen hosted off screen (a borderless window far outside
# the display, never shown). The files are compiled as they ship; no XCTest target exists.
#   tools/tests/welcome-screen-tests.sh
#   SNAPSHOT_DIR=/some/dir tools/tests/welcome-screen-tests.sh    # also saves a picture of each backdrop and theme
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/WelcomeScreenTests.swift "$out/main.swift"
swiftc -suppress-warnings -target "$(uname -m)-apple-macos13.0" \
    MarkView/Models/Appearance/ProjectBackdrop.swift MarkView/Models/Appearance/WelcomeBackdrop.swift MarkView/Models/Workspace/WelcomeActions.swift MarkView/Models/Workspace/ToolRegistry.swift \
    MarkView/Views/Appearance/ProjectBackdropLayers.swift MarkView/Views/Appearance/DevBackdropLayers.swift MarkView/Views/Appearance/AtmosphereBackdropLayers.swift MarkView/Views/Appearance/BackdropLayerBuilders.swift MarkView/Views/Appearance/WelcomeBackdropView.swift MarkView/Views/Workspace/WelcomeView.swift \
    MarkView/Models/Appearance/AppFontScale.swift MarkView/Views/Appearance/AppFontScaleView.swift MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/WindowTheme.swift MarkView/Views/Appearance/AppPalette.swift \
    "$out/main.swift" -o "$out/welcome-tests"
"$out/welcome-tests"
