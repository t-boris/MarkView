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
swiftc -O -o "$out/live" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Prototype/PrototypeFiles.swift MarkView/Models/Prototype/PrototypeStyles.swift MarkView/Models/Prototype/PrototypeShellStructure.swift MarkView/Models/Prototype/PrototypeEmbedded.swift MarkView/Models/Prototype/PrototypeAI.swift MarkView/Models/Prototype/PrototypeAI+Handoff.swift MarkView/Models/Prototype/PrototypeRuntime.swift MarkView/Models/Prototype/PrototypeAudit.swift MarkView/Models/Prototype/PrototypeThemes.swift MarkView/Models/Prototype/PrototypeBaseline.swift MarkView/Models/Prototype/PrototypeTailwind.swift MarkView/Models/Prototype/PrototypeHandoff.swift MarkView/Models/Prototype/PrototypeHandoffDraft.swift MarkView/Models/Workspace/ImageAttachments.swift MarkView/Models/Prototype/PrototypeImages.swift MarkView/Bridge/PrototypeScreenshots.swift MarkView/Bridge/PrototypeSchemeHandler.swift tools/tests/PrototypeCLIStub.swift "$out/main.swift"
"$out/live" "$1" "$2" "$3" "$4"
