#!/bin/bash
# Checks the file rules of Prototype Studio (MarkView/Models/PrototypeFiles.swift): path validation,
# edits, versions, the manifest and the progress lines. The module is compiled on its own with a test main and run.
#   tools/tests/prototype-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-tests" MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeStyles.swift MarkView/Models/PrototypeShellStructure.swift MarkView/Models/PrototypeEmbedded.swift MarkView/Models/PrototypeAI.swift MarkView/Models/PrototypeRuntime.swift MarkView/Models/PrototypeAudit.swift MarkView/Models/PrototypeThemes.swift MarkView/Models/PrototypeBaseline.swift MarkView/Models/PrototypeHandoff.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/prototype-tests"
