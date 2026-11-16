#!/bin/bash
# Checks the Discussion model and store (MarkView/Models/Discussion/Discussion.swift): turns, notes, decisions, persistence.
#   tools/tests/discussion-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DiscussionTests.swift "$out/main.swift"
swiftc -O -o "$out/discussion-tests" MarkView/Models/Discussion/Discussion.swift MarkView/Models/Shared/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/Discussion/DiscussionPrompt.swift tools/tests/StoreTestSupport.swift "$out/main.swift"
"$out/discussion-tests"
