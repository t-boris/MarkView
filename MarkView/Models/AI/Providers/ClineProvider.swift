import Foundation

/// Cline 3.x (`cline`), driven over the Agent Client Protocol (`ACPAssistant`).
struct ClineProvider: AssistantProvider, AssistantACPSupport {
    let id = "cline"
    let displayName = "Cline"
    let binaryName = "cline"
    let authStatusArgs: [String] = []
    let loginCommand = "auth"
    let fullAccessArgs = ["--auto-approve", "true"]
    let continueArgs: [String] = []
    let modelFlag = "-m"
    let terminalIcon = "circle.hexagongrid"
    var activity: (any AssistantActivitySupport)? { ClineActivity() }

    func goalPrompt(_ objective: String, closing: String) -> String { "Goal for this Cline task: \(objective) \(closing)" }

    var acp: (any AssistantACPSupport)? { self }

    func modelOptions() -> [AIModelOption] {
        // The account's models, as Cline listed them at the last check (Settings, menus).
        [AIModelOption(id: "", name: "Default", detail: "Cline's configured model (cline auth)")] + ACPModelCache.cached(id)
    }

    func launchProfile(effort: String?) -> ACPLaunchProfile {
        var arguments = ["--acp"]
        if let effort { arguments += ["--thinking", effort] }
        return ACPLaunchProfile(arguments: arguments, readOnlyMode: "plan", noticePrefix: nil)
    }

    /// Cline's npm launcher exits quietly when macOS kills its binary for a broken signature, so an empty version means that.
    var probe: ACPProbeProfile {
        ACPProbeProfile(
            minimumMajorVersion: 3, installCommand: "npm i -g cline@latest",
            silentExitMessage: "Cline did not start — macOS stops it when its binary's signature is invalid "
                + "(a known problem of the npm package). Fix in Terminal: codesign --force --sign - "
                + "\"$(dirname $(readlink -f $(which cline)))/.cline\"",
            modelListImpliesSignedIn: false)
    }

    var killedMessage: String? {
        "macOS stopped Cline (its binary's signature is invalid — a known problem of the npm package). "
            + "Fix: codesign --force --sign - \"$(dirname $(readlink -f $(which cline)))/.cline\""
    }

    /// Cline has no per-session option: its own settings must list the servers (BUG-026), whenever a terminal starts.
    var mcp: AssistantMCPRegistration? {
        .jsonFile(.init(
            file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cline/data/settings/cline_mcp_settings.json"),
            entry: { executable, server in
                ["transport": ["type": "stdio", "command": executable, "args": [server.flag]] as [String: Any],
                 "disabled": false, "autoApprove": [String](), "timeout": 120]
            },
            isCurrent: { entry, executable in
                (entry["transport"] as? [String: Any])?["command"] as? String == executable && entry["disabled"] as? Bool != true
            },
            checkedAtStart: true))
    }
}

// MARK: - Activity

/// What Cline is doing: its live session in `~/.cline/data/db/sessions.db`, by process, else the newest of the folder.
struct ClineActivity: AssistantActivitySupport {
    func read(_ request: ActivityRequest) -> ActivityRead? {
        guard let session = AgentActivityLog.clineSession(directory: request.directory, shell: request.shell),
              let data = try? Data(contentsOf: session.messages) else { return nil }
        return ActivityRead(source: session.messages, size: data.count, date: Date(),
                            activity: AgentActivityParser.cline(messagesJSON: data, status: session.status))
    }
}
