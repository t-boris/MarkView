#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

out="$(mktemp -d "${TMPDIR:-/tmp}/markview-phase6-tests.XXXXXX")"
trap 'rm -rf "$out"' EXIT

# Compile the real BrowserControlServer.verifyToken method from production source rather than a handwritten stub.
python3 - "$ROOT" "$out/BrowserControlServerSlice.swift" << 'PY'
import pathlib, re, sys
root, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
src = (root / "MarkView/Models/Browser/BrowserControlServer.swift").read_text()
m = re.search(r'(nonisolated static func verifyToken\b[\s\S]*?\n    \})', src)
if not m:
    raise SystemExit("Could not slice verifyToken from BrowserControlServer.swift")
dst.write_text("import Foundation\n@MainActor\nenum BrowserControlServer {\n    " + m.group(1) + "\n}\n")
PY

cp "$ROOT/tools/tests/Phase6StorageSecurityTests.swift" "$out/main.swift"

swiftc -lsqlite3 -o "$out/phase6-tests" \
    "$out/BrowserControlServerSlice.swift" \
    "$ROOT"/Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    "$ROOT/MarkView/Models/AgentTools/BrowserAgentTools.swift" \
    "$ROOT/MarkView/Models/Workspace/SchemaVersionedStore.swift" \
    "$out/main.swift"

"$out/phase6-tests"
