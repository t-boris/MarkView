#!/bin/bash
# Checks the rules of the Files panel (MarkView/Models/FileBrowserModel.swift): views' filters, sort, the
# Workspace level, the tree and its recursive search, and the viewer classification
# (FileType.hasViewer). The app has no XCTest target: the production modules are compiled on their own
# with a test main and run.
#   tools/tests/file-browser-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
python3 - "$out/filetype.swift" <<'PY'
from pathlib import Path
import sys
source = Path('MarkView/Models/DocumentState.swift').read_text().split('/// Represents a table of contents heading entry')[0]
Path(sys.argv[1]).write_text(source)
PY
cp tools/tests/FileBrowserTests.swift "$out/main.swift"
swiftc -o "$out/file-browser-tests" "$out/filetype.swift" MarkView/Models/ArchiveSupport.swift \
    MarkView/Models/FileNode.swift MarkView/Models/WindowUIState.swift MarkView/Models/FileBrowserModel.swift "$out/main.swift"
"$out/file-browser-tests"
