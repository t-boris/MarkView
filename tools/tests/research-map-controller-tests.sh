#!/bin/bash
# The research maps of a window (AR-14 step 3): the shipping ResearchMapController, ResearchJobs and ResearchMap over real map files and
# real folders, with a stand-in window that holds the tabs and a task bag. No assistant is started and nothing is shown. The assistant,
# the feature store's date and the repository listing are compile-time stand-ins for code these checks never reach.
#   tools/tests/research-map-controller-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ResearchMapControllerTests.swift "$out/main.swift"
cat > "$out/Stub.swift" <<'SWIFT'
import Foundation
enum FeatureStore { static var today: String { "2026-01-01" } }
extension ArchitectureScanner { static func listFiles(root: URL) -> [String] { [] } }
enum ACPAssistant {
    static func cachedModels(_ tool: CLITool) -> [AIModelOption] { [] }
    static func refreshModels(_ tool: CLITool, toolPath: String) async throws -> [AIModelOption] { [] }
    static func run(_ request: CLICompletion.Request, tool: CLITool, toolPath: String, model: String?, workDir: URL,
                    onDelta: (@Sendable (String) -> Void)?, onActivity: (@Sendable (CLICompletion.Activity) -> Void)?)
        async throws -> CLICompletion.Result { fatalError("not used by the checks") }
}
SWIFT
swiftc -o "$out/research-map-controller-tests" -target "$(uname -m)-apple-macos13.0" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Research/*.swift \
    MarkView/Models/Insight/SemanticDatabase.swift MarkView/Models/Insight/SemanticSchema.swift MarkView/Models/Insight/SemanticModels.swift \
    MarkView/Models/Workspace/TaskBag.swift MarkView/Models/Workspace/FrontMatter.swift MarkView/Models/Workspace/LinkedFolders.swift \
    MarkView/Models/Appearance/ProjectColor.swift \
    MarkView/Models/AI/AIAssistants.swift MarkView/Models/AI/CLICompletion.swift MarkView/Models/AI/AssistantProviderRegistry.swift \
    MarkView/Models/AI/AICallLog.swift MarkView/Models/AI/AgentProcesses.swift MarkView/Models/AI/AIOperation.swift \
    MarkView/Models/AI/OutputLanguage.swift MarkView/Models/AI/DiagramAI.swift \
    MarkView/Models/Architecture/ArchitectureModel.swift MarkView/Models/Architecture/CodeArchitecture.swift \
    MarkView/Models/Architecture/CodePathTags.swift MarkView/Models/Architecture/AutoAnalysisScheduler.swift \
    tools/tests/ProjectOperationAnyCodableStub.swift tools/tests/SemanticDatabaseTestSupport.swift "$out/Stub.swift" "$out/main.swift"
"$out/research-map-controller-tests"
