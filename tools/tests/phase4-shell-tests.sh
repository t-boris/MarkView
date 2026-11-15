#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

out="$(mktemp -d "${TMPDIR:-/tmp}/markview-phase4-tests.XXXXXX")"
trap 'rm -rf "$out"' EXIT

cp "$ROOT/tools/tests/Phase4ShellTests.swift" "$out/main.swift"

swiftc \
    "$ROOT"/Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    "$ROOT/MarkView/Models/Workspace/DocumentScrollSideTable.swift" \
    "$ROOT/MarkView/Models/Workspace/TaskBag.swift" \
    "$ROOT/MarkView/Models/Workspace/MarkdownDocumentChunker.swift" \
    "$out/main.swift" \
    -o "$out/phase4-tests"

"$out/phase4-tests"
