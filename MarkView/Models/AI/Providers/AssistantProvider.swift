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

/// Capabilities of an assistant's actual MarkView launch profiles (REQ-006).
/// Declared per provider inside `Models/AI/Providers/` so callers ask the provider rather than switching on identity.
struct AgentLaunchCapabilities: Equatable, Sendable {
    /// Background one-shot CLI/ACP run can perform live web search when `allowWeb == true`.
    var backgroundWebSearch: Bool = false
    /// Background one-shot CLI/ACP run enforces `allowWeb == false` at the CLI/tool layer.
    var enforcesWebOptOutAtCLI: Bool = true
    /// Background one-shot run can inspect image attachments (`request.images`).
    var backgroundImages: Bool = false
    /// Background one-shot run supports structured JSON output.
    var backgroundStructuredOutput: Bool = true
    /// Background one-shot run reports `costUSD` directly.
    var backgroundReportsCostUSD: Bool = false
    /// Interactive/Cockpit session supports provider-native subagent/workflow delegation.
    var interactiveDelegation: Bool = false
    /// Hosted Remote Work is supported (`AssistantRemoteSupport`).
    var remoteWork: Bool = false
}

/// How an assistant runs the independent parts of one task at the same time inside one interactive session: subagents, workflows
/// or fleets of its own. They run under the session's launch profile, so they keep its permissions.
struct AssistantParallelWork: Equatable, Sendable {
    /// The mechanism as a noun phrase the agent is told ("subagents started with the Agent tool"): in a Cockpit step, to the planner,
    /// and in every request `ParallelWork` makes.
    let mechanism: String
    /// The mechanism for a list of independent items, when the assistant has a stronger one for it (Claude Code starts a dynamic
    /// workflow only when the prompt asks for one in words); nil = `mechanism`.
    var itemsMechanism: String? = nil
}

/// The shape of the work a prompt hands to an agent session, which decides how its assistant is asked to run the work in parallel.
/// Every prompt MarkView sends into an agent session names its shape, and the request is written for the terminal that receives it.
enum ParallelWork: Sendable {
    /// One task whose parts may be independent of each other (a feature, a bug, a failed CI run): the agent decides what to split.
    case parts
    /// A list of independent items of one kind (a batch of bugs, conflicted files, review findings, places to look into).
    case items

    /// `prompt` followed by the request to run its independent work in parallel, written for `tool`; `prompt` unchanged when the
    /// terminal runs no assistant or the assistant has no mechanism (Cline).
    func ask(_ prompt: String, tool: CLITool?) -> String {
        guard let request = tool.flatMap({ request(for: $0.provider) }) else { return prompt }
        return prompt + (prompt.contains("\n") ? "\n\n" : " ") + request
    }

    /// The request in the words of `provider`'s mechanism; nil when it has none.
    func request(for provider: any AssistantProvider) -> String? {
        guard let work = provider.parallelWork else { return nil }
        let rules = "Keep work that depends on other work in order, never give the same file to two of them, run every git command that "
            + "changes the repository (branch, commit, merge) yourself, and wait for each one and check its result before you report."
        switch self {
        case .parts:
            return "Where parts of this work are independent of each other, do them at the same time with \(work.mechanism) instead of one "
                + "after another. " + rules
        case .items:
            return "Work on the independent items at the same time with \(work.itemsMechanism ?? work.mechanism), one per item or per group "
                + "of items that touch the same files. " + rules
        }
    }
}

protocol AssistantProvider: Sendable {
    // MARK: Identity

    /// The persisted raw value of the assistant (`CLITool.rawValue`, a stored selection, a terminal profile, a settings key).
    /// It never changes for an existing assistant.
    var id: String { get }
    var displayName: String { get }
    /// The name on a narrow tab; the number and model after the display name are kept.
    var compactName: String { get }
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

    // MARK: Interactive terminal

    /// SF Symbol of the assistant's terminal tab.
    var terminalIcon: String { get }
    /// Arguments, right after the executable, of a command that updates the CLI; it runs (`&&`) before every start.
    var updateArgs: [String] { get }
    /// The CLI has a session of its own in `directory` that `continueArgs` can pick up. Assistants that start a new
    /// session by themselves when there is none answer true; Claude Code stops with "No conversation found".
    func hasSession(in directory: URL) -> Bool
    /// The model the CLI's own session log names for a reply since `since` in `directory`; nil for a CLI without a
    /// readable log.
    func answeredModel(in directory: URL, since: Date) -> String?
    /// What the running CLI is doing, read from its own session store; nil when none can be read.
    var activity: (any AssistantActivitySupport)? { get }
    /// The CLI prints a message when an organisation's policy blocks MarkView's MCP servers (BUG-025).
    var reportsMCPPolicyBlock: Bool { get }
    /// Switches the model of a running session by a command typed into it; nil when the CLI must start again.
    var liveModelSwitch: (any AssistantLiveModelSwitch)? { get }

    // MARK: MarkView's MCP servers

    /// Command-line arguments that hand MarkView's MCP servers to one terminal (shell-quoted with `quote`); nil when the
    /// CLI has no per-session option and the servers must be in its own settings before it starts (`mcp`).
    func mcpLaunchArguments(for servers: [AgentMCPServer], quote: (String) -> String) -> [String]?
    /// How the servers are registered in the CLI's own settings (Connect Agents…); nil when it cannot use MCP servers.
    var mcp: AssistantMCPRegistration? { get }
    /// How this assistant's own MCP configuration is discovered and updated (per-service enable/disable).
    var mcpConfig: (any AssistantMCPConfigAdapter)? { get }
    /// The skill file (relative to the home folder) that teaches the CLI MarkView's tools, for CLIs that may not use MCP.
    var skillPath: String? { get }

    // MARK: Prompts

    /// The CLI can search the web by itself (project operation discovery and research rely on it).
    var canSearchWeb: Bool { get }
    /// Capabilities of this assistant's actual MarkView launch profiles (REQ-006).
    var launchCapabilities: AgentLaunchCapabilities { get }
    /// Fix with AI and the bug basket state the work as the CLI's goal command (`goalPrompt`), so the CLI goes on until it is
    /// done, instead of a numbered request; false for a CLI that has no goal command.
    var fixesBugsAsGoal: Bool { get }
    /// `objective` as a goal for the CLI's own command or task model; `closing` asks it to continue until it is done, for
    /// CLIs that have no goal command.
    func goalPrompt(_ objective: String, closing: String) -> String

    // MARK: Parallel work

    /// How the CLI runs independent work at the same time inside one interactive terminal session (agent-aware-implementation-runs
    /// REQ-002, and every prompt sent into an agent session); nil when it has no such mechanism.
    var parallelWork: AssistantParallelWork? { get }

    // MARK: Usage

    /// Present when the assistant's quota and usage are tracked (the Terminal tab's indicators).
    var usage: (any AssistantUsageSupport)? { get }

    // MARK: One-shot runs

    /// Present when the assistant answers a one-shot request by running its CLI once (`CLICompletion`); nil for the
    /// assistants driven over ACP.
    var completion: (any AssistantCompletionSupport)? { get }

    // MARK: Remote Work

    /// Present when the home Mac can host this assistant for a work Mac.
    var remote: (any AssistantRemoteSupport)? { get }

    // MARK: Agent Client Protocol

    /// Present when the assistant is driven over the Agent Client Protocol rather than a one-shot CLI run.
    var acp: (any AssistantACPSupport)? { get }
}

extension AssistantProvider {
    /// The identity of this assistant for the rest of the app.
    var tool: CLITool { CLITool(self) }

    var compactName: String { displayName }
    var versionArgs: [String] { ["--version"] }
    var modelFlag: String { "--model" }
    var defaultXRayModel: String { "" }
    var acp: (any AssistantACPSupport)? { nil }
    var completion: (any AssistantCompletionSupport)? { nil }
    var remote: (any AssistantRemoteSupport)? { nil }
    var updateArgs: [String] { [] }
    func hasSession(in directory: URL) -> Bool { true }
    func answeredModel(in directory: URL, since: Date) -> String? { nil }
    var activity: (any AssistantActivitySupport)? { nil }
    var reportsMCPPolicyBlock: Bool { false }
    var liveModelSwitch: (any AssistantLiveModelSwitch)? { nil }
    func mcpLaunchArguments(for servers: [AgentMCPServer], quote: (String) -> String) -> [String]? { nil }
    var mcp: AssistantMCPRegistration? { nil }
    var mcpConfig: (any AssistantMCPConfigAdapter)? { nil }
    var skillPath: String? { nil }
    var canSearchWeb: Bool { false }
    var launchCapabilities: AgentLaunchCapabilities {
        AgentLaunchCapabilities(
            backgroundWebSearch: canSearchWeb,
            enforcesWebOptOutAtCLI: true,
            backgroundImages: false,
            backgroundStructuredOutput: true,
            backgroundReportsCostUSD: false,
            interactiveDelegation: parallelWork != nil,
            remoteWork: remote != nil
        )
    }
    var fixesBugsAsGoal: Bool { false }
    func goalPrompt(_ objective: String, closing: String) -> String { objective + " " + closing }
    var parallelWork: AssistantParallelWork? { nil }
    var usage: (any AssistantUsageSupport)? { nil }
    func loginState(stdout: String, stderr: String) -> Bool? { nil }
    func additionalFolderArgs(_ folders: [URL]) -> [String] { [] }
    func configuredModel() -> String? { nil }

    /// Driven over the Agent Client Protocol (`ACPAssistant`) rather than a one-shot CLI run.
    var usesACP: Bool { acp != nil }

    /// Arguments that select `model` for one run.
    func modelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return [modelFlag, model]
    }
}
