#!/bin/bash
# Verify Phase 3 declarative extension points and registries (AR-31, AR-32, AR-33, AR-34)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

cp tools/tests/Phase3ExtensibilityTests.swift "$out/main.swift"
swiftc -o "$out/phase3-extensibility-tests" \
    MarkView/Models/AppTheme.swift \
    MarkView/Models/WelcomeBackdrop.swift \
    MarkView/Models/ProjectBackdrop.swift \
    MarkView/Models/PanelLayout.swift \
    MarkView/Models/ExtensionRegistries.swift \
    "$out/main.swift"

"$out/phase3-extensibility-tests"
