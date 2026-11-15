#!/bin/bash
# Where the Pull request X-Ray's changes come from (AR-16 split of ArchitectureStore): the shipping ChangeSource over a real temporary git
# repository, with the GitHub integration off. `editorLines` is the real helper cut out of CodeExplainer.swift; GitHubClient.swift
# needs the stand-in CLIToolLocator the other GitHub suites use. No window, no assistant.
#   tools/tests/change-source-tests.sh
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
cp tools/tests/ChangeSourceTests.swift "$out/main.swift"
swiftc -o "$out/change-source-tests" -target "$(uname -m)-apple-macos13.0" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Architecture/ChangeSource.swift MarkView/Models/Architecture/ChangeReviewModel.swift \
    MarkView/Models/Architecture/HistoricalBaseline.swift MarkView/Models/Git/GitHubClient.swift \
    MarkView/Models/AI/OutputLanguage.swift tools/tests/CLIToolLocatorStub.swift \
    "$out/EditorLines.swift" "$out/main.swift"
"$out/change-source-tests"
