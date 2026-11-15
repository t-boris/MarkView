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
}
