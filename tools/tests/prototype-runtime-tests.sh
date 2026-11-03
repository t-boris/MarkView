#!/bin/bash
# Checks the built-in prototype runtime of requirements mode (MarkView/Models/PrototypeRuntime.swift, BUG-056) in a real
# WKWebView served by PrototypeSchemeHandler: the shell, routing, the DB, the Prototype menu states, renderScreen, the
# preview audit (PrototypeAudit.script) and the error report the Studio's own listener receives.
#   tools/tests/prototype-runtime-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# The listener is a Swift multi-line string inside the view; undo the Swift escaping (\\ -> \).
python3 -I - "$out/listener.js" <<'PY'
import re, sys
src = open("MarkView/Views/PrototypeStudioView.swift", encoding="utf-8").read()
match = re.search(r"( *window\.addEventListener\('error'.*?\n *\}\);)", src, re.S)
if not match:
    sys.exit("error listener not found in PrototypeStudioView.swift")
open(sys.argv[1], "w", encoding="utf-8").write(match.group(1).replace("\\\\", "\\") + "\n")
PY

cp tools/tests/PrototypeRuntimeTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-runtime-tests" MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeStyles.swift \
  MarkView/Models/PrototypeEmbedded.swift MarkView/Models/PrototypeAI.swift MarkView/Models/PrototypeRuntime.swift \
  MarkView/Models/PrototypeAudit.swift MarkView/Models/PrototypeThemes.swift MarkView/Models/PrototypeBaseline.swift \
  MarkView/Models/PrototypeHandoff.swift MarkView/Bridge/PrototypeSchemeHandler.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/prototype-runtime-tests" "$out/listener.js"
