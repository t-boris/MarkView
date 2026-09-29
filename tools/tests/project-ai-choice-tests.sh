#!/bin/bash
# Checks per-project assistant choices (BUG-021): AIAssistants.swift and CLICompletion.swift are
# compiled with a stub ACP client and a test main, then run.
#   tools/tests/project-ai-choice-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ProjectAIChoiceTests.swift "$out/main.swift"
# The ACP client (Cline, Copilot) and the usage database are app-only; the checks never reach them.
cat > "$out/Stub.swift" <<'SWIFT'
import Foundation
enum ACPAssistant {
    static func cachedModels(_ tool: CLITool) -> [AIModelOption] { [] }
    static func refreshModels(_ tool: CLITool, toolPath: String) async throws -> [AIModelOption] { [] }
    static func run(_ request: CLICompletion.Request, tool: CLITool, toolPath: String, model: String?, workDir: URL,
                    onDelta: (@Sendable (String) -> Void)?, onActivity: (@Sendable (CLICompletion.Activity) -> Void)?)
        async throws -> CLICompletion.Result { fatalError("not used by the checks") }
}
final class SemanticDatabase {
    func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) {}
}
SWIFT
swiftc -o "$out/project-ai-choice-tests" MarkView/Models/AIAssistants.swift MarkView/Models/ProjectColor.swift \
    MarkView/Models/CLICompletion.swift "$out/Stub.swift" "$out/main.swift"
"$out/project-ai-choice-tests"
