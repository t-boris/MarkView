#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeBaselineTests.swift "$out/main.swift"
swiftc -o "$out/prototype-baseline-tests" MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeStyles.swift MarkView/Models/PrototypeShellStructure.swift MarkView/Models/PrototypeBaseline.swift MarkView/Models/PrototypeTailwind.swift MarkView/Models/PrototypeThemes.swift MarkView/Models/PrototypeHandoff.swift MarkView/Models/PrototypeHandoffDraft.swift "$out/main.swift"
"$out/prototype-baseline-tests"
