#!/bin/bash
# Checks BUG-063: a prototype made from the code of a Tailwind v4 app carries Tailwind (MarkView/Models/Prototype/PrototypeTailwind.swift): the source
# stylesheet becomes a text/tailwindcss style next to the browser build, both linked from every page, kept out of the sync baseline.
# The app has no XCTest target: the modules are compiled on their own with a test main and run.
#   tools/tests/prototype-tailwind-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeTailwindTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-tailwind-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Prototype/PrototypeFiles.swift MarkView/Models/Prototype/PrototypeStyles.swift MarkView/Models/Prototype/PrototypeShellStructure.swift MarkView/Models/Prototype/PrototypeTailwind.swift \
    MarkView/Models/Prototype/PrototypeEmbedded.swift MarkView/Models/Prototype/PrototypeAI.swift MarkView/Models/Prototype/PrototypeRuntime.swift MarkView/Models/Prototype/PrototypeAudit.swift MarkView/Models/Prototype/PrototypeThemes.swift \
    MarkView/Models/Prototype/PrototypeBaseline.swift MarkView/Models/Prototype/PrototypeHandoff.swift MarkView/Models/Prototype/PrototypeHandoffDraft.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/prototype-tailwind-tests"
