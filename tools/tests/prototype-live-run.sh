#!/bin/bash
# Manual check against the real `claude` CLI (not part of the automatic checks): builds a prototype from a
# requirements file, revises it, writes the specification and packs the archive.
#   tools/tests/prototype-live-run.sh <project root> <source path relative to the root>
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeLiveRun.swift "$out/main.swift"
swiftc -O -parse-as-library -o /dev/null /dev/null 2>/dev/null || true
swiftc -O -o "$out/live" MarkView/Models/Prototype/PrototypeFiles.swift MarkView/Models/Prototype/PrototypeStyles.swift MarkView/Models/Prototype/PrototypeShellStructure.swift MarkView/Models/Prototype/PrototypeEmbedded.swift MarkView/Models/Prototype/PrototypeAI.swift MarkView/Models/Prototype/PrototypeRuntime.swift MarkView/Models/Prototype/PrototypeAudit.swift MarkView/Models/Prototype/PrototypeThemes.swift MarkView/Models/Prototype/PrototypeBaseline.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/Prototype/PrototypeTailwind.swift MarkView/Models/Prototype/PrototypeHandoff.swift MarkView/Models/Prototype/PrototypeHandoffDraft.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/live" "$1" "$2"
