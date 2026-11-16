#!/bin/bash
# Recursive Insight of a window (AR-14 step 2): the shipping InsightCoordinator, InsightArchiveExport, InsightSession and
# InsightCache over real folders and a cache restored from a snapshot, with a stand-in window and page. The vendored libraries the
# cache copies from the bundle are the real ones, put next to the executable (a command-line tool's Bundle.main is its folder).
# Assistant, ACP, Whisper and bridge types the checks never reach are compile-time stand-ins. No window, panel or alert is shown.
#   tools/tests/insight-coordinator-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/InsightCoordinatorTests.swift "$out/main.swift"
cat > "$out/Stub.swift" <<'SWIFT'
import Foundation
enum WhisperClient { static func loadAPIKey() -> String? { nil }; static func saveAPIKey(_ key: String) {} }
enum WebViewBridge { static func logInsightDiag(_ message: String) {} }
enum ACPAssistant {
    static func cachedModels(_ tool: CLITool) -> [AIModelOption] { [] }
    static func refreshModels(_ tool: CLITool, toolPath: String) async throws -> [AIModelOption] { [] }
    static func run(_ request: CLICompletion.Request, tool: CLITool, toolPath: String, model: String?, workDir: URL,
                    onDelta: (@Sendable (String) -> Void)?, onActivity: (@Sendable (CLICompletion.Activity) -> Void)?)
        async throws -> CLICompletion.Result { fatalError("not used by the checks") }
}
SWIFT
mkdir -p "$out/Editor"
ln -s "$PWD/MarkView/Resources/Editor/vendor" "$out/Editor/vendor"
swiftc -o "$out/insight-coordinator-tests" -target "$(uname -m)-apple-macos13.0" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Insight/InsightCoordinator.swift MarkView/Models/Workspace/ProjectProviding.swift MarkView/Models/Insight/InsightArchiveExport.swift \
    MarkView/Models/Insight/InsightArchiveExporter.swift MarkView/Models/Insight/InsightCache.swift \
    MarkView/Models/Insight/InsightModels.swift MarkView/Models/Insight/InsightSession.swift MarkView/Models/Insight/InsightHTMLTemplate.swift MarkView/Models/Insight/InsightTreeSnapshot.swift \
    MarkView/Models/Insight/GraphRAG.swift MarkView/Models/Insight/EmbeddingClient.swift \
    MarkView/Models/Insight/SemanticDatabase.swift MarkView/Models/Insight/SemanticUsage.swift MarkView/Models/Insight/SemanticSchema.swift MarkView/Models/Insight/SemanticModels.swift \
    MarkView/Models/Workspace/LinkedFolders.swift MarkView/Models/AI/LinkedFolderStore.swift MarkView/Models/Appearance/ProjectColor.swift \
    MarkView/Models/AI/AIAssistants.swift MarkView/Models/AI/CLICompletion.swift MarkView/Models/AI/Providers/*.swift \
    MarkView/Models/AI/AICallLog.swift MarkView/Models/AI/AgentProcesses.swift MarkView/Models/AI/AIOperation.swift \
    MarkView/Models/AI/OutputLanguage.swift MarkView/Models/AI/DiagramAI.swift \
    MarkView/Models/Architecture/ArchitectureModel.swift MarkView/Models/Architecture/CodeArchitecture.swift \
    MarkView/Models/Architecture/CodePathTags.swift MarkView/Models/Architecture/AutoAnalysisScheduler.swift \
    tools/tests/ProjectOperationAnyCodableStub.swift tools/tests/SemanticDatabaseTestSupport.swift "$out/Stub.swift" "$out/main.swift"
"$out/insight-coordinator-tests"
