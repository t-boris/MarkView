#!/bin/bash
# The welcome backdrops as a registry (AR-34, DEC-001): the backdrops the app registers keep their stored names, titles, symbols, order,
# Shuffle pool and By Project rules; and a backdrop that is only registered (fakes in the test) appears in the picker list, in Shuffle's
# pool, in By Project and in the layer builder's dispatch with no list, enum or switch edited. The real model and scene files are compiled;
# no window is made.
#   tools/tests/backdrop-registry-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BackdropRegistryTests.swift "$out/main.swift"
swiftc -suppress-warnings -module-cache-path /private/tmp/markview-swift-cache -target "$(uname -m)-apple-macos13.0" \
    MarkView/Models/Appearance/BackdropRegistry.swift MarkView/Models/Appearance/WelcomeBackdrop.swift MarkView/Models/Appearance/ProjectBackdrop.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift \
    MarkView/Views/Appearance/BackdropLayerBuilders.swift MarkView/Views/Appearance/ProjectBackdropLayers.swift MarkView/Views/Appearance/DevBackdropLayers.swift MarkView/Views/Appearance/AtmosphereBackdropLayers.swift \
    "$out/main.swift" -o "$out/backdrop-registry-tests"
"$out/backdrop-registry-tests"
