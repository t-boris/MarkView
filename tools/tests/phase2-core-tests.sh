#!/bin/bash
# Verify Phase 2 Core infrastructure and MarkViewCore Swift package (AR-18, AR-24, AR-25, AR-27, AR-44 step 2)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

swift test --package-path Packages/MarkViewCore

cp tools/tests/Phase2CoreTests.swift "$out/main.swift"
swiftc -o "$out/phase2-core-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/AI/OutputLanguage.swift \
    "$out/main.swift"

"$out/phase2-core-tests"
