#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/prototype-deadline-tests" \
    MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeAI.swift \
    tools/tests/PrototypeDeadlineFixture.swift tools/tests/PrototypeDeadlineTests.swift
"$out/prototype-deadline-tests"
