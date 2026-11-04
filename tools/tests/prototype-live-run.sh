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
swiftc -O -o "$out/live" MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeStyles.swift MarkView/Models/PrototypeShellStructure.swift MarkView/Models/PrototypeEmbedded.swift MarkView/Models/PrototypeAI.swift MarkView/Models/PrototypeRuntime.swift MarkView/Models/PrototypeAudit.swift MarkView/Models/PrototypeThemes.swift MarkView/Models/PrototypeBaseline.swift MarkView/Models/PrototypeTailwind.swift MarkView/Models/PrototypeHandoff.swift MarkView/Models/PrototypeHandoffDraft.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/live" "$1" "$2"
