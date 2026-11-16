#!/bin/bash
# Checks BUG-050, steps 4 to 6: the shell contract for widgets and modals, the host and widget prompts, the effort of
# those runs, the isolated page that needs no assistant, the coverage figure and the read log
# (MarkView/Models/Prototype/PrototypeEmbedded.swift). The app has no XCTest target: the modules are compiled on their
# own with a test main and run.
#   tools/tests/prototype-embedded-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeEmbeddedTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-embedded-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Prototype/PrototypeFiles.swift MarkView/Models/Prototype/PrototypeStyles.swift MarkView/Models/Prototype/PrototypeShellStructure.swift \
    MarkView/Models/Prototype/PrototypeEmbedded.swift MarkView/Models/AI/AIOperation.swift MarkView/Models/Prototype/PrototypeAI.swift MarkView/Models/Prototype/PrototypePrompts.swift MarkView/Models/Prototype/PrototypeSchemas.swift MarkView/Models/Prototype/PrototypePlan.swift MarkView/Models/Prototype/PrototypeProgress.swift MarkView/Models/Prototype/PrototypeExport.swift MarkView/Models/Prototype/PrototypeRuntime.swift MarkView/Models/Prototype/PrototypeAudit.swift MarkView/Models/Prototype/PrototypeThemes.swift MarkView/Models/Prototype/PrototypeBaseline.swift MarkView/Models/Prototype/PrototypeTailwind.swift MarkView/Models/Prototype/PrototypeHandoff.swift MarkView/Models/Prototype/PrototypeHandoffDraft.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/prototype-embedded-tests"
