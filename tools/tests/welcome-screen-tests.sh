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
    MarkView/Models/ProjectBackdrop.swift MarkView/Models/WelcomeBackdrop.swift MarkView/Models/WelcomeActions.swift \
    MarkView/Views/ProjectBackdropLayers.swift MarkView/Views/BackdropLayerBuilders.swift MarkView/Views/WelcomeBackdropView.swift MarkView/Views/WelcomeView.swift \
    MarkView/Models/AppFontScale.swift MarkView/Models/AppTheme.swift MarkView/Models/WindowTheme.swift MarkView/Views/AppPalette.swift \
    "$out/main.swift" -o "$out/welcome-tests"
"$out/welcome-tests"
