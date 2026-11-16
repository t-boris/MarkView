#!/bin/bash
# Checks the Project Changes scanner (MarkView/Models/Architecture/ProjectChangeReview.swift, BUG-083): skipped caches and agent
# worktrees, binary and large files compared without being read, text changes, and peak memory over a large walk.
#   tools/tests/project-change-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ProjectChangeTests.swift "$out/main.swift"
swiftc -O -o "$out/project-change-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Architecture/ProjectChangeReview.swift MarkView/Models/Shared/ProjectChangeMonitor.swift MarkView/Models/Shared/ProjectSearch.swift \
  MarkView/Models/Shared/ArchiveSupport.swift MarkView/Models/Shared/LinkedFolderStore.swift MarkView/Models/Appearance/ProjectColor.swift "$out/main.swift"
"$out/project-change-tests"
