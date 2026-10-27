#!/bin/bash
# Opt-in: uses the installed CLI login and normal provider allowance.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -module-cache-path /private/tmp/markview-swift-cache \
  MarkView/Models/BookPDFSource.swift MarkView/Models/BookPDFTransform.swift MarkView/Models/BookPDFAssistant.swift MarkView/Bridge/BookPDFRenderer.swift \
  MarkView/Models/AIAssistants.swift MarkView/Models/ProjectColor.swift MarkView/Models/LinkedFolders.swift \
  MarkView/Models/AICallLog.swift MarkView/Models/CLICompletion.swift MarkView/Models/AgentProcesses.swift \
  tools/tests/BookPDFLiveChecks.swift -o "$out/book-pdf-live"
"$out/book-pdf-live" "$PWD/MarkView/Resources/Editor/book.html" "${2:-/private/tmp/markview-book-live}" "${1:-claude}" "${3:-both}"
