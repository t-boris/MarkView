import Foundation

enum AIAssistantPreferences {
    static func backend(project: URL?) -> CLITool { .copilot }
    static func model(for tool: CLITool, project: URL?) -> String? { nil }
    static func xrayModel(for tool: CLITool, project: URL?) -> String? { nil }
    static func summary(tool: CLITool, model: String) -> String { "\(tool.displayName) · \(model.isEmpty ? "default model" : model)" }
}
enum CLIToolLocator {
    static func resolve(_ tool: CLITool) -> String? {
        // A check that needs the assistant's CLI to be missing sets this.
        if ProcessInfo.processInfo.environment["MARKVIEW_TEST_CLI_MISSING"] != nil { return nil }
        return ProcessInfo.processInfo.environment["MARKVIEW_COMPLETION_LIVE_COPILOT"]
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }
    static func override(for tool: CLITool) -> String? { nil }
    static func searchDirectories() -> [String] { [] }
    static func subprocessPath(toolPath: String?) -> String { ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin" }
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

// The suite names the assistants by their stored identity; the app names none outside its providers.
extension CLITool {
    static var claude: CLITool { CLITool(rawValue: "claude")! }
    static var codex: CLITool { CLITool(rawValue: "codex")! }
    static var copilot: CLITool { CLITool(rawValue: "copilot")! }
}
