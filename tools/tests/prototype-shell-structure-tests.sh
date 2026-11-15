#!/bin/bash
# Checks BUG-060: the page structure of a prototype from code is written and linked by MarkView
# (MarkView/Models/Prototype/PrototypeShellStructure.swift), kept out of the assistant's reach and out of the sync baseline.
# The app has no XCTest target: the modules are compiled on their own with a test main and run.
#   tools/tests/prototype-shell-structure-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeShellStructureTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-shell-structure-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Prototype/PrototypeFiles.swift MarkView/Models/Prototype/PrototypeStyles.swift MarkView/Models/Prototype/PrototypeShellStructure.swift MarkView/Models/Prototype/PrototypeEmbedded.swift \
    MarkView/Models/Prototype/PrototypeAI.swift MarkView/Models/Prototype/PrototypeRuntime.swift MarkView/Models/Prototype/PrototypeAudit.swift MarkView/Models/Prototype/PrototypeThemes.swift MarkView/Models/Prototype/PrototypeBaseline.swift MarkView/Models/Prototype/PrototypeTailwind.swift MarkView/Models/Prototype/PrototypeHandoff.swift MarkView/Models/Prototype/PrototypeHandoffDraft.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/prototype-shell-structure-tests"
