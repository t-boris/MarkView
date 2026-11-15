import Foundation

/// Claude Code (`claude`).
struct ClaudeProvider: AssistantProvider {
    let id = "claude"
    let displayName = "Claude Code"
    let binaryName = "claude"
    let authStatusArgs = ["auth", "status"]
    let loginCommand = "auth login"
    let fullAccessArgs = ["--dangerously-skip-permissions"]
    let continueArgs = ["--continue"]
    let defaultXRayModel = "sonnet"

    func loginState(stdout: String, stderr: String) -> Bool? {
        // `claude auth status` emits JSON with a "loggedIn" boolean.
        if let data = stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let flag = json["loggedIn"] as? Bool {
            return flag
        }
        return (stdout + stderr).localizedCaseInsensitiveContains("logged in") ? true : nil
    }

    /// Claude `--add-dir`. Codex reads the whole disk in its read-only sandbox; Cline and Copilot have no such option.
    func additionalFolderArgs(_ folders: [URL]) -> [String] {
        folders.flatMap { ["--add-dir", $0.path] }
    }

    func modelOptions() -> [AIModelOption] {
        // Aliases resolve to the newest model of each family, so the list does not go stale when Claude Code ships a new version.
        [
            AIModelOption(id: "", name: "Default", detail: "Claude Code's configured model"),
            AIModelOption(id: "fable", name: "Fable", detail: "Latest Fable — most capable"),
            AIModelOption(id: "opus", name: "Opus", detail: "Latest Opus"),
            AIModelOption(id: "sonnet", name: "Sonnet", detail: "Latest Sonnet — balanced"),
            AIModelOption(id: "haiku", name: "Haiku", detail: "Latest Haiku — fastest"),
        ]
    }

    /// `~/.claude/settings.json` "model".
    func configuredModel() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = (object["model"] as? String)?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        return model
    }
}
