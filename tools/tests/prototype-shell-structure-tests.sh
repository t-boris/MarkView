#!/bin/bash
# Checks BUG-060: the page structure of a prototype from code is written and linked by MarkView
# (MarkView/Models/PrototypeShellStructure.swift), kept out of the assistant's reach and out of the sync baseline.
# The app has no XCTest target: the modules are compiled on their own with a test main and run.
#   tools/tests/prototype-shell-structure-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeShellStructureTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-shell-structure-tests" MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeStyles.swift MarkView/Models/PrototypeShellStructure.swift MarkView/Models/PrototypeEmbedded.swift \
    MarkView/Models/PrototypeAI.swift MarkView/Models/PrototypeRuntime.swift MarkView/Models/PrototypeAudit.swift MarkView/Models/PrototypeThemes.swift MarkView/Models/PrototypeBaseline.swift MarkView/Models/PrototypeTailwind.swift MarkView/Models/PrototypeHandoff.swift MarkView/Models/PrototypeHandoffDraft.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/prototype-shell-structure-tests"
