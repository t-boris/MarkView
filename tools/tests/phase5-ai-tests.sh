#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

out="$(mktemp -d "${TMPDIR:-/tmp}/markview-phase5-tests.XXXXXX")"
trap 'rm -rf "$out"' EXIT

cat > "$out/Stub.swift" << 'EOF'
import Foundation
enum ACPAssistant {
    static func refreshModels(_ tool: CLITool, toolPath: String) async throws -> [AIModelOption] { [] }
    static func run(_ request: CLICompletion.Request, tool: CLITool, toolPath: String, model: String?, workDir: URL,
                    onDelta: (@Sendable (String) -> Void)?, onActivity: (@Sendable (CLICompletion.Activity) -> Void)?)
        async throws -> CLICompletion.Result { fatalError("not used by unit tests") }
}
actor SemanticDatabase {
    func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) {}
    nonisolated static func documentId(for fileURL: URL, root: URL) -> String {
        fileURL.lastPathComponent
    }
}
EOF

cp "$ROOT/tools/tests/Phase5AITests.swift" "$out/main.swift"

swiftc -o "$out/phase5-tests" \
    "$ROOT"/Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    "$ROOT/MarkView/Models/AI/AIAssistants.swift" \
    "$ROOT/MarkView/Models/AI/AIOperation.swift" \
    "$ROOT"/MarkView/Models/AI/Providers/*.swift \
    "$ROOT/MarkView/Models/Appearance/ProjectColor.swift" \
    "$ROOT/MarkView/Models/Shared/LinkedFolders.swift" "$ROOT/MarkView/Models/Shared/LinkedFolderStore.swift" \
    "$ROOT/MarkView/Models/AI/AICallLog.swift" \
    "$ROOT/MarkView/Models/AI/CLICompletion.swift" \
    "$out/Stub.swift" \
    "$out/main.swift"

"$out/phase5-tests"
