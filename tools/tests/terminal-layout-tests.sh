#!/bin/bash
# Native WebKit, shipping xterm bundle, TerminalSession bridge, and a live PTY.
# Requires a macOS GUI session; leaves the user's running app untouched.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
python3 - "$out" <<'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
source = pathlib.Path('MarkView/Models/DocumentState.swift').read_text()
(out / 'FileType.swift').write_text(source.split('/// Represents a table of contents heading entry')[0])
(out / 'main.swift').write_text(pathlib.Path('tools/tests/TerminalLayoutTests.swift').read_text())
(out / 'fixture').mkdir()
PY
swiftc -module-cache-path /private/tmp/markview-swift-cache -o "$out/terminal-layout-tests" \
    MarkView/Models/TerminalLink.swift MarkView/Models/TerminalSession.swift MarkView/Models/PTYWriter.swift "$out/FileType.swift" "$out/main.swift"
"$out/terminal-layout-tests" "${1:-$PWD/MarkView/Resources/Editor/terminal.html}" "$out/fixture"
