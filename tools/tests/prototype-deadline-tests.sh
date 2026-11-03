#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/prototype-deadline-tests" \
    MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeStyles.swift MarkView/Models/PrototypeEmbedded.swift MarkView/Models/PrototypeAI.swift MarkView/Models/PrototypeAudit.swift MarkView/Models/PrototypeThemes.swift MarkView/Models/PrototypeBaseline.swift \
    tools/tests/PrototypeDeadlineFixture.swift tools/tests/PrototypeDeadlineTests.swift
"$out/prototype-deadline-tests"
