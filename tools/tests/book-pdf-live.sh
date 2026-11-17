#!/bin/bash
# Opt-in: uses the installed CLI login and normal provider allowance.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -module-cache-path /private/tmp/markview-swift-cache Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
  MarkView/Models/Book/BookPDFSource.swift MarkView/Models/Book/BookPDFTransform.swift MarkView/Models/Book/BookPDFAssistant.swift MarkView/Bridge/BookPDFRenderer.swift \
  MarkView/Models/AI/AIAssistants.swift MarkView/Models/AI/Providers/*.swift MarkView/Models/Appearance/ProjectColor.swift MarkView/Models/Shared/LinkedFolders.swift MarkView/Models/Shared/LinkedFolderStore.swift \
  MarkView/Models/AI/AICallLog.swift MarkView/Models/AI/AIOperation.swift MarkView/Models/AI/CLICompletion.swift \
  tools/tests/BookPDFLiveChecks.swift -o "$out/book-pdf-live"
"$out/book-pdf-live" "$PWD/MarkView/Resources/Editor/book.html" "${2:-/private/tmp/markview-book-live}" "${1:-claude}" "${3:-both}"
