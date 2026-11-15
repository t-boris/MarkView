#!/bin/bash
# The panels of one window (Models/Workspace/WindowChrome.swift): toggles that never hide the last panel, per-window state, and the
# panels a window session saves and restores.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# The GitHub tab discriminator is compiled from DocumentState.swift without the document models around it, as window-session-tests does.
python3 - "$out" <<'PY'
import pathlib, sys
source = pathlib.Path('MarkView/Models/Workspace/DocumentState.swift').read_text()
enum = source.split('enum GitHubItem:')[1].split('/// Represents an open tab')[0]
(pathlib.Path(sys.argv[1]) / 'GitHubItem.swift').write_text('import Foundation\nenum GitHubItem:' + enum)
PY
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -o "$out/window-chrome-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/WelcomeBackdrop.swift MarkView/Models/Appearance/ProjectBackdrop.swift \
    MarkView/Models/Workspace/PanelLayout.swift MarkView/Models/Workspace/SchemaVersionedStore.swift MarkView/Models/Workspace/ToolRegistry.swift \
    MarkView/Models/Workspace/WindowSession.swift MarkView/Models/Workspace/WindowUIState.swift MarkView/Models/Workspace/WindowChrome.swift \
    "$out/GitHubItem.swift" tools/tests/WindowChromeTests.swift
"$out/window-chrome-tests"
