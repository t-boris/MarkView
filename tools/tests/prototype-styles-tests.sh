#!/bin/bash
# Checks BUG-050: the inventory the planner reads (tests left out, folder blocks, a cap that keeps widgets and
# stylesheets), the verbatim copy of the app's own stylesheets (MarkView/Models/Prototype/PrototypeStyles.swift) and
# how the plan carries styles, widgets and hosts. The app has no XCTest target: the modules are compiled on
# their own with a test main and run.
#   tools/tests/prototype-styles-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeStylesTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-styles-tests" MarkView/Models/Prototype/PrototypeFiles.swift MarkView/Models/Prototype/PrototypeStyles.swift MarkView/Models/Prototype/PrototypeShellStructure.swift MarkView/Models/Prototype/PrototypeEmbedded.swift \
    MarkView/Models/Prototype/PrototypeAI.swift MarkView/Models/Prototype/PrototypeRuntime.swift MarkView/Models/Prototype/PrototypeAudit.swift MarkView/Models/Prototype/PrototypeThemes.swift MarkView/Models/Prototype/PrototypeBaseline.swift MarkView/Models/Prototype/PrototypeTailwind.swift MarkView/Models/Prototype/PrototypeHandoff.swift MarkView/Models/Prototype/PrototypeHandoffDraft.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/prototype-styles-tests"
