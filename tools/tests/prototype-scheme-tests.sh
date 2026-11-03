#!/bin/bash
# Checks the Prototype Studio preview's file server (MarkView/Bridge/PrototypeSchemeHandler.swift, BUG-047):
# the path rules, and an end-to-end run in a real WKWebView that a script error keeps its text and line.
# The error listener under test is taken from MarkView/Views/PrototypeStudioView.swift, not copied.
# The app has no XCTest target: the module is compiled on its own with a test main and run.
#   tools/tests/prototype-scheme-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# The listener is a Swift multi-line string inside the view; undo the Swift escaping (\\ -> \).
python3 -I - "$out/listener.js" <<'EOF'
import re, sys
src = open("MarkView/Views/PrototypeStudioView.swift", encoding="utf-8").read()
match = re.search(r"( *window\.addEventListener\('error'.*?\n *\}\);)", src, re.S)
if not match:
    sys.exit("error listener not found in PrototypeStudioView.swift")
open(sys.argv[1], "w", encoding="utf-8").write(match.group(1).replace("\\\\", "\\") + "\n")
EOF

cp tools/tests/PrototypeSchemeTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-scheme-tests" MarkView/Bridge/PrototypeSchemeHandler.swift "$out/main.swift"
"$out/prototype-scheme-tests" "$out/listener.js"
