#!/bin/bash
# Checks the hand-off draft of a prototype from code (MarkView/Models/Prototype/PrototypeHandoffDraft.swift): the draft, the feature text, the
# describer's prompt and parser, and the line difference. The app has no XCTest target: the modules are compiled on their own with a
# test main and run.
#   tools/tests/prototype-handoff-draft-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeHandoffDraftTests.swift "$out/main.swift"
swiftc -o "$out/prototype-handoff-draft-tests" MarkView/Models/Prototype/PrototypeFiles.swift MarkView/Models/Prototype/PrototypeStyles.swift MarkView/Models/Prototype/PrototypeShellStructure.swift MarkView/Models/Prototype/PrototypeBaseline.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/Prototype/PrototypeTailwind.swift MarkView/Models/Prototype/PrototypeThemes.swift MarkView/Models/Prototype/PrototypeHandoff.swift MarkView/Models/Prototype/PrototypeHandoffDraft.swift "$out/main.swift"
"$out/prototype-handoff-draft-tests"
