import Foundation
import Darwin

/// A GitHub repository the workspace talks to: `origin`, or the repository it was forked from.
struct GitHubRepo: Hashable, Sendable {
    /// "owner/name"
    let slug: String
    /// Git remote (name or URL) that pull request heads are fetched from.
    let remote: String
    /// True for the parent of a fork (the `upstream` remote, or GitHub's parent).
    let isUpstream: Bool

    var webURL: URL? { URL(string: "https://github.com/" + slug) }
}

struct GitHubError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Host aliases of the person's SSH configuration. A Git remote may name an alias rather than
/// a real host (`git@my-github:owner/name.git`, with `HostName github.com` in `~/.ssh/config`),
/// and such a remote still points at GitHub. Reading the configuration keeps that recognition
/// out of a subprocess: it happens while a window loads its Git state.
enum SSHHostAliases {
    /// One `HostName` with the `Host` patterns it belongs to.
    private struct Entry {
        let patterns: [String]
        let hostName: String
    }

    /// The person's home directory. A checker passes one of its own.
    static var defaultHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Configuration files, in the order ssh reads them.
    private static func roots(home: URL) -> [URL] {
        [home.appendingPathComponent(".ssh/config"), URL(fileURLWithPath: "/etc/ssh/ssh_config")]
    }
    /// Files `Include` may reach, and how deep it may nest; a broken configuration cannot
    /// turn into an endless walk.
    private static let fileLimit = 64
    private static let depthLimit = 8

    private static let lock = NSLock()
    /// Parsed entries with the files they came from and the modification dates seen then.
    private static var cache: (signature: String, files: [URL], entries: [Entry])?

    /// The host an alias stands for, or `host` itself when no `Host` block matches it.
    static func resolve(_ host: String, home: URL = defaultHome) -> String {
        guard !host.isEmpty else { return host }
        for entry in entries(home: home) where matches(host, entry.patterns) {
            // ssh keeps the first HostName it finds, and %h is the host as given.
            return entry.hostName.replacingOccurrences(of: "%h", with: host)
        }
        return host
    }

    /// True when ssh would apply a `Host` line's patterns to this host: at least one positive
    /// pattern matches and no negated one does.
    private static func matches(_ host: String, _ patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if fnmatch(String(pattern.dropFirst()), host, 0) == 0 { return false }
            } else if fnmatch(pattern, host, 0) == 0 {
                matched = true
            }
        }
        return matched
    }

    private static func entries(home: URL) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        // The files of the last parse are re-checked, not re-read: an unchanged configuration
        // costs a few stats, and an edited or newly included file changes the signature.
        if let cache, cache.signature == signature(of: cache.files, home: home) { return cache.entries }
        var files: [URL] = []
        var parsed: [Entry] = []
        for root in roots(home: home) { parse(root, home: home, depth: 0, files: &files, into: &parsed) }
        cache = (signature(of: files, home: home), files, parsed)
        return parsed
    }

    private static func signature(of files: [URL], home: URL) -> String {
        // The roots are always part of the signature, files only once they were read: a
        // configuration created after the first lookup has to be noticed too.
        let all = roots(home: home) + files.filter { file in !roots(home: home).contains { $0.path == file.path } }
        return all.map { "\($0.path)@\(modified($0))" }.joined(separator: "|")
    }

    private static func modified(_ url: URL) -> TimeInterval {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
    }

    private static func parse(_ url: URL, home: URL, depth: Int, files: inout [URL], into entries: inout [Entry]) {
        let path = url.standardizedFileURL.path
        guard depth <= depthLimit, files.count < fileLimit, !files.contains(where: { $0.path == path }) else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        files.append(url.standardizedFileURL)
        var patterns: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let comment = line.firstIndex(of: "#") { line = String(line[line.startIndex..<comment]) }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            guard let keyword = tokens.first?.lowercased(), tokens.count > 1 else { continue }
            let values = Array(tokens.dropFirst())
            switch keyword {
            case "host":
                patterns = values
            case "match":
                // A Match block depends on the connection being made; none of its HostName
                // values can be claimed here, so the block is skipped.
                patterns = []
            case "hostname":
                if !patterns.isEmpty, let name = values.first { entries.append(Entry(patterns: patterns, hostName: name)) }
            case "include":
                for value in values {
                    for included in expand(value, home: home, relativeTo: url) {
                        parse(included, home: home, depth: depth + 1, files: &files, into: &entries)
                    }
                }
            default:
                break
            }
        }
    }

    /// Files an `Include` value names. Relative paths are read from `~/.ssh` (from `/etc/ssh`
    /// for the system-wide file), and a pattern is matched against the directory it names.
    private static func expand(_ value: String, home: URL, relativeTo parent: URL) -> [URL] {
        var path = value
        if path == "~" || path.hasPrefix("~/") { path = home.appendingPathComponent(String(path.dropFirst(1))).path }
        if !path.hasPrefix("/") {
            let base = parent.path.hasPrefix("/etc/ssh") ? URL(fileURLWithPath: "/etc/ssh") : home.appendingPathComponent(".ssh")
            path = base.appendingPathComponent(path).path
        }
        guard path.contains("*") || path.contains("?") || path.contains("[") else { return [URL(fileURLWithPath: path)] }
        let directory = (path as NSString).deletingLastPathComponent
        let pattern = (path as NSString).lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { fnmatch(pattern, $0, 0) == 0 }.sorted()
            .map { URL(fileURLWithPath: directory).appendingPathComponent($0) }
    }
}

// MARK: - Models (the JSON `gh` prints)

struct GHUser: Codable, Hashable, Sendable {
    let login: String
}

struct GHLabel: Codable, Hashable, Sendable {
    let name: String
    var color: String?
}

struct GHComment: Codable, Hashable, Sendable {
    var author: GHUser?
    var body: String
    var createdAt: String?
}

/// A check on a pull request: a check run (status/conclusion) or a commit status (state).
struct GHCheck: Codable, Hashable, Sendable {
    var name: String?
    var context: String?
    var status: String?
    var conclusion: String?
    var state: String?

    var title: String { name ?? context ?? "check" }

    var outcome: GHOutcome {
        if let state {  // commit status
            switch state.uppercased() {
            case "SUCCESS": return .success
            case "PENDING", "EXPECTED": return .running
            default: return .failure
            }
        }
        if (status ?? "").uppercased() != "COMPLETED" { return .running }
        return GHOutcome(conclusion: conclusion)
    }
}

/// How something ended (or that it has not yet).
enum GHOutcome: Sendable {
    case success, failure, running, neutral

    init(conclusion: String?) {
        switch (conclusion ?? "").lowercased() {
        case "success": self = .success
        case "failure", "timed_out", "startup_failure", "action_required": self = .failure
        case "": self = .running
        default: self = .neutral  // cancelled, skipped, neutral, stale
        }
    }

    init(status: String?, conclusion: String?) {
        if (status ?? "").lowercased() != "completed" { self = .running } else { self.init(conclusion: conclusion) }
    }
}

struct GHPullRequest: Codable, Identifiable, Hashable, Sendable {
    var id: Int { number }
    let number: Int
    var title: String
    var author: GHUser?
    var headRefName: String
    var baseRefName: String
    var state: String
    var isDraft: Bool?
    var url: String
    var createdAt: String?
    var updatedAt: String?
    var reviewDecision: String?
    var statusCheckRollup: [GHCheck]?
    var comments: [GHComment]?
    var mergeable: String?
    var headRefOid: String?

    static let listFields = "number,title,author,headRefName,baseRefName,state,isDraft,url,createdAt,updatedAt,reviewDecision,statusCheckRollup,comments"

    var checks: [GHCheck] { statusCheckRollup ?? [] }
    var passedChecks: Int { checks.filter { $0.outcome == .success }.count }

    /// Worst outcome of the checks, nil without checks.
    var checksOutcome: GHOutcome? {
        guard !checks.isEmpty else { return nil }
        if checks.contains(where: { $0.outcome == .failure }) { return .failure }
        if checks.contains(where: { $0.outcome == .running }) { return .running }
        return .success
    }
}

struct GHIssue: Codable, Identifiable, Hashable, Sendable {
    var id: Int { number }
    let number: Int
    var title: String
    var state: String
    var author: GHUser?
    var labels: [GHLabel]?
    var assignees: [GHUser]?
    var createdAt: String?
    var updatedAt: String?
    var comments: [GHComment]?
    var url: String
    var body: String?

    static let listFields = "number,title,state,author,labels,assignees,createdAt,updatedAt,comments,url"
    static let viewFields = listFields + ",body"

    var isOpen: Bool { state.uppercased() == "OPEN" }
}

/// An issue's text and comments as HTML rendered by GitHub.
struct GHIssueHTML: Sendable {
    struct Comment: Codable, Hashable, Sendable {
        var author: String?
        var avatar: String?
        var createdAt: String?
        var html: String
        /// What a pull request entry is: a review verdict or the file and line of a code comment.
        var label: String?
    }
    var body: String
    var comments: [Comment]
}

struct GHRun: Codable, Identifiable, Hashable, Sendable {
    var id: Int { databaseId }
    let databaseId: Int
    var number: Int
    var name: String?
    var displayTitle: String
    var workflowName: String
    var workflowDatabaseId: Int?
    var status: String
    var conclusion: String?
    var headBranch: String
    var event: String
    var createdAt: String
    var startedAt: String?
    var updatedAt: String?
    var url: String
    var attempt: Int?

    static let fields = "databaseId,number,name,displayTitle,workflowName,workflowDatabaseId,status,conclusion,headBranch,event,createdAt,startedAt,updatedAt,url,attempt"

    var outcome: GHOutcome { GHOutcome(status: status, conclusion: conclusion) }
    var isActive: Bool { outcome == .running }

    /// Seconds the run took (or has taken so far).
    var duration: TimeInterval? {
        guard let start = GHDate.parse(startedAt ?? createdAt) else { return nil }
        let end = isActive ? Date() : (GHDate.parse(updatedAt) ?? Date())
        return max(0, end.timeIntervalSince(start))
    }
}

struct GHStep: Codable, Hashable, Sendable {
    var name: String
    var number: Int
    var status: String
    var conclusion: String?
    var startedAt: String?
    var completedAt: String?

    var outcome: GHOutcome { GHOutcome(status: status, conclusion: conclusion) }
    var duration: TimeInterval? { GHDate.span(startedAt, completedAt, running: outcome == .running) }
}

struct GHJob: Codable, Identifiable, Hashable, Sendable {
    var id: Int { databaseId }
    let databaseId: Int
    var name: String
    var status: String
    var conclusion: String?
    var startedAt: String?
    var completedAt: String?
    var url: String?
    var steps: [GHStep]?

    var outcome: GHOutcome { GHOutcome(status: status, conclusion: conclusion) }
    var duration: TimeInterval? { GHDate.span(startedAt, completedAt, running: outcome == .running) }
}

struct GHWorkflow: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var path: String
    var state: String
}

/// One `workflow_dispatch` input, read from the workflow file.
struct GHWorkflowInput: Hashable, Sendable {
    var name: String
    var description: String?
    var required: Bool
    var defaultValue: String?
    /// string | boolean | choice | number | environment
    var type: String
    var options: [String]
}

/// Dates as `gh` prints them (ISO 8601; the zero date for "not yet").
enum GHDate {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let lock = NSLock()

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty, !text.hasPrefix("0001-") else { return nil }
        lock.lock(); defer { lock.unlock() }
        return formatter.date(from: text) ?? fractional.date(from: text)
    }

    static func span(_ start: String?, _ end: String?, running: Bool) -> TimeInterval? {
        guard let from = parse(start) else { return nil }
        let to = parse(end) ?? (running ? Date() : nil)
        return to.map { max(0, $0.timeIntervalSince(from)) }
    }

    /// "4:12", "1:02:40"
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "5m ago", "2h ago", "3d ago"
    static func ago(_ text: String?) -> String {
        guard let date = parse(text) else { return "" }
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        case ..<2_592_000: return "\(seconds / 86_400)d ago"
        default: return "\(seconds / 2_592_000)mo ago"
        }
    }
}

// MARK: - The `gh` command

/// The GitHub CLI configuration an open folder belongs to. People who work under more than one
/// GitHub account give each one its own `GH_CONFIG_DIR`, and their shell switches between them
/// per directory. A window has no shell, so the folder's configuration is resolved here and
/// passed to every `gh` it starts; otherwise the Git tab would speak as the default account,
/// which may not even see the repository.
enum GitHubProfile {
    /// Settings key of an explicit configuration directory. Empty: follow the folder.
    static let configDirectoryKey = "settings.github.configDirectory"
    /// A folder names its profile in this file, as the shell helper reads it.
    static let markerFile = ".ghprofile"
    /// Profiles live in `~/.config/gh-profiles/<name>/`, each a `GH_CONFIG_DIR` of its own.
    static func profilesRoot(home: URL = SSHHostAliases.defaultHome) -> URL {
        home.appendingPathComponent(".config/gh-profiles", isDirectory: true)
    }

    /// Where `gh` reads its configuration for a folder, and what the choice was made from.
    struct Resolved: Sendable {
        /// nil: `gh` keeps its own default (`~/.config/gh`).
        var directory: URL?
        var token: String?
        var sshCommand: String?
        /// Profile name, when a `.ghprofile` chose it.
        var name: String?
        /// Short description for the settings pane.
        var source: String
    }

    static func resolve(root: URL?, home: URL = SSHHostAliases.defaultHome) -> Resolved {
        let setting = (UserDefaults.standard.string(forKey: configDirectoryKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !setting.isEmpty {
            let directory = URL(fileURLWithPath: expandTilde(setting, home: home))
            return Resolved(directory: directory, source: "Settings")
        }
        guard let root, let name = profileName(near: root) else {
            return Resolved(source: "Default (gh)")
        }
        let directory = profilesRoot(home: home).appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return Resolved(name: name, source: "Default (gh) — no profile “\(name)”")
        }
        let values = environmentFile(directory.appendingPathComponent("profile.env"))
        let key = values["GHP_SSH_KEY"].map { expandTilde($0, home: home) }
        return Resolved(directory: directory,
                        token: values["GHP_TOKEN"],
                        sshCommand: key.map { "ssh -i \($0) -o IdentitiesOnly=yes" },
                        name: name,
                        source: "\(markerFile): \(name)")
    }

    /// Apply a folder's configuration to the environment of a `gh` or `git` run. A profile
    /// replaces an inherited token: the token of another account would override it.
    static func apply(to environment: inout [String: String], root: URL, home: URL = SSHHostAliases.defaultHome) {
        let resolved = resolve(root: root, home: home)
        guard let directory = resolved.directory else { return }
        environment["GH_CONFIG_DIR"] = directory.path
        if let token = resolved.token { environment["GITHUB_TOKEN"] = token } else { environment["GITHUB_TOKEN"] = nil }
        if let command = resolved.sshCommand { environment["GIT_SSH_COMMAND"] = command }
    }

    /// The profile named by the nearest `.ghprofile` at or above `root`.
    private static func profileName(near root: URL) -> String? {
        var directory = root.standardizedFileURL
        while directory.path != "/" {
            let marker = directory.appendingPathComponent(markerFile)
            if let text = try? String(contentsOf: marker, encoding: .utf8) {
                let name = text.split(separator: "\n")
                    .map { line -> String in
                        let body = line.firstIndex(of: "#").map { String(line[line.startIndex..<$0]) } ?? String(line)
                        return body.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .first { !$0.isEmpty }
                // A profile is a directory name; anything with a separator is not one.
                if let name, !name.contains("/") { return name }
                return nil
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            guard parent != directory else { break }
            directory = parent
        }
        return nil
    }

    /// A leading `~` stands for the home directory, as it does in a shell.
    private static func expandTilde(_ path: String, home: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home.appendingPathComponent(String(path.dropFirst(1))).path
    }

    /// `KEY=value` lines of a profile's `profile.env`, without quotes and `export`.
    private static func environmentFile(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let equals = line.firstIndex(of: "="), equals > line.startIndex else { continue }
            let key = String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                // A quoted value ends at its closing quote; anything after it is a comment.
                let body = value.dropFirst()
                guard let end = body.firstIndex(of: quote) else { continue }
                value = String(body[body.startIndex..<end])
            } else if let comment = value.firstIndex(of: "#") {
                value = String(value[value.startIndex..<comment]).trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            values[key] = value
        }
        return values
    }
}

/// Runs the GitHub CLI for one repository. Everything happens off the main thread; both
/// pipes are drained while `gh` runs, so a large answer (logs, diffs) cannot deadlock it.
struct GitHubClient: Sendable {
    let root: URL
    let repo: GitHubRepo

    /// `gh` on the PATH the AI CLIs get (Homebrew and friends), or nil.
    static func ghPath() -> String? {
        let path = CLIToolLocator.subprocessPath(toolPath: nil)
        return path.split(separator: ":").map { $0 + "/gh" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Run `gh` (or, with `git: true`, git) in `root`. Never waits for a prompt: stdin is
    /// closed and git's terminal prompt is off. The blocking reads run on GCD threads, not on
    /// Swift's small cooperative pool, and a process that hangs (offline, stalled proxy) is
    /// terminated after `timeout` seconds.
    static func execute(_ arguments: [String], in root: URL, git: Bool = false, timeout: TimeInterval = 60) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(arguments, in: root, git: git, timeout: timeout))
            }
        }
    }

    /// `gh` for code that already runs on its own thread (the X-Ray's pull-request sources and
    /// diffs): the runner of `execute`, called directly. Standard output when `gh` exits with 0,
    /// nil otherwise. GitHub is opt-in: `enabled` is `GitHubSettings.enabled`, read on the main
    /// actor by the caller, and while it is false `gh` is not started at all.
    static func output(_ arguments: [String], in root: URL, enabled: Bool, timeout: TimeInterval = 20) -> String? {
        guard enabled else { return nil }
        let output = runBlocking(arguments, in: root, git: false, timeout: timeout)
        return output.status == 0 ? output.stdout : nil
    }

    private static func runBlocking(_ arguments: [String], in root: URL, git: Bool, timeout: TimeInterval) -> Output {
        let path = CLIToolLocator.subprocessPath(toolPath: nil)
        let process = Process()
        if git {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        } else {
            guard let gh = ghPath() else {
                return Output(status: -1, stdout: "", stderr: "GitHub CLI (gh) is not installed. Install it with `brew install gh`.")
            }
            process.executableURL = URL(fileURLWithPath: gh)
        }
        process.arguments = arguments
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        GitHubProfile.apply(to: &env, root: root)
        process.environment = env
        let out = Pipe(), err = Pipe()
        // A PTY can fork concurrently with Process.run. Do not leave our pipe ends open
        // after another child's exec, and never depend on EOF from an inherited writer.
        for handle in [out.fileHandleForReading, out.fileHandleForWriting, err.fileHandleForReading, err.fileHandleForWriting] {
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC) == 0 else {
                return Output(status: -1, stdout: "", stderr: "Could not prepare GitHub command output.")
            }
        }
        let outputFD = out.fileHandleForReading.fileDescriptor, errorFD = err.fileHandleForReading.fileDescriptor
        for fd in [outputFD, errorFD] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                return Output(status: -1, stdout: "", stderr: "Could not prepare GitHub command output.")
            }
        }
        defer { try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close() }
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        var data = Data(), errData = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        let limit = 64 * 1024 * 1024
        // A bounded drain lets both pipes progress even when one is continuously producing.
        func drain(_ fd: Int32, into output: inout Data) {
            for _ in 0..<16 {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    output.append(contentsOf: buffer.prefix(count))
                    if output.count >= limit { return }
                } else if count < 0 && errno == EINTR { continue }
                else { return }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)
        var timedOut = false, oversized = false
        var stoppedAt: TimeInterval?
        while true {
            drain(outputFD, into: &data); drain(errorFD, into: &errData)
            oversized = oversized || data.count >= limit || errData.count >= limit
            let now = ProcessInfo.processInfo.systemUptime
            let running = process.isRunning
            if !running {
                // The process, rather than every possible inheritor of its stdout, owns this
                // request. Collect its final buffered bytes and finish without waiting for EOF.
                drain(outputFD, into: &data); drain(errorFD, into: &errData)
                oversized = oversized || data.count >= limit || errData.count >= limit
                break
            }
            if stoppedAt == nil, now >= deadline || oversized {
                timedOut = !oversized
                stoppedAt = now
                process.terminate()
            }
            if let stoppedAt, now - stoppedAt >= 0.2 {
                _ = kill(process.processIdentifier, SIGKILL)
                // SIGKILL normally exits immediately. A broken process must not hold a UI
                // loading flag forever even if the OS has not delivered its exit callback.
                if now - stoppedAt >= 2 { break }
            }
            usleep(10_000)
        }
        if oversized {
            return Output(status: -1, stdout: "", stderr: "GitHub response exceeded 64 MB. Request a smaller log or fewer results.")
        }
        if timedOut {
            return Output(status: -1, stdout: "", stderr: "GitHub did not answer within \(Int(timeout)) s (offline?).")
        }
        return Output(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    /// `gh …` for this repository; throws with gh's own message when it fails.
    @discardableResult
    func gh(_ arguments: [String], timeout: TimeInterval = 60) async throws -> String {
        let output = await Self.execute(arguments, in: root, timeout: timeout)
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubError(message: message.isEmpty ? "gh \(arguments.first ?? "") failed" : String(message.prefix(400)))
        }
        return output.stdout
    }

    private func decode<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
        let text = try await gh(arguments)
        do { return try JSONDecoder().decode(T.self, from: Data(text.utf8)) } catch {
            throw GitHubError(message: "Unexpected answer from gh: \(error.localizedDescription)")
        }
    }

    private var r: [String] { ["-R", repo.slug] }

    // MARK: Repository and account

    /// GitHub repositories of the checkout at `root`: `origin`, then the repository it was
    /// forked from (`upstream` remote, or GitHub's parent fetched by URL).
    static func detectRepos(root: URL) async -> [GitHubRepo] {
        let remotes = await execute(["remote", "-v"], in: root, git: true)
        guard remotes.status == 0 else { return [] }
        var slugs: [String: String] = [:]  // remote name → slug
        for line in remotes.stdout.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let slug = slug(fromRemoteURL: String(parts[1])) else { continue }
            slugs[String(parts[0])] = slug
        }
        var repos: [GitHubRepo] = []
        if let origin = slugs["origin"] ?? slugs.values.sorted().first {
            repos.append(GitHubRepo(slug: origin, remote: slugs["origin"] != nil ? "origin" : (slugs.first { $0.value == origin }?.key ?? "origin"), isUpstream: false))
        }
        if let upstream = slugs["upstream"], upstream != repos.first?.slug {
            repos.append(GitHubRepo(slug: upstream, remote: "upstream", isUpstream: true))
        } else if let origin = repos.first {
            let view = await execute(["repo", "view", origin.slug, "--json", "parent"], in: root)
            if view.status == 0,
               let object = try? JSONSerialization.jsonObject(with: Data(view.stdout.utf8)) as? [String: Any],
               let parent = object["parent"] as? [String: Any],
               let owner = (parent["owner"] as? [String: Any])?["login"] as? String,
               let name = parent["name"] as? String {
                let slug = owner + "/" + name
                repos.append(GitHubRepo(slug: slug, remote: "https://github.com/\(slug).git", isUpstream: true))
            }
        }
        return repos
    }

    /// "owner/name" from git@github.com:owner/name.git or https://github.com/owner/name(.git).
    /// An SSH remote may name a host alias instead of github.com (`git@my-github:owner/name.git`
    /// with the real host in `~/.ssh/config`), so an unrecognized SSH host is resolved through
    /// that configuration before the remote is given up on.
    static func slug(fromRemoteURL url: String, home: URL = SSHHostAliases.defaultHome) -> String? {
        if let slug = githubSlug(fromURL: url) { return slug }
        guard let (host, path) = sshHostAndPath(url) else { return nil }
        let resolved = SSHHostAliases.resolve(host, home: home)
        guard resolved.lowercased() != host.lowercased() else { return nil }
        return githubSlug(fromURL: resolved + ":" + path)
    }

    /// "owner/name" when the URL names github.com itself.
    private static func githubSlug(fromURL url: String) -> String? {
        guard let range = url.range(of: #"github\.com[:/]([^/\s]+)/([^/\s]+?)(\.git)?/?$"#, options: .regularExpression) else { return nil }
        var tail = String(url[range]).dropFirst("github.com".count + 1)
        if tail.hasSuffix("/") { tail = tail.dropLast() }
        if tail.hasSuffix(".git") { tail = tail.dropLast(4) }
        return String(tail)
    }

    /// Host and path of an SSH remote — `ssh://git@host[:port]/owner/name.git` or the scp form
    /// `git@host:owner/name.git` — or nil when the URL is not SSH-like.
    static func sshHostAndPath(_ url: String) -> (host: String, path: String)? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: String, path: String
        if let rest = text.range(of: "ssh://").flatMap({ $0.lowerBound == text.startIndex ? String(text[$0.upperBound...]) : nil }) {
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[rest.startIndex..<slash])
            path = String(rest[rest.index(after: slash)...])
            if let colon = host.lastIndex(of: ":") { host = String(host[host.startIndex..<colon]) }
        } else {
            guard !text.contains("://"), let colon = text.firstIndex(of: ":") else { return nil }
            host = String(text[text.startIndex..<colon])
            path = String(text[text.index(after: colon)...])
        }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        guard !host.isEmpty, !host.contains("/"), !path.isEmpty else { return nil }
        return (host, path)
    }

    struct Account: Sendable {
        let login: String
        let scopes: [String]
    }

    /// The signed-in account and its token's scopes.
    static func account(root: URL) async throws -> Account {
        let output = await execute(["api", "-i", "user"], in: root)
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubError(message: message.isEmpty ? "Not signed in to GitHub." : message)
        }
        var scopes: [String] = []
        var login = ""
        let parts = output.stdout.components(separatedBy: "\r\n\r\n")
        for line in (parts.first ?? "").components(separatedBy: "\r\n") where line.lowercased().hasPrefix("x-oauth-scopes:") {
            scopes = line.dropFirst("x-oauth-scopes:".count).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let body = parts.dropFirst().joined(separator: "\r\n\r\n").data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            login = object["login"] as? String ?? ""
        }
        return Account(login: login, scopes: scopes)
    }

    // MARK: Pull requests

    enum PRFilter: String, CaseIterable, Sendable { case all = "All", mine = "Mine", reviewRequested = "Review requested" }

    func pullRequests(state: String, filter: PRFilter) async throws -> [GHPullRequest] {
        var args = ["pr", "list"] + r + ["--state", state, "--limit", "100", "--json", GHPullRequest.listFields]
        switch filter {
        case .all: break
        case .mine: args += ["--author", "@me"]
        case .reviewRequested: args += ["--search", "review-requested:@me"]
        }
        return try await decode([GHPullRequest].self, args)
    }

    func pullRequest(_ number: Int) async throws -> GHPullRequest {
        try await decode(GHPullRequest.self, ["pr", "view", String(number)] + r
            + ["--json", GHPullRequest.listFields + ",mergeable,headRefOid"])
    }

    /// Lifecycle events of the pull requests that are, or close, issues `numbers` (one query), and
    /// each such pull request's last commit (whose CI runs `ciCaptures` reads).
    func lifecycleCaptures(numbers: [Int]) async throws -> (captures: [LifecycleGitHub.Capture], heads: [(note: String, sha: String)]) {
        let parts = repo.slug.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !numbers.isEmpty else { return ([], []) }
        let text = try await gh(["api", "graphql", "-f", "query=" + LifecycleGitHub.query(numbers: numbers),
                                 "-f", "owner=" + parts[0], "-f", "name=" + parts[1]])
        let data = Data(text.utf8)
        return (LifecycleGitHub.captures(from: data), LifecycleGitHub.heads(from: data))
    }

    /// The Actions runs of commit `sha`: one call gives both the CI events (request, start, re-runs)
    /// and, when every run succeeded, the time the last one finished.
    func ciRuns(commit sha: String, note: String) async throws -> (captures: [LifecycleGitHub.Capture], passed: Date?) {
        let json = try await gh(["run", "list"] + r + ["--commit", sha, "-L", "100", "--json", LifecycleCICapture.runFields])
        let data = Data(json.utf8)
        return (LifecycleCICapture.captures(runsJSON: data, note: note), LifecycleGit.ciPassed(runsJSON: data))
    }

    /// The pull request's description and its whole conversation — comments, reviews and code
    /// comments — as GitHub renders them, oldest first.
    func pullRequestHTML(_ number: Int) async throws -> GHIssueHTML {
        let accept = ["-H", "Accept: application/vnd.github.full+json"]
        let body = try await gh(["api", "repos/\(repo.slug)/pulls/\(number)"] + accept + ["-q", ".body_html // \"\""])
        func entries(_ path: String, _ shape: String) async throws -> [GHIssueHTML.Comment] {
            let lines = try await gh(["api", "repos/\(repo.slug)/\(path)?per_page=100", "--paginate"] + accept + ["-q", shape])
            return lines.split(separator: "\n").compactMap { try? JSONDecoder().decode(GHIssueHTML.Comment.self, from: Data($0.utf8)) }
        }
        let user = "author: .user.login, avatar: .user.avatar_url"
        async let comments = entries("issues/\(number)/comments",
            ".[] | {\(user), createdAt: .created_at, html: (.body_html // \"\")}")
        // A review without text only groups its code comments, which are listed on their own.
        async let reviews = entries("pulls/\(number)/reviews",
            ".[] | select(.state != \"PENDING\" and (.state != \"COMMENTED\" or ((.body // \"\") != \"\"))) | {\(user), createdAt: .submitted_at, label: .state, html: (.body_html // \"\")}")
        async let code = entries("pulls/\(number)/comments",
            ".[] | {\(user), createdAt: .created_at, label: (.path + \":\" + ((.line // .original_line // 0) | tostring)), html: (.body_html // \"\")}")
        let all = try await comments + reviews + code
        return GHIssueHTML(body: body.trimmingCharacters(in: .newlines),
                           comments: all.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") })
    }

    /// Check the pull request out into the working copy (`gh pr checkout`).
    func checkout(_ number: Int) async throws {
        try await gh(["pr", "checkout", String(number)] + r)
    }

    /// approve | request-changes | comment
    func review(_ number: Int, action: String, body: String) async throws {
        guard ["approve", "request-changes", "comment"].contains(action) else { throw GitHubError(message: "Unknown review action.") }
        var args = ["pr", "review", String(number)] + r + ["--" + action]
        if !body.isEmpty { args += ["--body", body] }
        try await gh(args)
    }

    /// merge | squash | rebase
    static let mergeMethods: Set<String> = ["merge", "squash", "rebase"]

    func merge(_ number: Int, method: String) async throws {
        guard Self.mergeMethods.contains(method) else { throw GitHubError(message: "Unknown merge method \(method).") }
        try await gh(["pr", "merge", String(number)] + r + ["--" + method])
    }

    func closePR(_ number: Int) async throws {
        try await gh(["pr", "close", String(number)] + r)
    }

    func commentPR(_ number: Int, body: String) async throws {
        try await gh(["pr", "comment", String(number)] + r + ["--body", body])
    }

    /// A review comment on one line of the pull request's new code.
    func lineComment(_ number: Int, commit: String, path: String, line: Int, body: String) async throws {
        try await gh(["api", "repos/\(repo.slug)/pulls/\(number)/comments", "-X", "POST",
                      "-f", "body=\(body)", "-f", "commit_id=\(commit)", "-f", "path=\(path)",
                      "-F", "line=\(line)", "-f", "side=RIGHT"])
    }

    /// Open a pull request from `head` (already pushed); returns its URL.
    func createPR(title: String, body: String, base: String, head: String, draft: Bool) async throws -> String {
        var args = ["pr", "create"] + r + ["--title", title, "--body", body, "--base", base, "--head", head]
        if draft { args.append("--draft") }
        return try await gh(args).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Issues

    enum IssueFilter: String, CaseIterable, Sendable { case all = "All", assigned = "Assigned to me", created = "Created by me" }

    func issues(state: String, filter: IssueFilter, search: String = "") async throws -> [GHIssue] {
        var args = ["issue", "list"] + r + ["--state", state, "--limit", "100", "--json", GHIssue.listFields]
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args += ["--search", search] }
        switch filter {
        case .all: break
        case .assigned: args += ["--assignee", "@me"]
        case .created: args += ["--author", "@me"]
        }
        return try await decode([GHIssue].self, args)
    }

    func issue(_ number: Int) async throws -> GHIssue {
        try await decode(GHIssue.self, ["issue", "view", String(number)] + r + ["--json", GHIssue.viewFields])
    }

    /// The issue's text and comments as GitHub renders them (HTML, sanitized by GitHub; image
    /// links are signed for a few minutes, so private repositories' images load too).
    func issueHTML(_ number: Int) async throws -> GHIssueHTML {
        let accept = ["-H", "Accept: application/vnd.github.full+json"]
        let body = try await gh(["api", "repos/\(repo.slug)/issues/\(number)"] + accept + ["-q", ".body_html // \"\""])
        // One JSON object per line, all pages.
        let lines = try await gh(["api", "repos/\(repo.slug)/issues/\(number)/comments?per_page=100", "--paginate"] + accept
            + ["-q", ".[] | {author: .user.login, avatar: .user.avatar_url, createdAt: .created_at, html: (.body_html // \"\")}"])
        let comments = lines.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(GHIssueHTML.Comment.self, from: Data($0.utf8))
        }
        return GHIssueHTML(body: body.trimmingCharacters(in: .newlines), comments: comments)
    }

    func commentIssue(_ number: Int, body: String) async throws {
        try await gh(["issue", "comment", String(number)] + r + ["--body", body])
    }

    func setIssueOpen(_ number: Int, open: Bool) async throws {
        try await gh(["issue", open ? "reopen" : "close", String(number)] + r)
    }

    func editIssueContent(_ number: Int, title: String, body: String) async throws {
        try await gh(["issue", "edit", String(number)] + r + ["--title", title, "--body", body])
    }

    /// Add or remove labels and assignees.
    func editIssue(_ number: Int, addLabels: [String] = [], removeLabels: [String] = [],
                   addAssignees: [String] = [], removeAssignees: [String] = []) async throws {
        var args = ["issue", "edit", String(number)] + r
        for label in addLabels { args += ["--add-label", label] }
        for label in removeLabels { args += ["--remove-label", label] }
        for user in addAssignees { args += ["--add-assignee", user] }
        for user in removeAssignees { args += ["--remove-assignee", user] }
        try await gh(args)
    }

    /// Create an issue; returns its URL.
    func createIssue(title: String, body: String, labels: [String] = []) async throws -> String {
        var args = ["issue", "create"] + r + ["--title", title, "--body", body]
        for label in labels { args += ["--label", label] }
        return try await gh(args).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func labels() async throws -> [GHLabel] {
        try await decode([GHLabel].self, ["label", "list"] + r + ["--limit", "200", "--json", "name,color"])
    }

    /// People issues can be assigned to.
    func assignableUsers() async throws -> [String] {
        let text = try await gh(["api", "repos/\(repo.slug)/assignees", "--paginate", "--jq", ".[].login"])
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: Actions

    func runs(workflow: Int?, branch: String?) async throws -> [GHRun] {
        var args = ["run", "list"] + r + ["--limit", "50", "--json", GHRun.fields]
        if let workflow { args += ["--workflow", String(workflow)] }
        if let branch, !branch.isEmpty { args += ["--branch", branch] }
        return try await decode([GHRun].self, args)
    }

    func run(_ id: Int) async throws -> GHRun {
        try await decode(GHRun.self, ["run", "view", String(id)] + r + ["--json", GHRun.fields])
    }

    func jobs(run id: Int) async throws -> [GHJob] {
        struct Jobs: Decodable { let jobs: [GHJob] }
        return try await decode(Jobs.self, ["run", "view", String(id)] + r + ["--json", "jobs"]).jobs
    }

    /// A finished job's whole log (GitHub serves logs once the job is complete).
    func jobLog(_ jobId: Int) async throws -> String {
        try await gh(["api", "repos/\(repo.slug)/actions/jobs/\(jobId)/logs"], timeout: 180)
    }

    func rerun(_ id: Int, failedOnly: Bool) async throws {
        try await gh(["run", "rerun", String(id)] + r + (failedOnly ? ["--failed"] : []))
    }

    func cancel(_ id: Int) async throws {
        try await gh(["run", "cancel", String(id)] + r)
    }

    func workflows() async throws -> [GHWorkflow] {
        try await decode([GHWorkflow].self, ["workflow", "list"] + r + ["--all", "--json", "id,name,path,state"])
    }

    /// Start a `workflow_dispatch` workflow on `ref` with `inputs`.
    func dispatch(workflow: Int, ref: String, inputs: [String: String]) async throws {
        var args = ["workflow", "run", String(workflow)] + r + ["--ref", ref]
        for (key, value) in inputs.sorted(by: { $0.key < $1.key }) { args += ["-f", "\(key)=\(value)"] }
        try await gh(args)
    }

    /// The workflow file as it is on the default branch.
    func workflowFile(_ path: String) async throws -> String {
        let text = try await gh(["api", "repos/\(repo.slug)/contents/\(path)", "-H", "Accept: application/vnd.github.raw"])
        return text
    }
}

// MARK: - Workflow files and logs

enum GHWorkflowFile {
    /// Whether the workflow can be started by hand, and its inputs. A small reader for the
    /// `on: workflow_dispatch: inputs:` block (indentation-based, no YAML library).
    static func dispatchInputs(_ yaml: String) -> (dispatchable: Bool, inputs: [GHWorkflowInput]) {
        let lines = yaml.components(separatedBy: "\n").map { line -> String in
            // Drop comments that are not inside quotes (good enough for keys and scalars).
            guard let hash = line.range(of: " #") else { return line.hasPrefix("#") ? "" : line }
            return String(line[..<hash.lowerBound])
        }
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func keyValue(_ line: String) -> (String, String)? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let key = trimmed[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \"'-"))
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return (key, unquote(value))
        }
        guard let dispatchIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("workflow_dispatch")
                || $0.contains("[") && $0.contains("workflow_dispatch")
                || $0.trimmingCharacters(in: .whitespaces) == "on: workflow_dispatch"
        }) else { return (false, []) }
        let base = indent(lines[dispatchIndex])
        var i = dispatchIndex + 1
        // Find "inputs:" inside the workflow_dispatch block.
        var inputsIndent: Int?
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            if indent(line) <= base { break }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("inputs:") { inputsIndent = indent(line); i += 1; break }
            i += 1
        }
        guard let inputsIndent else { return (true, []) }
        var inputs: [GHWorkflowInput] = []
        var current: GHWorkflowInput?
        var nameIndent: Int?
        var inOptions = false
        while i < lines.count {
            let line = lines[i]; i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let level = indent(line)
            if level <= inputsIndent { break }
            if nameIndent == nil || level == nameIndent {
                if let current { inputs.append(current) }
                nameIndent = level
                let name = trimmed.hasSuffix(":") ? String(trimmed.dropLast()) : (keyValue(line)?.0 ?? trimmed)
                current = GHWorkflowInput(name: unquote(name), description: nil, required: false, defaultValue: nil, type: "string", options: [])
                inOptions = false
                continue
            }
            if inOptions, trimmed.hasPrefix("- ") {
                current?.options.append(unquote(String(trimmed.dropFirst(2))))
                continue
            }
            inOptions = false
            guard let (key, value) = keyValue(line) else { continue }
            switch key {
            case "description": current?.description = value
            case "required": current?.required = value.lowercased() == "true"
            case "default": current?.defaultValue = value
            case "type": current?.type = value
            case "options":
                if value.hasPrefix("[") {
                    current?.options = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                } else { inOptions = true }
            default: break
            }
        }
        if let current { inputs.append(current) }
        return (true, inputs)
    }

    private static func unquote(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }
}

/// One line of a job log, without its timestamp.
struct GHLogLine: Hashable, Sendable {
    let index: Int
    let text: String
    /// ##[error] lines and compiler-style "error:" lines.
    let isError: Bool
    let isWarning: Bool
}

enum GHJobLog {
    /// Split a job's log into its steps. The log marks where steps begin: after "Set up job"
    /// each step opens with a top-level `##[group]Run …` line, post steps with "Post job
    /// cleanup.", and "Complete job" with "Cleaning up orphan processes". Steps are walked in
    /// order; a `Run` marker only moves on once the next step has started (by the steps'
    /// whole-second times), so the inner steps of composite actions stay in their step.
    static func split(_ log: String, steps: [GHStep]) -> [Int: [GHLogLine]] {
        // Skipped steps print nothing.
        let ran = steps.filter { ($0.conclusion ?? "").lowercased() != "skipped" }
        var result: [Int: [GHLogLine]] = [:]
        var position = 0
        var index = 0
        func isPost(_ step: GHStep) -> Bool { step.name.hasPrefix("Post ") }
        func isComplete(_ step: GHStep) -> Bool { step.name == "Complete job" }
        func advance(where match: (GHStep) -> Bool, at date: Date?) {
            guard let next = ran.indices.first(where: { $0 > position && match(ran[$0]) }) else { return }
            if let date, let start = GHDate.parse(ran[next].startedAt), date < start { return }
            position = next
        }
        for raw in log.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if line.hasSuffix("\r") { line.removeLast() }
            var text = line
            var date: Date?
            if line.count > 29, line.dropFirst(4).first == "-", let space = line.firstIndex(of: " ") {
                date = parseStamp(String(line[..<space]))
                text = String(line[line.index(after: space)...])
            }
            if text.hasPrefix("##[group]Run ") {
                advance(where: { !isPost($0) && !isComplete($0) }, at: date)
            } else if text == "Post job cleanup." {
                advance(where: isPost, at: nil)
            } else if text.hasPrefix("Cleaning up orphan processes") {
                advance(where: isComplete, at: nil)
            }
            if text == "##[endgroup]" { continue }
            let lower = text.lowercased()
            let isError = text.hasPrefix("##[error]") || lower.contains(" error:") || lower.hasPrefix("error:")
                || lower.contains("** build failed **") || lower.contains("fatal:")
            let isWarning = !isError && (text.hasPrefix("##[warning]") || lower.contains(" warning:"))
            // Workflow commands as readable text.
            for (marker, replacement) in [("##[group]", "▸ "), ("##[error]", "Error: "), ("##[warning]", "Warning: "),
                                          ("##[notice]", "Notice: "), ("##[debug]", "")] where text.hasPrefix(marker) {
                text = replacement + text.dropFirst(marker.count)
            }
            let step = ran.isEmpty ? 0 : ran[position].number
            result[step, default: []].append(GHLogLine(index: index, text: text, isError: isError, isWarning: isWarning))
            index += 1
        }
        return result
    }

    private static let stampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let lock = NSLock()

    /// "2026-09-25T11:51:34.4762030Z" (7 fraction digits) → Date.
    private static func parseStamp(_ stamp: String) -> Date? {
        guard stamp.hasSuffix("Z"), let dot = stamp.firstIndex(of: ".") else { return GHDate.parse(stamp) }
        let fraction = stamp[stamp.index(after: dot)..<stamp.index(before: stamp.endIndex)]
        let trimmed = String(stamp[..<dot]) + "." + fraction.prefix(3) + "Z"
        lock.lock(); defer { lock.unlock() }
        return stampFormatter.date(from: trimmed)
    }
}
