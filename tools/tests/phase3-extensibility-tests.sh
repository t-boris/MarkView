#!/bin/bash
# Verify Phase 3 declarative extension points and registries (AR-31, AR-32, AR-33, AR-34)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

cp tools/tests/Phase3ExtensibilityTests.swift "$out/main.swift"
swiftc -o "$out/phase3-extensibility-tests" \
    MarkView/Models/Appearance/AppTheme.swift \
    MarkView/Models/Appearance/ThemeDefinition.swift \
    MarkView/Models/Appearance/BackdropRegistry.swift \
    MarkView/Models/Appearance/WelcomeBackdrop.swift \
    MarkView/Models/Appearance/ProjectBackdrop.swift \
    MarkView/Models/Workspace/PanelLayout.swift \
    MarkView/Models/Workspace/ToolRegistry.swift \
    MarkView/Models/Workspace/WelcomeActions.swift \
    "$out/main.swift"

"$out/phase3-extensibility-tests"
