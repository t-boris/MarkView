#!/bin/bash
# Checks BUG-063: a prototype made from the code of a Tailwind v4 app carries Tailwind (MarkView/Models/PrototypeTailwind.swift): the source
# stylesheet becomes a text/tailwindcss style next to the browser build, both linked from every page, kept out of the sync baseline.
# The app has no XCTest target: the modules are compiled on their own with a test main and run.
#   tools/tests/prototype-tailwind-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeTailwindTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-tailwind-tests" MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeStyles.swift MarkView/Models/PrototypeShellStructure.swift MarkView/Models/PrototypeTailwind.swift \
    MarkView/Models/PrototypeEmbedded.swift MarkView/Models/PrototypeAI.swift MarkView/Models/PrototypeRuntime.swift MarkView/Models/PrototypeAudit.swift MarkView/Models/PrototypeThemes.swift \
    MarkView/Models/PrototypeBaseline.swift MarkView/Models/PrototypeHandoff.swift MarkView/Models/PrototypeHandoffDraft.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/prototype-tailwind-tests"
