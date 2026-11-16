#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/window-session-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Shared/SchemaVersionedStore.swift \
    MarkView/Models/Workspace/WindowSession.swift MarkView/Models/Workspace/ToolRegistry.swift MarkView/Models/Workspace/WindowUIState.swift MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/ThemeDefinition.swift MarkView/Models/Git/GitHubItem.swift tools/tests/WindowSessionTests.swift
"$out/window-session-tests" "$@"
