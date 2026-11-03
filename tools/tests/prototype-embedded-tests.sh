#!/bin/bash
# Checks BUG-050, steps 4 to 6: the shell contract for widgets and modals, the host and widget prompts, the effort of
# those runs, the isolated page that needs no assistant, the coverage figure and the read log
# (MarkView/Models/PrototypeEmbedded.swift). The app has no XCTest target: the modules are compiled on their
# own with a test main and run.
#   tools/tests/prototype-embedded-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeEmbeddedTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-embedded-tests" MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeStyles.swift MarkView/Models/PrototypeShellStructure.swift \
    MarkView/Models/PrototypeEmbedded.swift MarkView/Models/PrototypeAI.swift MarkView/Models/PrototypeRuntime.swift MarkView/Models/PrototypeAudit.swift MarkView/Models/PrototypeThemes.swift MarkView/Models/PrototypeBaseline.swift MarkView/Models/PrototypeHandoff.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/prototype-embedded-tests"
