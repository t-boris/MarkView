#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/prototype-deadline-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Prototype/PrototypeFiles.swift MarkView/Models/Prototype/PrototypeStyles.swift MarkView/Models/Prototype/PrototypeShellStructure.swift MarkView/Models/Prototype/PrototypeEmbedded.swift MarkView/Models/AI/AIOperation.swift MarkView/Models/Prototype/PrototypeAI.swift MarkView/Models/Prototype/PrototypeRuntime.swift MarkView/Models/Prototype/PrototypeAudit.swift MarkView/Models/Prototype/PrototypeThemes.swift MarkView/Models/Prototype/PrototypeBaseline.swift MarkView/Models/Prototype/PrototypeTailwind.swift MarkView/Models/Prototype/PrototypeHandoff.swift MarkView/Models/Prototype/PrototypeHandoffDraft.swift \
    tools/tests/PrototypeDeadlineFixture.swift tools/tests/PrototypeDeadlineTests.swift
"$out/prototype-deadline-tests"
