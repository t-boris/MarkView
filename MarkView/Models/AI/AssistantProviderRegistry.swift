import Foundation


/// Unified protocol describing an AI assistant CLI or ACP backend (`AR-35`).
protocol AssistantProvider: Sendable {
    var tool: CLITool { get }
    var id: String { get }
    var displayName: String { get }
    var binaryName: String { get }
    var usesACP: Bool { get }
    var overrideKey: String { get }
    var versionArgs: [String] { get }
    var authStatusArgs: [String] { get }
    var loginCommand: String { get }
    var fullAccessArgs: [String] { get }
    var continueArgs: [String] { get }
    var defaultXRayModel: String { get }
    func modelArgs(_ model: String?) -> [String]
}

extension AssistantProvider {
    var id: String { tool.rawValue }
    var overrideKey: String { "settings.cli.\(tool.rawValue)Path" }
    var versionArgs: [String] { ["--version"] }
}

struct ClaudeAssistantProvider: AssistantProvider {
    let tool: CLITool = .claude
    let displayName = "Claude Code"
    let binaryName = "claude"
    let usesACP = false
    let authStatusArgs = ["auth", "status"]
    let loginCommand = "auth login"
    let fullAccessArgs = ["--dangerously-skip-permissions"]
    let continueArgs = ["--continue"]
    let defaultXRayModel = "sonnet"

    func modelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["--model", model]
    }
}

struct CodexAssistantProvider: AssistantProvider {
    let tool: CLITool = .codex
    let displayName = "Codex"
    let binaryName = "codex"
    let usesACP = false
    let authStatusArgs = ["login", "status"]
    let loginCommand = "login"
    let fullAccessArgs = ["--dangerously-bypass-approvals-and-sandbox"]
    let continueArgs = ["resume", "--last"]
    let defaultXRayModel = "gpt-5.6-luna"

    func modelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["-m", model]
    }
}

struct ClineAssistantProvider: AssistantProvider {
    let tool: CLITool = .cline
    let displayName = "Cline"
    let binaryName = "cline"
    let usesACP = true
    let authStatusArgs: [String] = []
    let loginCommand = "auth"
    let fullAccessArgs = ["--auto-approve", "true"]
    let continueArgs: [String] = []
    let defaultXRayModel = ""

    func modelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["-m", model]
    }
}

struct CopilotAssistantProvider: AssistantProvider {
    let tool: CLITool = .copilot
    let displayName = "Copilot"
    let binaryName = "copilot"
    let usesACP = true
    let authStatusArgs: [String] = []
    let loginCommand = "login"
    let fullAccessArgs = ["--allow-all"]
    let continueArgs = ["--continue"]
    let defaultXRayModel = ""

    func modelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["--model", model]
    }
}

struct AntigravityAssistantProvider: AssistantProvider {
    let tool: CLITool = .antigravity
    let displayName = "Antigravity"
    let binaryName = "agy"
    let usesACP = false
    let authStatusArgs: [String] = []
    let loginCommand = ""
    let fullAccessArgs = ["--dangerously-skip-permissions"]
    let continueArgs = ["--continue"]
    let defaultXRayModel = ""

    func modelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["--model", model]
    }
}

/// Central registry of all supported `AssistantProvider` backends (`AR-35`).
enum AssistantProviderRegistry {
    static let claude = ClaudeAssistantProvider()
    static let codex = CodexAssistantProvider()
    static let cline = ClineAssistantProvider()
    static let copilot = CopilotAssistantProvider()
    static let antigravity = AntigravityAssistantProvider()

    static let all: [any AssistantProvider] = [
        claude,
        codex,
        cline,
        copilot,
        antigravity,
    ]

    static func provider(for tool: CLITool) -> any AssistantProvider {
        switch tool {
        case .claude: return claude
        case .codex: return codex
        case .cline: return cline
        case .copilot: return copilot
        case .antigravity: return antigravity
        }
    }

    static func provider(id: String) -> (any AssistantProvider)? {
        guard let tool = CLITool(rawValue: id) else { return nil }
        return provider(for: tool)
    }
}
