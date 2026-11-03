#!/bin/bash
# Checks BUG-050: the inventory the planner reads (tests left out, folder blocks, a cap that keeps widgets and
# stylesheets), the verbatim copy of the app's own stylesheets (MarkView/Models/PrototypeStyles.swift) and
# how the plan carries styles, widgets and hosts. The app has no XCTest target: the modules are compiled on
# their own with a test main and run.
#   tools/tests/prototype-styles-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeStylesTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-styles-tests" MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeStyles.swift MarkView/Models/PrototypeShellStructure.swift MarkView/Models/PrototypeEmbedded.swift \
    MarkView/Models/PrototypeAI.swift MarkView/Models/PrototypeRuntime.swift MarkView/Models/PrototypeAudit.swift MarkView/Models/PrototypeThemes.swift MarkView/Models/PrototypeBaseline.swift MarkView/Models/PrototypeHandoff.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/prototype-styles-tests"
