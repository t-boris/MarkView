#!/bin/bash
# Compile the production executor unchanged, without the workspace/socket host.
set -euo pipefail
cd "$(dirname "$0")/../.."
qa_frame_out=$(mktemp -d)
trap 'rm -rf "$qa_frame_out"' EXIT
python3 - "$qa_frame_out/Executor.swift" <<'PY'
from pathlib import Path
import sys
s=Path('MarkView/Models/BrowserControlServer.swift').read_text()
Path(sys.argv[1]).write_text('import AppKit\nimport WebKit\n@MainActor\n'+s[s.index('enum BrowserAgentExecutor {'):])
PY
swiftc -parse-as-library -o "$qa_frame_out/checks" "$qa_frame_out/Executor.swift" MarkView/Models/QAWebWindow.swift tools/tests/BrowserFrameChecks.swift
"$qa_frame_out/checks"
