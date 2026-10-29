import Foundation

enum CLITool: String {
    case claude, codex, antigravity, cline, copilot
    var usesACP: Bool { self == .copilot || self == .cline }
    var displayName: String { rawValue }
    var binaryName: String { rawValue }
    var loginCommand: String { "login" }
    func modelArgs(_ model: String?) -> [String] { [] }
    func additionalFolderArgs(_ folders: [URL]) -> [String] { [] }
}
enum AIAssistantPreferences {
    static func backend(project: URL?) -> CLITool { .copilot }
    static func model(for tool: CLITool, project: URL?) -> String? { nil }
    static func xrayModel(for tool: CLITool, project: URL?) -> String? { nil }
}
enum CLIToolLocator {
    static func resolve(_ tool: CLITool) -> String? {
        ProcessInfo.processInfo.environment["MARKVIEW_COMPLETION_LIVE_COPILOT"]
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }
    static func override(for tool: CLITool) -> String? { nil }
    static func searchDirectories() -> [String] { [] }
    static func subprocessPath(toolPath: String?) -> String { ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin" }
}
struct AIModelOption { let id: String; let name: String; let detail: String }
@MainActor final class SemanticDatabase {
    func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) {}
}
enum LinkedFolders {
    struct Folder { let url: URL }
    static func load(project: URL) -> [Folder] { [] }
}
enum AICallLog {
    struct Entry {
        let timestamp: Date, project: String, label: String, tool: String, model: String, effort: String
        let seconds: Double
        let inputTokens: Int, outputTokens: Int
        let costUSD: Double?
        let outcome: String
    }
    static func record(_ entry: Entry) {}
}
