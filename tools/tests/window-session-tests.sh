#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# Compile the actual GitHub tab discriminator without unrelated document models.
python3 - "$out" <<'PY'
import pathlib, sys
source = pathlib.Path('MarkView/Models/Workspace/DocumentState.swift').read_text()
enum = source.split('enum GitHubItem:')[1].split('/// Represents an open tab')[0]
(pathlib.Path(sys.argv[1]) / 'GitHubItem.swift').write_text('import Foundation\nenum GitHubItem:' + enum)
PY
swiftc -parse-as-library -o "$out/window-session-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Workspace/SchemaVersionedStore.swift \
    MarkView/Models/Workspace/WindowSession.swift MarkView/Models/Workspace/ToolRegistry.swift MarkView/Models/Workspace/WindowUIState.swift MarkView/Models/Appearance/AppTheme.swift "$out/GitHubItem.swift" tools/tests/WindowSessionTests.swift
"$out/window-session-tests" "$@"
