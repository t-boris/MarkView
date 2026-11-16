#!/bin/bash
# Checks the project search index (MarkView/Models/Shared/ProjectSearch.swift): any text file, binaries by
# name only, entry names inside zip archives.
#   tools/tests/project-search-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ProjectSearchTests.swift "$out/main.swift"
swiftc -O -o "$out/project-search-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Shared/ProjectSearch.swift MarkView/Models/Shared/ArchiveSupport.swift MarkView/Models/Shared/LinkedFolderStore.swift MarkView/Models/Appearance/ProjectColor.swift "$out/main.swift"
"$out/project-search-tests"
