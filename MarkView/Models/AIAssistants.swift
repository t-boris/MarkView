import Foundation
import AppKit

// MARK: - CLI Tool Discovery

/// Locates the Claude Code, Codex, Cline and GitHub Copilot command-line binaries.
///
/// These used to be hardcoded absolute paths, which broke silently whenever a tool
/// was installed somewhere else — an npm/nvm install of Codex lands in
/// `~/.nvm/versions/node/<version>/bin`, and that path changes on every Node
/// upgrade. Resolution is now: user override from Settings, then a candidate scan
/// (including every installed Node version), then a login-shell lookup.
enum CLITool: String, CaseIterable {
    case claude
    case codex
    /// Cline 3.x, driven over the Agent Client Protocol (`ACPAssistant`).
    case cline
    /// GitHub Copilot CLI 1.x, driven over the Agent Client Protocol (`ACPAssistant`).
    case copilot

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cline: return "Cline"
        case .copilot: return "Copilot"
        }
    }

    /// Driven over the Agent Client Protocol (`ACPAssistant`) rather than a one-shot CLI run.
    var usesACP: Bool { self == .cline || self == .copilot }

    /// Executable name as installed on disk.
    var binaryName: String { rawValue }

    /// UserDefaults key holding the user's explicit path override ("" = auto-detect).
    var overrideKey: String { "settings.cli.\(rawValue)Path" }

    /// Arguments that print the version without touching the network.
    var versionArgs: [String] { ["--version"] }

    /// Arguments that report login state without consuming tokens.
    var authStatusArgs: [String] {
        switch self {
        case .claude: return ["auth", "status"]
        case .codex: return ["login", "status"]
        // No status command that works without a terminal; see `probeACP`.
        case .cline, .copilot: return []
        }
    }

    /// Command the user runs in Terminal to authenticate.
    var loginCommand: String {
        switch self {
        case .claude: return "auth login"
        case .codex: return "login"
        case .cline: return "auth"
        case .copilot: return "login"
        }
    }

    /// Arguments that select `model` for one run.
    func modelArgs(_ model: String?) -> [String] {
        guard let model else { return [] }
        switch self {
        case .claude, .copilot: return ["--model", model]
        case .codex, .cline: return ["-m", model]
        }
    }
}

// MARK: - Assistant & Model Preferences

/// A model the user can pick for a CLI. `id` is passed to the CLI's model flag;
/// an empty `id` means "no flag" — the CLI uses its own configured default.
struct AIModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
}

/// Which CLI answers AI Console requests and which model it runs.
///
/// Stored in UserDefaults so DDE Settings and the console's quick switch edit the
/// same values; views bind to the keys with `@AppStorage`, and the engine reads
/// them at send time.
enum AIAssistantPreferences {
    static let backendKey = "settings.ai.backend"

    static func modelKey(for tool: CLITool) -> String { "settings.cli.\(tool.rawValue)Model" }

    static var backend: CLITool {
        CLITool(rawValue: UserDefaults.standard.string(forKey: backendKey) ?? "") ?? .claude
    }

    /// The selected model, or nil to let the CLI use its own default.
    static func model(for tool: CLITool) -> String? {
        let value = (UserDefaults.standard.string(forKey: modelKey(for: tool)) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    // MARK: X-Ray

    /// X-Ray has its own model: its answers are large and structured, so a fast model
    /// at low effort matters more there than raw capability.
    static func xrayModelKey(for tool: CLITool) -> String { "settings.xray.\(tool.rawValue)Model" }
    static func defaultXRayModel(for tool: CLITool) -> String {
        switch tool {
        case .claude: return "sonnet"
        case .codex: return "gpt-5.6-luna"
        case .cline, .copilot: return ""
        }
    }
    /// The X-Ray model for `tool`; "" means the assistant's general model.
    static func xrayModel(for tool: CLITool) -> String? {
        let value = UserDefaults.standard.string(forKey: xrayModelKey(for: tool)) ?? defaultXRayModel(for: tool)
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? model(for: tool) : trimmed
    }

    /// Short label for the active selection, e.g. "Claude Code · opus".
    static func summary(tool: CLITool, model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return "\(tool.displayName) · \(trimmed.isEmpty ? "default model" : trimmed)"
    }

    /// Models offered in pickers. Codex reads its own catalog from disk (~350 KB of
    /// JSON), so call this off the main thread.
    static func modelOptions(for tool: CLITool) -> [AIModelOption] {
        switch tool {
        case .claude:
            // Aliases resolve to the newest model of each family, so the list does
            // not go stale when Claude Code ships a new version.
            return [
                AIModelOption(id: "", name: "Default", detail: "Claude Code's configured model"),
                AIModelOption(id: "fable", name: "Fable", detail: "Latest Fable — most capable"),
                AIModelOption(id: "opus", name: "Opus", detail: "Latest Opus"),
                AIModelOption(id: "sonnet", name: "Sonnet", detail: "Latest Sonnet — balanced"),
                AIModelOption(id: "haiku", name: "Haiku", detail: "Latest Haiku — fastest"),
            ]
        case .codex:
            let configured = codexConfiguredModel()
            let fallback = AIModelOption(
                id: "", name: configured.map { "Default (\($0))" } ?? "Default",
                detail: configured.map { "\($0) (from ~/.codex/config.toml)" } ?? "Codex's configured model"
            )
            return [fallback] + codexCatalog()
        case .cline:
            // The account's models, as Cline listed them at the last check (Settings, menus).
            return [AIModelOption(id: "", name: "Default", detail: "Cline's configured model (cline auth)")]
                + ACPAssistant.cachedModels(.cline)
        case .copilot:
            return [AIModelOption(id: "", name: "Default", detail: "Copilot's configured model")]
                + ACPAssistant.cachedModels(.copilot)
        }
    }

    private static var codexHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Models Codex itself lists in its picker, from the cache the CLI maintains.
    private static func codexCatalog() -> [AIModelOption] {
        let url = codexHome.appendingPathComponent("models_cache.json")
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

    /// Top-level `model = "..."` from Codex's config, used to label "Default".
    private static func codexConfiguredModel() -> String? {
        let url = codexHome.appendingPathComponent("config.toml")
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
}

enum CLIToolLocator {

    /// Extra `PATH` entries the user configured in Settings (colon- or newline-separated).
    static var extraPathEntries: [String] {
        (UserDefaults.standard.string(forKey: "settings.cli.extraPATH") ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ":\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The user's explicit override, or nil when set to auto-detect.
    static func override(for tool: CLITool) -> String? {
        let value = (UserDefaults.standard.string(forKey: tool.overrideKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func setOverride(_ path: String?, for tool: CLITool) {
        let value = (path ?? "").trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(value, forKey: tool.overrideKey)
    }

    /// Every `bin` directory belonging to an installed Node version, newest first.
    /// This is the directory an `npm install -g codex` actually writes to, and the
    /// one the previous hardcoded `/opt/homebrew/bin` path could never find.
    static func nodeBinDirectories() -> [String] {
        let fm = FileManager.default
        let versionsRoot = NSHomeDirectory() + "/.nvm/versions/node"
        guard let versions = try? fm.contentsOfDirectory(atPath: versionsRoot) else { return [] }
        return versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(versionsRoot)/\($0)/bin" }
    }

    /// Directories searched when no override is set, in priority order.
    static func searchDirectories() -> [String] {
        let home = NSHomeDirectory()
        return extraPathEntries
            + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
               "\(home)/.claude/local", "\(home)/bin", "/usr/bin"]
            + nodeBinDirectories()
    }

    /// Resolve a tool to an executable path, or nil if it cannot be found.
    /// Pure filesystem work — safe to call from the main actor.
    static func resolve(_ tool: CLITool) -> String? {
        if let override = override(for: tool) {
            // An override that no longer exists is reported as "not found" so the
            // user sees the problem instead of a cryptic launch failure.
            return isExecutable(override) ? override : nil
        }
        for directory in searchDirectories() {
            let candidate = "\(directory)/\(tool.binaryName)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Last-resort lookup through a login shell, which picks up PATH entries set by
    /// nvm/rbenv/etc. in the user's dotfiles. Off-main and time-bounded.
    static func resolveViaLoginShell(_ tool: CLITool) async -> String? {
        let result = await run("/bin/zsh", ["-lc", "command -v \(tool.binaryName)"], timeout: 10)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, isExecutable(path) else { return nil }
        return path
    }

    /// Resolve, falling back to the login shell when the candidate scan comes up empty.
    static func resolveThorough(_ tool: CLITool) async -> String? {
        if let path = resolve(tool) { return path }
        if override(for: tool) != nil { return nil }  // explicit override, don't second-guess it
        return await resolveViaLoginShell(tool)
    }

    static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return fm.isExecutableFile(atPath: path)
    }

    /// `PATH` handed to spawned CLIs. Includes the tool's own directory and every
    /// Node bin dir, so a node-based CLI can find its own runtime.
    static func subprocessPath(toolPath: String?) -> String {
        let home = NSHomeDirectory()
        var entries: [String] = []
        if let toolPath { entries.append((toolPath as NSString).deletingLastPathComponent) }
        entries += extraPathEntries
        entries += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                    "/usr/sbin", "/sbin", "\(home)/.local/bin"]
        entries += nodeBinDirectories()
        // Preserve order, drop duplicates.
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    // MARK: - Probing

    struct ProbeResult {
        var path: String?
        var version: String?
        var loggedIn: Bool?
        var error: String?
    }

    /// Check that a tool is present, runnable, and authenticated.
    /// Uses each CLI's own status command — no tokens are spent.
    static func probe(_ tool: CLITool) async -> ProbeResult {
        guard let path = await resolveThorough(tool) else {
            let searched = searchDirectories().prefix(4).joined(separator: ", ")
            if let override = override(for: tool) {
                return ProbeResult(error: "Path set in Settings does not exist or is not executable: \(override)")
            }
            return ProbeResult(error: "\(tool.binaryName) not found. Searched \(searched), … — set the path manually in Settings.")
        }

        let versionRun = await run(path, tool.versionArgs, timeout: 20)
        if tool.usesACP {
            return await probeACP(tool, path: path, versionRun: versionRun)
        }
        guard versionRun.exitCode == 0 else {
            let detail = (versionRun.stderr.isEmpty ? versionRun.stdout : versionRun.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ProbeResult(path: path, error: "Could not run \(path): \(detail.prefix(200))")
        }
        let version = versionRun.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let authRun = await run(path, tool.authStatusArgs, timeout: 30)
        let authOutput = authRun.stdout + authRun.stderr
        let loggedIn: Bool?
        switch tool {
        case .claude:
            // `claude auth status` emits JSON with a "loggedIn" boolean.
            if let data = authRun.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let flag = json["loggedIn"] as? Bool {
                loggedIn = flag
            } else {
                loggedIn = authOutput.localizedCaseInsensitiveContains("logged in") ? true : nil
            }
        case .cline, .copilot:
            loggedIn = nil
        case .codex:
            // `codex login status` prints e.g. "Logged in using ChatGPT".
            if authOutput.localizedCaseInsensitiveContains("not logged in") {
                loggedIn = false
            } else if authOutput.localizedCaseInsensitiveContains("logged in") {
                loggedIn = true
            } else {
                loggedIn = nil
            }
        }
        return ProbeResult(path: path, version: version, loggedIn: loggedIn)
    }

    /// Cline and Copilot: the version, then a session over ACP (no prompt, no tokens) that
    /// lists the account's models and refreshes the model menus. Cline's npm launcher exits quietly when macOS kills its
    /// binary for a broken signature, so an empty version means that.
    private static func probeACP(_ tool: CLITool, path: String, versionRun: RunResult) async -> ProbeResult {
        // "3.0.65" (Cline), "GitHub Copilot CLI 1.0.88." (Copilot).
        let firstLine = versionRun.stdout.split(separator: "\n").first.map(String.init) ?? ""
        let version = firstLine.range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map { String(firstLine[$0]) } ?? ""
        guard versionRun.exitCode == 0, !version.isEmpty else {
            let detail = (versionRun.stderr + versionRun.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty && tool == .cline {
                return ProbeResult(path: path, error: "Cline did not start — macOS stops it when its binary's signature is invalid "
                    + "(a known problem of the npm package). Fix in Terminal: codesign --force --sign - "
                    + "\"$(dirname $(readlink -f $(which cline)))/.cline\"")
            }
            return ProbeResult(path: path, error: "Could not run \(path): \(detail.prefix(200))")
        }
        let (minimum, install) = tool == .cline ? (3, "npm i -g cline@latest") : (1, "npm i -g @github/copilot@latest")
        guard (Int(version.prefix(while: \.isNumber)) ?? 0) >= minimum else {
            return ProbeResult(path: path, version: version,
                               error: "\(tool.displayName) \(version) is too old for MarkView — update: \(install)")
        }
        do {
            let models = try await ACPAssistant.refreshModels(tool, toolPath: path)
            // Copilot lists models per account (so a list means signed in); Cline lists them signed out too.
            return ProbeResult(path: path, version: "\(version) · \(models.count) models",
                               loggedIn: tool == .copilot && !models.isEmpty ? true : nil)
        } catch {
            let message = error.localizedDescription
            let signedOut = message.localizedCaseInsensitiveContains("auth") || message.localizedCaseInsensitiveContains("login")
            return ProbeResult(path: path, version: version, loggedIn: signedOut ? false : nil,
                               error: signedOut ? nil : "\(tool.displayName) started but its session failed: \(message)")
        }
    }

    // MARK: - Process helper

    struct RunResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    /// Run a command off the main thread, draining both pipes concurrently with the
    /// wait so a full pipe can never deadlock the app (CLAUDE.md process rule), and
    /// terminating it if it outlives `timeout`.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> RunResult {
        let path = subprocessPath(toolPath: executable)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = path
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: RunResult(exitCode: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }

                // Read both pipes on their own queues so neither can fill and block.
                var outData = Data()
                var errData = Data()
                let lock = NSLock()
                let group = DispatchGroup()
                for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        lock.lock()
                        if isStdout { outData = data } else { errData = data }
                        lock.unlock()
                        group.leave()
                    }
                }

                // Poll instead of blocking forever, so a hung CLI is terminated
                // rather than pinning this worker. We are already off the main
                // thread and both pipes are draining on their own queues.
                let deadline = Date().addingTimeInterval(timeout)
                var timedOut = false
                while process.isRunning {
                    if Date() > deadline {
                        process.terminate()
                        timedOut = true
                        break
                    }
                    usleep(50_000)
                }
                process.waitUntilExit()
                _ = group.wait(timeout: .now() + 5)

                lock.lock()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                lock.unlock()

                continuation.resume(returning: RunResult(
                    exitCode: timedOut ? -2 : process.terminationStatus,
                    stdout: out,
                    stderr: timedOut ? "Timed out after \(Int(timeout))s. \(err)" : err
                ))
            }
        }
    }

    // MARK: - Terminal login

    /// Write an executable `.command` file and open it, which macOS runs in
    /// Terminal.app. Deliberately avoids NSAppleScript: driving Terminal through
    /// Apple Events would require an automation permission prompt and an
    /// NSAppleEventsUsageDescription entry.
    @discardableResult
    static func openLoginInTerminal(_ tool: CLITool) -> String? {
        guard let toolPath = resolve(tool) else {
            return "\(tool.binaryName) not found — set its path in Settings first."
        }
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MarkView", isDirectory: true)
        let script = directory.appendingPathComponent("login-\(tool.rawValue).command")
        let body = """
            #!/bin/zsh
            export PATH="\(subprocessPath(toolPath: toolPath))"
            echo "Signing in to \(tool.displayName)…"
            "\(toolPath)" \(tool.loginCommand)
            echo
            echo "Done. You can close this window."

            """
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return "Could not prepare the login script: \(error.localizedDescription)"
        }
        NSWorkspace.shared.open(script)
        return nil
    }
}
