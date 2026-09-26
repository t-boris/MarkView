#!/bin/bash
# Real WKWebView + shipping xterm bundle + TerminalSession bridge and live PTY cwd.
# Requires a macOS GUI session. Browser/default-app opens are captured in the harness.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# Compile the actual FileType enum without the unrelated document/tab models.
python3 - "$out" <<'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
source = pathlib.Path('MarkView/Models/DocumentState.swift').read_text()
(out / 'FileType.swift').write_text(source.split('/// Represents a table of contents heading entry')[0])
(out / 'main.swift').write_text(pathlib.Path('tools/tests/TerminalLinkTests.swift').read_text())
root = out / 'fixtures'
(root / 'sub').mkdir(parents=True)
for name in ['sample.swift', 'spaced file.md', 'README.md', 'LICENSE', 'literal%20.md', 'colon:42', 'archive.zip', 'sub/child.swift']:
    (root / name).write_text('test fixture\n')
PY
swiftc -module-cache-path /private/tmp/markview-swift-cache -o "$out/terminal-link-tests" \
    MarkView/Models/TerminalLink.swift MarkView/Models/TerminalSession.swift "$out/FileType.swift" "$out/main.swift"
"$out/terminal-link-tests" "$PWD/MarkView/Resources/Editor/terminal.html" "$out/fixtures" "$@"

cp tools/tests/EditorLineLinkTests.swift "$out/main.swift"
swiftc -module-cache-path /private/tmp/markview-swift-cache -o "$out/editor-line-tests" "$out/main.swift"
"$out/editor-line-tests" "$PWD/MarkView/Resources/Editor/index.html"
