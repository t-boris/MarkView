import Foundation

/// Codex (`codex`).
struct CodexProvider: AssistantProvider {
    let id = "codex"
    let displayName = "Codex"
    let binaryName = "codex"
    let authStatusArgs = ["login", "status"]
    let loginCommand = "login"
    let fullAccessArgs = ["--dangerously-bypass-approvals-and-sandbox"]
    let continueArgs = ["resume", "--last"]
    let modelFlag = "-m"
    let defaultXRayModel = "gpt-5.6-luna"

    func loginState(stdout: String, stderr: String) -> Bool? {
        // `codex login status` prints e.g. "Logged in using ChatGPT".
        let output = stdout + stderr
        if output.localizedCaseInsensitiveContains("not logged in") { return false }
        if output.localizedCaseInsensitiveContains("logged in") { return true }
        return nil
    }

    func modelOptions() -> [AIModelOption] {
        let configured = configuredModel()
        let fallback = AIModelOption(
            id: "", name: configured.map { "Default (\($0))" } ?? "Default",
            detail: configured.map { "\($0) (from ~/.codex/config.toml)" } ?? "Codex's configured model"
        )
        return [fallback] + catalog()
    }

    /// Top-level `model = "..."` from Codex's config, used to label "Default".
    func configuredModel() -> String? {
        let url = Self.home.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }  // past the top-level table
            guard line.hasPrefix("model"),
                  let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Models Codex itself lists in its picker, from the cache the CLI maintains (~350 KB of JSON).
    private func catalog() -> [AIModelOption] {
        let url = Self.home.appendingPathComponent("models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model in
                guard let slug = model["slug"] as? String, !slug.isEmpty else { return nil }
                return AIModelOption(
                    id: slug,
                    name: model["display_name"] as? String ?? slug,
                    detail: model["description"] as? String ?? ""
                )
            }
    }
}
