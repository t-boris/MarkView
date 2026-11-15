import Foundation

// One AI assistant CLI (Claude Code, Codex, Cline, Copilot, Antigravity, ...), described by ONE conforming type in this
// folder and ONE line in `AssistantProviders.list`. Everything that differs between assistants lives in its provider; the
// rest of the app asks the provider and never switches on which assistant it is (AR-35, `tools/lint/architecture-lint.sh`
// rule `assistant-switch`). Foundation only, so the suites that compile it need no app state.

/// A model the user can pick for a CLI. `id` is passed to the CLI's model flag;
/// an empty `id` means "no flag" — the CLI uses its own configured default.
struct AIModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
}

protocol AssistantProvider: Sendable {
    // MARK: Identity

    /// The persisted raw value of the assistant (`CLITool.rawValue`, a stored selection, a terminal profile, a settings key).
    /// It never changes for an existing assistant.
    var id: String { get }
    var displayName: String { get }
    /// Executable name as installed on disk.
    var binaryName: String { get }

    // MARK: Discovery and sign-in

    /// Arguments that print the version without touching the network.
    var versionArgs: [String] { get }
    /// Arguments that report login state without consuming tokens.
    var authStatusArgs: [String] { get }
    /// Command the user runs in Terminal to authenticate.
    var loginCommand: String { get }
    /// Signed in (true), signed out (false) or unknown (nil), from the output of `authStatusArgs`.
    func loginState(stdout: String, stderr: String) -> Bool?

    // MARK: Interactive terminal

    /// Arguments that let the interactive CLI in an AI terminal act without approval prompts:
    /// every assistant there always runs with full access (BUG-006).
    var fullAccessArgs: [String] { get }
    /// Arguments, right after the executable, that continue the most recent session in the working folder without a
    /// picker (BUG-005). Empty when the CLI has no such option: Cline resumes a session only by its id.
    var continueArgs: [String] { get }
    /// The flag that selects a model for one run (`--model`, `-m`).
    var modelFlag: String { get }
    /// Arguments that let the CLI read `folders` besides its working directory; empty when it has no such option.
    func additionalFolderArgs(_ folders: [URL]) -> [String]

    // MARK: Models

    /// The model X-Ray starts with ("" = the assistant's own model).
    var defaultXRayModel: String { get }
    /// Models offered in pickers. Some assistants read a catalogue from disk, so call this off the main thread.
    func modelOptions() -> [AIModelOption]
    /// The model the CLI runs when no flag is given, from its own configuration, or nil.
    func configuredModel() -> String?

    // MARK: Agent Client Protocol

    /// Present when the assistant is driven over the Agent Client Protocol rather than a one-shot CLI run.
    var acp: (any AssistantACPSupport)? { get }
}

extension AssistantProvider {
    /// The identity of this assistant for the rest of the app.
    var tool: CLITool { CLITool(rawValue: id)! }

    var versionArgs: [String] { ["--version"] }
    var modelFlag: String { "--model" }
    var defaultXRayModel: String { "" }
    var acp: (any AssistantACPSupport)? { nil }
    func loginState(stdout: String, stderr: String) -> Bool? { nil }
    func additionalFolderArgs(_ folders: [URL]) -> [String] { [] }
    func configuredModel() -> String? { nil }

    /// UserDefaults key holding the user's explicit path override ("" = auto-detect).
    var overrideKey: String { "settings.cli.\(id)Path" }
    /// Driven over the Agent Client Protocol (`ACPAssistant`) rather than a one-shot CLI run.
    var usesACP: Bool { acp != nil }

    /// Arguments that select `model` for one run.
    func modelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return [modelFlag, model]
    }
}
