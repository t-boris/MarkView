import Foundation
import AppKit

/// Settings of New Research: the job timeout (global) and the per-repository web search
/// opt-out (DEC-011, DEC-012).
enum ResearchSettings {
    static let timeoutKey = "research.timeoutMinutes"
    static let defaultTimeoutMinutes = 20

    static var timeoutMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: timeoutKey)
        return stored > 0 ? stored : defaultTimeoutMinutes
    }

    static func webDisabledKey(_ root: URL) -> String {
        "research.webDisabled." + String(ContentHash.of(root.standardizedFileURL.path).prefix(12))
    }

    static func isWebDisabled(_ root: URL) -> Bool {
        UserDefaults.standard.bool(forKey: webDisabledKey(root))
    }
}

/// Research jobs of one window: new research, follow-ups, retries and comments, each a
/// cancellable headless agent run (DEC-012) over the repository. Owned by `WorkspaceManager`.
@MainActor
final class ResearchJobs: ObservableObject {
    struct Job: Identifiable {
        enum Kind { case research, followUp, comment }
        let id = UUID()
        let kind: Kind
        /// The research document the job writes.
        let file: URL
        /// What the bar shows ("Research: <question>").
        let title: String
        let started = Date()
        var step = "Starting"
        fileprivate var task: Task<Void, Never>?
    }

    /// The "Continue / deepen" sheet to show (ContentView presents it).
    struct FollowUpRequest: Identifiable {
        let id = UUID()
        let file: URL
    }

    @Published private(set) var jobs: [Job] = []
    /// The last problem to show in the bar (cleared by the user or the next job).
    @Published var message: String?
    @Published var followUp: FollowUpRequest?

    weak var workspace: WorkspaceManager?

    func isRunning(on file: URL) -> Bool {
        jobs.contains { $0.file.standardizedFileURL == file.standardizedFileURL }
    }

    func cancel(_ id: UUID) {
        jobs.first { $0.id == id }?.task?.cancel()
    }

    // MARK: - New research (I-3)

    /// Starts a research: copies attachments, lists the analysis scope, runs the agent and
    /// writes `relativePath` (a free name is chosen if it was taken meanwhile), then opens it.
    func start(question: String, relativePath: String, targets: [URL], attachments: [URL]) {
        guard let root = workspace?.rootNode?.url else { return }
        let file = root.appendingPathComponent(relativePath)
        let id = ResearchDocument.id(forPath: relativePath)
        let title = Self.title(question)
        launch(kind: .research, file: file, title: "Research: " + title) { job in
            let targetPaths = await Task.detached { ResearchScope.targetFiles(root: root, targets: targets) }.value
            job.update("Copying attachments")
            let copied = Self.copyAttachments(attachments, root: root, id: id)
            job.update("Listing the repository")
            let scope = await Task.detached { ResearchScope.files(root: root, always: targetPaths + copied) }.value
            let web = Self.web(root)
            let prompt = ResearchPrompt.research(question: question, targets: targetPaths, attachments: copied, scope: scope, web: web.allowed)
            let outcome = await job.run(prompt: prompt, root: root, web: web.allowed)
            var run = ResearchDocument.Run(question: question, answer: ResearchDocument.parseAnswer(outcome.text))
            run.incomplete = Self.incompleteReason(outcome, web: web)
            run.targets = targetPaths
            run.attachments = copied
            run.filesRead = outcome.filesRead(root: root)
            run.urlsFetched = outcome.urls
            run.webQueries = outcome.queries
            run.notes = web.note.map { [$0] } ?? []
            run.noProjectFiles = scope.isEmpty
            let exists = Self.existsIn(root)
            let text = ResearchDocument.newDocument(id: id, title: title, created: FeatureStore.today, run: run, pathExists: exists)
            let target = Self.freeFile(file, root: root)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: target, options: .withoutOverwriting)
            } catch {
                return "Could not save the research: \(error.localizedDescription)"
            }
            self.workspace?.refreshFileTree()
            self.workspace?.openFile(target)
            return run.incomplete.map { "Research saved as incomplete: \($0)" }
        }
    }

    // MARK: - Continue / deepen, retry (I-5)

    /// Opens the "Continue / deepen" sheet; unsaved edits must be saved first (DEC-014).
    func requestFollowUp(for file: URL) {
        guard workspace?.saveBeforeResearch(file, action: "continuing the research") == true else { return }
        followUp = FollowUpRequest(file: file)
    }

    /// Appends a follow-up (or, with `retry`, a retry of that incomplete section) to `file`.
    func followUp(_ file: URL, question: String, retry: ResearchDocument.Section?) {
        guard let root = workspace?.rootNode?.url else { return }
        guard workspace?.saveBeforeResearch(file, action: "continuing the research") == true else { return }
        let label = retry.map { "Retry: \($0.name)" } ?? "Follow-up: " + Self.title(question)
        launch(kind: .followUp, file: file, title: label) { job in
            guard let current = try? String(contentsOf: file, encoding: .utf8) else { return "Could not read \(file.lastPathComponent)." }
            job.update("Listing the repository")
            let targets = FrontMatter.split(current).0.strings("targets")
            let scope = await Task.detached { ResearchScope.files(root: root, always: targets) }.value
            let web = Self.web(root)
            let prompt = ResearchPrompt.followUp(document: current, question: question, retrying: retry?.text,
                                                 scope: scope, web: web.allowed)
            let outcome = await job.run(prompt: prompt, root: root, web: web.allowed)
            var run = ResearchDocument.Run(question: question, answer: ResearchDocument.parseAnswer(outcome.text))
            run.incomplete = Self.incompleteReason(outcome, web: web)
            run.filesRead = outcome.filesRead(root: root)
            run.urlsFetched = outcome.urls
            run.webQueries = outcome.queries
            run.notes = web.note.map { [$0] } ?? []
            run.noProjectFiles = scope.isEmpty
            let exists = Self.existsIn(root)
            // Appended to the file as it is now, not the copy the job started from (DEC-014).
            guard let latest = try? String(contentsOf: file, encoding: .utf8) else { return "\(file.lastPathComponent) is gone; the follow-up was not saved." }
            let number = ResearchDocument.nextFollowUpNumber(latest)
            let section = ResearchDocument.followUpSection(number: number, date: FeatureStore.today, retryOf: retry?.name,
                                                           run: run, pathExists: exists)
            guard let updated = ResearchDocument.appending(section, to: latest, webQueries: run.webQueries) else {
                return "\(file.lastPathComponent) has front matter the app cannot rewrite safely (comments?); the follow-up was not saved."
            }
            do { try Data(updated.utf8).write(to: file, options: .atomic) } catch {
                return "Could not save the follow-up: \(error.localizedDescription)"
            }
            self.workspace?.researchDocumentChanged(file, content: updated) { tabText in
                ResearchDocument.appending(section, to: tabText, webQueries: run.webQueries)
            }
            return run.incomplete.map { "Follow-up saved as incomplete: \($0)" }
        }
    }

    // MARK: - Comments (I-6, DEC-017)

    /// The AI revises the smallest section containing `passage` according to `comment`.
    func comment(on passage: String, comment: String, in file: URL) {
        guard let root = workspace?.rootNode?.url else { return }
        guard !isRunning(on: file) else {
            message = "Another research job is working on \(file.lastPathComponent); comment when it has finished."
            return
        }
        guard workspace?.saveBeforeResearch(file, action: "revising it with your comment") == true else { return }
        guard let current = try? String(contentsOf: file, encoding: .utf8),
              let range = ResearchDocument.enclosingSection(of: passage, in: current) else {
            message = "The selected text was not found under a heading of \(file.lastPathComponent); select text inside a section."
            return
        }
        let original = String(current[range])
        launch(kind: .comment, file: file, title: "Comment: " + Self.title(comment)) { job in
            let web = Self.web(root)
            let targets = FrontMatter.split(current).0.strings("targets")
            let scope = await Task.detached { ResearchScope.files(root: root, always: targets) }.value
            let prompt = ResearchPrompt.comment(document: current, section: original, passage: passage, comment: comment,
                                                scope: scope, web: web.allowed)
            let outcome = await job.run(prompt: prompt, root: root, web: web.allowed)
            if let failure = outcome.failure { return "The comment was not applied: \(failure). The document is unchanged." }
            let revised = ResearchPrompt.revisedSection(outcome.text, original: original)
            guard !revised.isEmpty else { return "The assistant returned no revised text; the document is unchanged." }
            let checked = ResearchDocument.checkingLabels(in: revised, pathExists: Self.existsIn(root))
            // Written only when the section is still the one the AI saw (DEC-017).
            guard let latest = try? String(contentsOf: file, encoding: .utf8),
                  let now = latest.range(of: original) else {
                return "The section changed while the AI worked; nothing was overwritten. Comment again on the current text."
            }
            guard let updated = ResearchDocument.replacing(now, in: latest, with: checked, webQueries: outcome.queries) else {
                return "\(file.lastPathComponent) has front matter the app cannot rewrite safely (comments?); the comment was not applied."
            }
            do { try Data(updated.utf8).write(to: file, options: .atomic) } catch {
                return "Could not save the revision: \(error.localizedDescription)"
            }
            self.workspace?.researchDocumentChanged(file, content: updated) { tabText in
                tabText.range(of: original).flatMap { ResearchDocument.replacing($0, in: tabText, with: checked, webQueries: outcome.queries) }
            }
            return nil
        }
    }

    // MARK: - Running

    /// Adds a job to the bar and runs `body`; its return value is the message to show (nil = none).
    private func launch(kind: Job.Kind, file: URL, title: String, body: @escaping (JobHandle) async -> String?) {
        message = nil
        var job = Job(kind: kind, file: file, title: title)
        let handle = JobHandle(id: job.id, owner: self)
        job.task = Task { [weak self] in
            let result = await body(handle)
            self?.jobs.removeAll { $0.id == handle.id }
            if let result { self?.message = result }
        }
        jobs.append(job)
    }

    fileprivate func setStep(_ step: String, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].step = step
    }

    /// Web search for this run: allowed unless the repository opted out or the backend has none.
    private static func web(_ root: URL) -> (allowed: Bool, unavailable: String?, note: String?) {
        if ResearchSettings.isWebDisabled(root) {
            return (false, nil, "Web search: disabled for this repository, so the research is repository-only.")
        }
        let tool = AIAssistantPreferences.backend
        if tool.usesACP {
            return (false, "web search unavailable (\(tool.displayName) has no web access), so the findings are repository-only", nil)
        }
        return (true, nil, nil)
    }

    private static func incompleteReason(_ outcome: JobOutcome, web: (allowed: Bool, unavailable: String?, note: String?)) -> String? {
        let reasons = [outcome.failure, outcome.webRefused, web.unavailable].compactMap { $0 }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    /// The first line, cut at a word boundary after at most 90 characters.
    private static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 90 else { return trimmed }
        let head = trimmed.prefix(90)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    nonisolated static func relative(_ url: URL, to root: URL) -> String? {
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

    private static func existsIn(_ root: URL) -> (String) -> Bool {
        { path in
            guard !path.hasPrefix("/"), !path.contains("..") else { return false }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    /// `file`, or the next `-2`, `-3`, … name when it exists by now.
    private static func freeFile(_ file: URL, root: URL) -> URL {
        guard FileManager.default.fileExists(atPath: file.path) else { return file }
        let base = file.deletingPathExtension().path
        var n = 2
        while FileManager.default.fileExists(atPath: "\(base)-\(n).md") { n += 1 }
        return URL(fileURLWithPath: "\(base)-\(n).md")
    }

    /// Attachments go to docs/research/assets/<doc-id>/ (DEC-009); returns their workspace paths.
    private static func copyAttachments(_ urls: [URL], root: URL, id: String) -> [String] {
        guard !urls.isEmpty else { return [] }
        let folder = root.appendingPathComponent("\(ResearchDocument.folder)/assets/\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return urls.compactMap { url in
            var target = folder.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(n).\(url.pathExtension)")
                n += 1
            }
            guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return nil }
            return relative(target, to: root)
        }
    }
}

/// What an agent run left behind: its text (the final answer, or what streamed before it
/// stopped), what it read, fetched and searched, and why it stopped early.
struct JobOutcome {
    var text: String
    var reads: [String]
    var urls: [String]
    var queries: [String]
    /// Why the run stopped early (cancel, timeout, error, no answer).
    var failure: String?
    /// The CLI refused web searches or fetches: the findings lack what they would have found.
    var webRefused: String? = nil

    /// Workspace-relative files read, in order, without duplicates or files outside the root.
    func filesRead(root: URL) -> [String] {
        var result: [String] = []
        let base = root.standardizedFileURL.path + "/"
        for path in reads {
            let full = path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL.path
                : root.appendingPathComponent(path).standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            let relative = String(full.dropFirst(base.count))
            if !result.contains(relative) { result.append(relative) }
        }
        return result
    }
}

/// A running job as its body sees it: progress updates and the agent run.
@MainActor
final class JobHandle {
    let id: UUID
    private weak var owner: ResearchJobs?

    init(id: UUID, owner: ResearchJobs) {
        self.id = id
        self.owner = owner
    }

    func update(_ step: String) { owner?.setStep(step, for: id) }

    /// Runs the agent over `root` with the research system prompt. Cancel, errors and the
    /// timeout end it early; the text streamed so far is kept (DEC-004, DEC-012).
    func run(prompt: String, root: URL, web: Bool) async -> JobOutcome {
        var request = CLICompletion.Request(prompt: prompt, systemPrompt: ResearchPrompt.system(web: web), readableFolder: root)
        request.allowWeb = web
        let minutes = ResearchSettings.timeoutMinutes
        request.timeout = TimeInterval(minutes * 60)
        let log = RunLog()
        let started = Date()
        update("Thinking")
        do {
            let result = try await CLICompletion.run(request, onDelta: { log.append(text: $0) }, onActivity: { [weak self] activity in
                guard let step = log.record(activity, root: root) else { return }
                Task { @MainActor in self?.update(step) }
            })
            result.record(in: owner?.workspace?.semanticDatabase)
            let snapshot = log.snapshot()
            let text = result.text.isEmpty ? snapshot.text : result.text
            // Refused web calls were never sent: they leave the lists, and the run lost web access (DEC-004).
            let refusedWeb = result.refused.filter { $0.tool == "WebSearch" || $0.tool == "WebFetch" }
            return JobOutcome(text: text, reads: snapshot.reads,
                              urls: snapshot.urls.filter { url in !refusedWeb.contains { $0.input == url } },
                              queries: snapshot.queries.filter { query in !refusedWeb.contains { $0.input == query } },
                              failure: text.isEmpty ? "the assistant returned no answer" : nil,
                              webRefused: refusedWeb.isEmpty ? nil
                                : "web access was refused (\(refusedWeb.count) search or fetch call\(refusedWeb.count == 1 ? "" : "s"))")
        } catch {
            let snapshot = log.snapshot()
            let elapsed = Int(Date().timeIntervalSince(started))
            let failure: String
            if error is CancellationError || Task.isCancelled {
                failure = "cancelled after \(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
            } else if case CLICompletion.Failure.timedOut = error {
                failure = "timed out after \(minutes) min"
            } else {
                failure = "the assistant stopped: \(error.localizedDescription)"
            }
            return JobOutcome(text: snapshot.text, reads: snapshot.reads, urls: snapshot.urls, queries: snapshot.queries, failure: failure)
        }
    }
}

/// Collects a run's streamed text and tool use from the CLI's background callbacks.
private final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var reads: [String] = []
    private var urls: [String] = []
    private var queries: [String] = []

    func append(text part: String) {
        lock.lock(); text += part; lock.unlock()
    }

    /// Records the activity; returns the progress line for it, if any.
    func record(_ activity: CLICompletion.Activity, root: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        let base = root.standardizedFileURL.path + "/"
        switch activity {
        case .read(let path):
            reads.append(path)
            return "Reading " + (path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path)
        case .search(let pattern):
            return "Searching “\(pattern.prefix(50))”"
        case .run(let command):
            return "Running " + String(command.prefix(60))
        case .webSearch(let query):
            if !queries.contains(query) { queries.append(query) }
            return "Searching the web: “\(query.prefix(60))”"
        case .webFetch(let url):
            if !urls.contains(url) { urls.append(url) }
            return "Reading " + String(url.prefix(70))
        case .thinking:
            return "Thinking"
        case .writing:
            return "Writing the report"
        case .answerDelta:
            return nil
        }
    }

    func snapshot() -> (text: String, reads: [String], urls: [String], queries: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (text, reads, urls, queries)
    }
}

/// The analysis scope (DEC-016): files git lists (tracked and untracked, honouring .gitignore),
/// without vendor/generated directories, lock and minified files, binary files and files over
/// 1 MB. Target documents and attachments are always in it.
enum ResearchScope {
    static let maxBytes = 1_000_000
    private static let generatedNames: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Podfile.lock",
                                                      "Cargo.lock", "Gemfile.lock", "composer.lock", "poetry.lock"]

    /// Explicit folder targets expand recursively into readable files, never directory
    /// paths. Resolve symlinks at the boundary so a target cannot read outside the workspace.
    static func targetFiles(root: URL, targets: [URL]) -> [String] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var paths = Set<String>()
        for target in targets {
            guard target.standardizedFileURL == root.standardizedFileURL || target.resolvingSymlinksInPath().path.hasPrefix(base) else { continue }
            if (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard let entries = FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let file as URL in entries {
                    guard file.resolvingSymlinksInPath().path.hasPrefix(base),
                          (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                          isText(file), let path = ResearchJobs.relative(file, to: root) else { continue }
                    paths.insert(path)
                }
            } else if let path = ResearchJobs.relative(target, to: root), isText(target) { paths.insert(path) }
        }
        return paths.sorted()
    }

    static func files(root: URL, always: [String]) -> [String] {
        var result = ArchitectureScanner.listFiles(root: root).filter { path in
            let name = (path as NSString).lastPathComponent
            if generatedNames.contains(name) || name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.hasSuffix(".map")
                || path.hasPrefix(ResearchDocument.folder + "/assets/") { return false }
            return isText(root.appendingPathComponent(path))
        }
        for path in always where !result.contains(path) { result.append(path) }
        return result
    }

    /// Readable text: at most 1 MB and no NUL byte in the first 8 KB.
    static func isText(_ url: URL) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        return !head.contains(0)
    }
}
