#!/bin/bash
# Pure file classification, text decoding, tree visibility and Explain prompt regressions.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
python3 - "$out/main.swift" <<'PY'
from pathlib import Path
import sys
file_types = Path('MarkView/Models/DocumentState.swift').read_text().split('/// Represents a table of contents heading entry')[0]
prompts = Path('MarkView/Models/CodeExplainer.swift').read_text().split('/// One logical section of a text file')[0]
tree = Path('MarkView/Models/FileNode.swift').read_text()
tests = Path('tools/tests/AllFilesExplainTests.swift').read_text()
Path(sys.argv[1]).write_text(file_types + '\n' + prompts + '\n' + tree + '\n' + tests)
PY
# ArchiveSupport.swift: FileType.hasViewer asks Archive.isArchive.
swiftc -o "$out/all-files-explain-tests" MarkView/Models/ArchiveSupport.swift "$out/main.swift"
"$out/all-files-explain-tests"
