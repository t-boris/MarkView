#!/bin/bash
# Reading a unified diff (AR-16 split of ArchitectureStore): the shipping ChangeDiff over what git itself prints for a temporary
# repository. `editorLines` is the real helper, cut out of CodeExplainer.swift (as all-files-explain-tests does). No window, no assistant.
#   tools/tests/change-diff-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
python3 - "$out/EditorLines.swift" <<'PY'
from pathlib import Path
import sys
text = Path('MarkView/Models/Architecture/CodeExplainer.swift').read_text()
start = text.index('extension String {')
end = text.index('\n}\n', start) + 3
Path(sys.argv[1]).write_text('import Foundation\n' + text[start:end])
PY
# XRayContent only needs the shape of an ArchNode to compile; ChangeDiff reads outlines, never nodes (the stand-in xray-content-tests uses).
cat > "$out/ArchNodeStub.swift" <<'SWIFT'
struct ArchNode {
    var id: String; var parent: String?; var kind: String; var name: String; var path: String?
    var files: Int; var summary: String?; var line: Int?; var anchor: String?
    init(id: String, parent: String?, kind: String, name: String, path: String? = nil, files: Int = 0, summary: String? = nil) {
        self.id = id; self.parent = parent; self.kind = kind; self.name = name; self.path = path; self.files = files; self.summary = summary
    }
}
SWIFT
cp tools/tests/ChangeDiffTests.swift "$out/main.swift"
swiftc -o "$out/change-diff-tests" -target "$(uname -m)-apple-macos13.0" \
    Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift \
    MarkView/Models/Architecture/ChangeDiff.swift MarkView/Models/Architecture/ChangeReviewModel.swift MarkView/Models/Architecture/XRayContent.swift "$out/ArchNodeStub.swift" \
    "$out/EditorLines.swift" "$out/main.swift"
"$out/change-diff-tests"
