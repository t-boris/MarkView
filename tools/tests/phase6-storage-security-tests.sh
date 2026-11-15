#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

out="$(mktemp -d "${TMPDIR:-/tmp}/markview-phase6-tests.XXXXXX")"
trap 'rm -rf "$out"' EXIT

cat > "$out/Stubs.swift" << 'EOF'
import Foundation

@MainActor
enum BrowserControlServer {
    nonisolated static func verifyToken(_ provided: String?, expected: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        guard let provided, !provided.isEmpty else { return false }
        return provided == expected
    }
}
EOF

cp "$ROOT/tools/tests/Phase6StorageSecurityTests.swift" "$out/main.swift"

swiftc -lsqlite3 -o "$out/phase6-tests" \
    "$out/Stubs.swift" \
    "$ROOT/MarkView/Core/CoreFiles.swift" \
    "$ROOT/MarkView/Models/BrowserAgentTools.swift" \
    "$ROOT/MarkView/Models/StorageAndSecurity.swift" \
    "$out/main.swift"

"$out/phase6-tests"
