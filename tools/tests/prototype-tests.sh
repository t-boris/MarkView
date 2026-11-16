#!/bin/bash
# Checks the file rules of Prototype Studio (MarkView/Models/Prototype/PrototypeFiles.swift): path validation,
# edits, versions, the manifest and the progress lines. The module is compiled on its own with a test main and run.
#   tools/tests/prototype-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Prototype/PrototypeFiles.swift MarkView/Models/Prototype/PrototypeStyles.swift MarkView/Models/Prototype/PrototypeShellStructure.swift MarkView/Models/Prototype/PrototypeEmbedded.swift MarkView/Models/AI/AIOperation.swift MarkView/Models/Prototype/PrototypeAI.swift MarkView/Models/Prototype/PrototypePrompts.swift MarkView/Models/Prototype/PrototypeSchemas.swift MarkView/Models/Prototype/PrototypePlan.swift MarkView/Models/Prototype/PrototypeProgress.swift MarkView/Models/Prototype/PrototypeExport.swift MarkView/Models/Prototype/PrototypeRuntime.swift MarkView/Models/Prototype/PrototypeAudit.swift MarkView/Models/Prototype/PrototypeThemes.swift MarkView/Models/Prototype/PrototypeBaseline.swift MarkView/Models/Prototype/PrototypeTailwind.swift MarkView/Models/Prototype/PrototypeHandoff.swift MarkView/Models/Prototype/PrototypeHandoffDraft.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/prototype-tests"
