#!/bin/bash
# Manual check against the real `claude` CLI (not part of the automatic checks): the hand-off takes the before and after screenshots of one
# screen of a prototype from code and asks the assistant what the application's code must change. The "before" is versions/v<N> of the
# prototype, the "after" its site/ folder.
#   tools/tests/prototype-handoff-live-run.sh <prototype folder> <screen id> <changed files, comma separated> <project root>
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeHandoffLiveRun.swift "$out/main.swift"
swiftc -O -o "$out/live" MarkView/Models/PrototypeFiles.swift MarkView/Models/PrototypeStyles.swift MarkView/Models/PrototypeShellStructure.swift MarkView/Models/PrototypeEmbedded.swift MarkView/Models/PrototypeAI.swift MarkView/Models/PrototypeAI+Handoff.swift MarkView/Models/PrototypeRuntime.swift MarkView/Models/PrototypeAudit.swift MarkView/Models/PrototypeThemes.swift MarkView/Models/PrototypeBaseline.swift MarkView/Models/PrototypeHandoff.swift MarkView/Models/PrototypeHandoffDraft.swift MarkView/Models/PrototypeImages.swift MarkView/Bridge/PrototypeScreenshots.swift MarkView/Bridge/PrototypeSchemeHandler.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/live" "$1" "$2" "$3" "$4"
