#!/bin/bash
# Checks the hand-off draft of a prototype from code (MarkView/Models/PrototypeHandoffDraft.swift): the draft, the feature text, the
# describer's prompt and parser, and the line difference. The app has no XCTest target: the modules are compiled on their own with a
# test main and run.
#   tools/tests/prototype-handoff-draft-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeHandoffDraftTests.swift "$out/main.swift"
swiftc -o "$out/prototype-handoff-draft-tests" MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeStyles.swift MarkView/Models/PrototypeShellStructure.swift MarkView/Models/PrototypeBaseline.swift MarkView/Models/PrototypeTailwind.swift MarkView/Models/PrototypeThemes.swift MarkView/Models/PrototypeHandoff.swift MarkView/Models/PrototypeHandoffDraft.swift "$out/main.swift"
"$out/prototype-handoff-draft-tests"
