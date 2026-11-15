import Foundation

/// The identity of an assistant CLI. Everything an assistant does differently lives in its `AssistantProvider`
/// (`provider`); this type is the key stored selections, terminal profiles and settings are made of.
enum CLITool: String, CaseIterable {
    case claude
    case codex
    /// Cline 3.x, driven over the Agent Client Protocol (`ACPAssistant`).
    case cline
    /// GitHub Copilot CLI 1.x, driven over the Agent Client Protocol (`ACPAssistant`).
    case copilot
    /// Google Antigravity CLI (`agy`), the successor of Gemini CLI. Terminals use its interactive mode, one-shot
    /// requests its print mode with stream-json (`CLICompletion`).
    case antigravity

    var displayName: String { provider.displayName }

    /// Provider descriptor from `AssistantProviderRegistry` (`AR-35`).
    var provider: any AssistantProvider { AssistantProviderRegistry.provider(for: self) }

    /// Driven over the Agent Client Protocol (`ACPAssistant`) rather than a one-shot CLI run.
    var usesACP: Bool { provider.usesACP }

    /// Executable name as installed on disk.
    var binaryName: String { provider.binaryName }

    /// UserDefaults key holding the user's explicit path override ("" = auto-detect).
    var overrideKey: String { provider.overrideKey }

    /// Arguments that print the version without touching the network.
    var versionArgs: [String] { provider.versionArgs }

    /// Arguments that report login state without consuming tokens.
    var authStatusArgs: [String] { provider.authStatusArgs }

    /// Command the user runs in Terminal to authenticate.
    var loginCommand: String { provider.loginCommand }

    /// Arguments that let the interactive CLI in an AI terminal act without approval prompts:
    /// every assistant there always runs with full access (BUG-006).
    var fullAccessArgs: [String] { provider.fullAccessArgs }

    /// Arguments, right after the executable, that continue the most recent session in the
    /// working folder without a picker (BUG-005). Empty when the CLI has no such option:
    /// Cline resumes a session only by its id.
    var continueArgs: [String] { provider.continueArgs }

    /// Arguments that select `model` for one run.
    func modelArgs(_ model: String?) -> [String] { provider.modelArgs(model) }

    /// Arguments that let the CLI read `folders` besides its working directory (Claude `--add-dir`); empty for the others.
    func additionalFolderArgs(_ folders: [URL]) -> [String] { provider.additionalFolderArgs(folders) }
}
