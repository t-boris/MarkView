#!/bin/bash
# Checks the Book X-Ray skeleton (MarkView/Models/Architecture/BookBuilder.swift), the wiki-link chooser
# (WikiLinkResolver.swift) and the AI annotation step (BookAnnotator.swift): headings of every text format, slugs, nested sections with line
# ranges, link resolution down to the section, reading order, nodes and edges. The app has no
# XCTest target: the modules are compiled on their own with a test main and run.
#   tools/tests/book-xray-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BookXRayTests.swift "$out/main.swift"
# OutputLanguage.swift provides ContentHash (the chapter signature) and the output-language setting;
# XRayContent.swift builds the item nodes under a section.
swiftc -o "$out/book-xray-tests" Packages/MarkViewCore/Sources/MarkViewCore/Settings.swift Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift MarkView/Models/Architecture/BookBuilder.swift MarkView/Models/Shared/WikiLinkResolver.swift \
    MarkView/Models/Architecture/BookAnnotator.swift MarkView/Models/Architecture/XRayContent.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/StoredJSON.swift MarkView/Models/AI/OutputLanguage.swift "$out/main.swift"
"$out/book-xray-tests"
