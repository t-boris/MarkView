#!/bin/bash
# Project mood selection and bounded local platform inspection. No app, network or AI calls.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# The scenes register their own rules (AR-34): the files that draw them are compiled too.
swiftc -parse-as-library MarkView/Models/Appearance/ProjectBackdrop.swift MarkView/Models/Appearance/WelcomeBackdrop.swift MarkView/Models/Appearance/BackdropRegistry.swift \
    MarkView/Views/Appearance/BackdropLayerBuilders.swift MarkView/Views/Appearance/ProjectBackdropLayers.swift MarkView/Views/Appearance/DevBackdropLayers.swift MarkView/Views/Appearance/AtmosphereBackdropLayers.swift \
    tools/tests/ProjectBackdropChecks.swift -o "$out/project-backdrops"
"$out/project-backdrops"
