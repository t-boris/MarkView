#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

out="$(mktemp -d "${TMPDIR:-/tmp}/markview-phase6-tests.XXXXXX")"
trap 'rm -rf "$out"' EXIT

cp "$ROOT/tools/tests/Phase6StorageSecurityTests.swift" "$out/main.swift"

swiftc -lsqlite3 -o "$out/phase6-tests" \
    "$ROOT"/Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    "$ROOT/MarkView/Models/AgentTools/BrowserAgentTools.swift" \
    "$ROOT/MarkView/Models/Workspace/SchemaVersionedStore.swift" \
    tools/tests/StoreTestSupport.swift "$out/main.swift"

"$out/phase6-tests"
