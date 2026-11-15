#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

out="$(mktemp -d "${TMPDIR:-/tmp}/markview-phase5-tests.XXXXXX")"
trap 'rm -rf "$out"' EXIT

cat > "$out/Stub.swift" << 'EOF'
import Foundation
enum ACPAssistant {
    static func cachedModels(_ tool: CLITool) -> [AIModelOption] { [] }
    static func refreshModels(_ tool: CLITool, toolPath: String) async throws -> [AIModelOption] { [] }
    static func run(_ request: CLICompletion.Request, tool: CLITool, toolPath: String, model: String?, workDir: URL,
                    onDelta: (@Sendable (String) -> Void)?, onActivity: (@Sendable (CLICompletion.Activity) -> Void)?)
        async throws -> CLICompletion.Result { fatalError("not used by unit tests") }
}
final class SemanticDatabase {
    func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) {}
    nonisolated static func documentId(for fileURL: URL, root: URL) -> String {
        fileURL.lastPathComponent
    }
}
EOF

cp "$ROOT/tools/tests/Phase5AITests.swift" "$out/main.swift"

swiftc -o "$out/phase5-tests" \
    "$ROOT/MarkView/Models/AIAssistants.swift" \
    "$ROOT/MarkView/Models/AILayer.swift" \
    "$ROOT/MarkView/Models/ProjectColor.swift" \
    "$ROOT/MarkView/Models/LinkedFolders.swift" \
    "$ROOT/MarkView/Models/AICallLog.swift" \
    "$ROOT/MarkView/Models/CLICompletion.swift" \
    "$ROOT/MarkView/Models/AgentProcesses.swift" \
    "$out/Stub.swift" \
    "$out/main.swift"

"$out/phase5-tests"
