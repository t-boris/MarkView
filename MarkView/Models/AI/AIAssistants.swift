import Foundation
import AppKit
#if canImport(MarkViewCore)
import MarkViewCore
#endif

// MARK: - Assistant & Model Preferences

/// One project's own assistant choice (BUG-021). A missing value means the default; models are
/// keyed by tool, so switching assistants keeps each one's model. Stored in local settings under
/// the project's key (`ProjectColor.projectKey`), never in the project folder.
struct ProjectAIChoice: Codable, Equatable {
    static let defaultsKey = "project.ai"
    /// Posted when a project's choice changes; `object` is the project key.
    static let didChange = Notification.Name("ProjectAIChoiceDidChange")

    var backend: String?
    var models: [String: String] = [:]
    var xrayModels: [String: String] = [:]

    static func key(_ project: URL) -> String { ProjectColor.projectKey(for: project) }

    static func load(_ project: URL?) -> ProjectAIChoice? {
        guard let project,
              let data = UserDefaults.standard.dictionary(forKey: defaultsKey)?[key(project)] as? Data else { return nil }
        return try? JSONDecoder().decode(ProjectAIChoice.self, from: data)
    }

    /// Applies `change` to `project`'s choice (starting from none) and tells every window.
    static func update(_ project: URL, _ change: (inout ProjectAIChoice) -> Void) {
        var choice = load(project) ?? ProjectAIChoice()
        change(&choice)
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        all[key(project)] = try? JSONEncoder().encode(choice)
        UserDefaults.standard.set(all, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChange, object: key(project))
    }
}

/// When the user last picked a model for an assistant in MarkView, per project and for the defaults.
/// A running assistant is restarted for a pick made after it started, never for a model remembered
/// from a session (BUG-048). In memory only: after a relaunch every assistant starts with the stored
/// model.
enum ModelPickLog {
    private static var picks: [String: Date] = [:]

    private static func key(_ tool: CLITool, _ project: URL?) -> String {
        tool.rawValue + "|" + (project.map(ProjectAIChoice.key) ?? "default")
    }

    static func record(tool: CLITool, project: URL?, at date: Date = Date()) {
        picks[key(tool, project)] = date
    }

    /// The latest pick that decides `project`'s model: its own, or the defaults'.
    static func lastPick(tool: CLITool, project: URL?) -> Date? {
        [picks[key(tool, project)], picks[key(tool, nil)]].compactMap { $0 }.max()
    }
}

/// A window's view of the assistant choice for the menus: its project's own values when it shows a
/// project, else the defaults (a single file). Stored strings: "" = the CLI default model, or for
/// X-Ray, the assistant's model.
struct AssistantChoice {
    let project: URL?

    var tool: CLITool { AIAssistantPreferences.backend(project: project) }

    func setTool(_ raw: String) {
        if let project { ProjectAIChoice.update(project) { $0.backend = raw } }
        else { UserDefaults.standard.set(raw, forKey: AIAssistantPreferences.backendKey) }
    }

    func model(for tool: CLITool) -> String {
        ProjectAIChoice.load(project)?.models[tool.rawValue] ?? AIAssistantPreferences.defaultModelSetting(for: tool)
    }

    /// The user picked `id` in MarkView (toolbar menu or DDE Settings).
    func setModel(_ id: String, for tool: CLITool) {
        ModelPickLog.record(tool: tool, project: project)
        if let project { ProjectAIChoice.update(project) { $0.models[tool.rawValue] = id } }
        else { UserDefaults.standard.set(id, forKey: AIAssistantPreferences.modelKey(for: tool)) }
    }

    func xrayModel(for tool: CLITool) -> String {
        ProjectAIChoice.load(project)?.xrayModels[tool.rawValue] ?? AIAssistantPreferences.defaultXRayModelSetting(for: tool)
    }

    func setXRayModel(_ id: String, for tool: CLITool) {
        if let project { ProjectAIChoice.update(project) { $0.xrayModels[tool.rawValue] = id } }
        else { UserDefaults.standard.set(id, forKey: AIAssistantPreferences.xrayModelKey(for: tool)) }
    }
}

/// Which CLI answers AI requests, which model it runs, and which model X-Ray uses.
///
/// Each project has its own choice (BUG-021), set from its windows' toolbar menus and kept in
/// `ProjectAIChoice`; what a project has not chosen comes from the defaults, which DDE Settings
/// edits under the keys below. Every read names its project, so no window changes another.
enum AIAssistantPreferences {
    static let backendKey = "settings.ai.backend"

    static func modelKey(for tool: CLITool) -> String { "settings.cli.\(tool.rawValue)Model" }

    /// The default assistant, for projects without a choice of their own.
    static var defaultBackend: CLITool {
        CLITool(rawValue: UserDefaults.standard.string(forKey: backendKey) ?? "") ?? AssistantProviderRegistry.defaultTool
    }

    /// The assistant for `project`: its own choice, else the default.
    static func backend(project: URL?) -> CLITool {
        ProjectAIChoice.load(project)?.backend.flatMap(CLITool.init(rawValue:)) ?? defaultBackend
    }

    /// The default model for `tool` as stored ("" = the CLI's own default).
    static func defaultModelSetting(for tool: CLITool) -> String {
        UserDefaults.standard.string(forKey: modelKey(for: tool)) ?? ""
    }

    /// Compact state fingerprint for assistant/model/xray settings in `project`, used by observers
    /// so unrelated `UserDefaults` writes (such as divider drags) do not trigger view refreshes (`AR-18`).
    static func snapshot(project: URL?) -> String {
        let tool = backend(project: project)
        let choice = AssistantChoice(project: project)
        return "\(tool.rawValue)|\(choice.model(for: tool))|\(choice.xrayModel(for: tool))"
    }

    /// A model a running assistant reported (the user switched inside its session, BUG-048): the next
    /// start in `project` uses it. Only that project: a switch in one window must not change what another
    /// project shows or starts with, so the default moves only when no project is open. Not a pick in
    /// MarkView, so it restarts nothing (`ModelPickLog`).
    static func remember(_ model: String, for tool: CLITool, project: URL?) {
        if let project { ProjectAIChoice.update(project) { $0.models[tool.rawValue] = model } }
        else { UserDefaults.standard.set(model, forKey: modelKey(for: tool)) }
    }

    /// The model `tool` runs for `project`, or nil to let the CLI use its own default.
    static func model(for tool: CLITool, project: URL?) -> String? {
        let value = (ProjectAIChoice.load(project)?.models[tool.rawValue] ?? defaultModelSetting(for: tool))
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    // MARK: X-Ray

    /// X-Ray has its own model: its answers are large and structured, so a fast model
    /// at low effort matters more there than raw capability.
    static func xrayModelKey(for tool: CLITool) -> String { "settings.xray.\(tool.rawValue)Model" }
    static func defaultXRayModel(for tool: CLITool) -> String { tool.provider.defaultXRayModel }
    /// The default X-Ray model for `tool` as stored ("" = the assistant's model).
    static func defaultXRayModelSetting(for tool: CLITool) -> String {
        UserDefaults.standard.string(forKey: xrayModelKey(for: tool)) ?? defaultXRayModel(for: tool)
    }

    /// The X-Ray model `tool` runs for `project`; "" falls back to the assistant's model.
    static func xrayModel(for tool: CLITool, project: URL?) -> String? {
        let value = ProjectAIChoice.load(project)?.xrayModels[tool.rawValue] ?? defaultXRayModelSetting(for: tool)
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? model(for: tool, project: project) : trimmed
    }

    /// Automatic code analysis of code projects, on unless turned off (DEC-001 of
    /// automatic-code-architecture). Off: only the local layers, no CLI agent is started.
    static let autoAnalyzeKey = "xray.autoAnalyze"
    static var autoAnalyze: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: autoAnalyzeKey) == nil ? true : defaults.bool(forKey: autoAnalyzeKey)
    }

    /// Short label for the active selection, e.g. "Claude Code · opus".
    static func summary(tool: CLITool, model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return "\(tool.displayName) · \(trimmed.isEmpty ? "default model" : trimmed)"
    }

    /// Models offered in pickers. Codex reads its own catalog from disk (~350 KB of
    /// JSON), so call this off the main thread.
    static func modelOptions(for tool: CLITool) -> [AIModelOption] { tool.provider.modelOptions() }

    /// The model the CLI runs when no flag is given, from its own configuration (Claude Code:
    /// `~/.claude/settings.json` "model", Codex: `~/.codex/config.toml`), or nil.
    static func configuredModel(for tool: CLITool) -> String? { tool.provider.configuredModel() }
}

// MARK: - CLI Tool Discovery

/// Locates the assistants' command-line binaries.
///
/// These used to be hardcoded absolute paths, which broke silently whenever a tool
/// was installed somewhere else — an npm/nvm install of Codex lands in
/// `~/.nvm/versions/node/<version>/bin`, and that path changes on every Node
/// upgrade. Resolution is now: user override from Settings, then a candidate scan
/// (including every installed Node version), then a login-shell lookup.
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
        if let support = tool.provider.acp {
            return await probeACP(tool, support: support, path: path, versionRun: versionRun)
        }
        guard versionRun.exitCode == 0 else {
            let detail = (versionRun.stderr.isEmpty ? versionRun.stdout : versionRun.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ProbeResult(path: path, error: "Could not run \(path): \(detail.prefix(200))")
        }
        let version = versionRun.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let authRun = await run(path, tool.authStatusArgs, timeout: 30)
        let loggedIn = tool.provider.loginState(stdout: authRun.stdout, stderr: authRun.stderr)
        return ProbeResult(path: path, version: version, loggedIn: loggedIn)
    }

    /// Assistants driven over ACP (Cline, Copilot): the version, then a session over ACP (no prompt, no tokens) that
    /// lists the account's models and refreshes the model menus. An empty version means the CLI exited quietly.
    private static func probeACP(_ tool: CLITool, support: any AssistantACPSupport, path: String, versionRun: RunResult) async -> ProbeResult {
        // "3.0.65" (Cline), "GitHub Copilot CLI 1.0.88." (Copilot).
        let firstLine = versionRun.stdout.split(separator: "\n").first.map(String.init) ?? ""
        let version = firstLine.range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map { String(firstLine[$0]) } ?? ""
        let probe = support.probe
        guard versionRun.exitCode == 0, !version.isEmpty else {
            let detail = (versionRun.stderr + versionRun.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty, let message = probe.silentExitMessage {
                return ProbeResult(path: path, error: message)
            }
            return ProbeResult(path: path, error: "Could not run \(path): \(detail.prefix(200))")
        }
        guard (Int(version.prefix(while: \.isNumber)) ?? 0) >= probe.minimumMajorVersion else {
            return ProbeResult(path: path, version: version,
                               error: "\(tool.displayName) \(version) is too old for MarkView — update: \(probe.installCommand)")
        }
        do {
            let models = try await ACPAssistant.refreshModels(tool, toolPath: path)
            return ProbeResult(path: path, version: "\(version) · \(models.count) models",
                               loggedIn: probe.modelListImpliesSignedIn && !models.isEmpty ? true : nil)
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

    /// Run a CLI off the main thread on the PATH the AI CLIs get (`subprocessPath`), through the shared runner
    /// (`Subprocess`: pipes drained concurrently, the whole process group ended at `timeout`). A timeout is
    /// exit code -2 with the elapsed time at the start of `stderr`.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> RunResult {
        let result = await Subprocess.run(SubprocessSpec(
            executable: executable, arguments: arguments, environment: ["PATH": subprocessPath(toolPath: executable)],
            timeout: timeout))
        if result.timedOut {
            return RunResult(exitCode: -2, stdout: result.stdout, stderr: "Timed out after \(Int(timeout))s. \(result.stderr)")
        }
        return RunResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
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
