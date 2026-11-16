#!/bin/bash
# Checks the built-in prototype runtime of requirements mode (MarkView/Models/Prototype/PrototypeRuntime.swift, BUG-056) in a real
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
src = open("MarkView/Views/Prototype/PrototypeStudioView.swift", encoding="utf-8").read()
match = re.search(r"( *window\.addEventListener\('error'.*?\n *\}\);)", src, re.S)
if not match:
    sys.exit("error listener not found in PrototypeStudioView.swift")
open(sys.argv[1], "w", encoding="utf-8").write(match.group(1).replace("\\\\", "\\") + "\n")
PY

cp tools/tests/PrototypeRuntimeTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-runtime-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Prototype/PrototypeFiles.swift MarkView/Models/Prototype/PrototypeStyles.swift MarkView/Models/Prototype/PrototypeShellStructure.swift \
  MarkView/Models/Prototype/PrototypeEmbedded.swift MarkView/Models/AI/AIOperation.swift MarkView/Models/Prototype/PrototypeAI.swift MarkView/Models/Prototype/PrototypePrompts.swift MarkView/Models/Prototype/PrototypeSchemas.swift MarkView/Models/Prototype/PrototypePlan.swift MarkView/Models/Prototype/PrototypeProgress.swift MarkView/Models/Prototype/PrototypeExport.swift MarkView/Models/Prototype/PrototypeRuntime.swift \
  MarkView/Models/Prototype/PrototypeAudit.swift MarkView/Models/Prototype/PrototypeThemes.swift MarkView/Models/Prototype/PrototypeBaseline.swift MarkView/Models/Prototype/PrototypeTailwind.swift \
  MarkView/Models/Prototype/PrototypeHandoff.swift MarkView/Models/Prototype/PrototypeHandoffDraft.swift MarkView/Bridge/PrototypeSchemeHandler.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/prototype-runtime-tests" "$out/listener.js"
