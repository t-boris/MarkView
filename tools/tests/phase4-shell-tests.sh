#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

out="$(mktemp -d "${TMPDIR:-/tmp}/markview-phase4-tests.XXXXXX")"
trap 'rm -rf "$out"' EXIT

cat > "$out/Stubs.swift" << 'EOF'
import Foundation

struct LinkedFolder: Equatable {
    var id: String
    var path: String
}

struct OpenTab: Identifiable {
    var id = UUID()
    var url: URL
}

struct NewProjectRequest {}
struct BookPDFSelection {}
struct ProjectOperationEditRequest {}
struct HandoffResume {}

enum CLICompletion {
    struct Assistant {}
}

@MainActor
final class WindowTheme {}
EOF

cp "$ROOT/tools/tests/Phase4ShellTests.swift" "$out/main.swift"

swiftc \
    "$out/Stubs.swift" \
    "$ROOT/MarkView/Core/Subprocess.swift" \
    "$ROOT/MarkView/Core/CoreFiles.swift" \
    "$ROOT/MarkView/Core/SettingsRegistry.swift" \
    "$ROOT/MarkView/Models/WindowUIState.swift" \
    "$ROOT/MarkView/Models/WelcomeBackdrop.swift" \
    "$ROOT/MarkView/Models/ProjectBackdrop.swift" \
    "$ROOT/MarkView/Models/PanelLayout.swift" \
    "$ROOT/MarkView/Models/AppTheme.swift" \
    "$ROOT/MarkView/Models/ExtensionRegistries.swift" \
    "$ROOT/MarkView/Models/WorkspaceControllers.swift" \
    "$out/main.swift" \
    -o "$out/phase4-tests"

"$out/phase4-tests"
