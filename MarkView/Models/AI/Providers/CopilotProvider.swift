import Foundation

/// GitHub Copilot CLI 1.x (`copilot`), driven over the Agent Client Protocol (`ACPAssistant`).
struct CopilotProvider: AssistantProvider, AssistantACPSupport {
    let id = "copilot"
    let displayName = "Copilot"
    let binaryName = "copilot"
    let authStatusArgs: [String] = []
    let loginCommand = "login"
    let fullAccessArgs = ["--allow-all"]
    let continueArgs = ["--continue"]

    var acp: (any AssistantACPSupport)? { self }

    func modelOptions() -> [AIModelOption] {
        [AIModelOption(id: "", name: "Default", detail: "Copilot's configured model")] + ACPModelCache.cached(id)
    }

    func launchProfile(effort: String?) -> ACPLaunchProfile {
        // Only these tools exist for the model: no shell, no edits, no web, no subagents.
        var arguments = ["--acp", "--no-auto-update", "--no-ask-user", "--disable-builtin-mcps",
                         "--no-custom-instructions"]
        if let effort { arguments += ["--reasoning-effort", effort] }
        arguments += ["--available-tools", "view", "grep", "glob"]
        return ACPLaunchProfile(arguments: arguments, readOnlyMode: nil, noticePrefix: "Info: Disabled tools:")
    }

    /// Copilot lists models per account, so a list means signed in.
    var probe: ACPProbeProfile {
        ACPProbeProfile(minimumMajorVersion: 1, installCommand: "npm i -g @github/copilot@latest",
                        silentExitMessage: nil, modelListImpliesSignedIn: true)
    }
}
