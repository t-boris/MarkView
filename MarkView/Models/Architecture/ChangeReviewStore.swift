import Foundation
import CryptoKit
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The Pull request X-Ray: which changes can be shown (this checkout, a branch or date comparison, a pull request on GitHub), the
/// change that is loaded with its files, links, per-file notes, AI analysis, review and chat, and what the person does with a review's
/// findings (explain, dismiss, comment, issue). It owns its state; what is shared with the rest of the X-Ray (the snapshot, the
/// status line, the error, the run flag, the assistant call, a file's outline and the revision the page re-renders on) it asks of
/// the host. Where the changes come from is `ChangeSource`, how a diff is read is `ChangeDiff`.
@MainActor
final class ChangeReviewStore {
    unowned let host: ArchitectureHost

    init(host: ArchitectureHost) {
        self.host = host
    }

    private(set) var prSources: [PRSource] = []
    private(set) var prOverlay: PROverlay?

    private(set) var historyPicker: HistoryPicker?
    /// Answers only the latest question: a day asked for while an earlier one is still being read wins.
    private var historyRequest = 0
    private var prLoadToken = 0

    /// Per-file diffs of the loaded change (kept here, sent only for the selected file).
    private var prFileDiffs: [String: String] = [:]
    private var prDiffText = ""
    /// The AI's explanations of changed files, by "<source>|<path>|<diff hash>".
    private var prExplanations: [String: (summary: String, notes: [PRChangeNote])] = [:]
    private var prExplaining: Set<String> = []
    /// Files opened from the PR X-Ray: their viewer starts on the "Pull request" lens.
    private var prFocusPaths: Set<String> = []
    /// For reloading the shown change when its files moved on (see `prFileNotes`).
    private var prRoot: URL?
    /// The fetched pull request being shown (nil for local changes or when not fetchable).
    private var prCheckout: PRCheckout?
    /// Commit the shown change starts from (the old side of its diff): removed files open
    /// in this version.
    private var prBase: String?
    /// The GitHub repository this window's integration selected (nil when it is off): its
    /// pull requests are listed and fetched. Without it `gh` picks the repository itself.
    var gitHubRepo: GitHubRepo?
    /// The repository the shown pull request was loaded from — its actions go there, even
    /// when the Git tab selects another repository afterwards.
    private var prRepo: GitHubRepo?
    private var prReloadedAt = Date.distantPast


    /// A new workspace: neither a commit list nor a change that is still being read may land in it.
    func reset() {
        historyRequest += 1
        historyPicker = nil
        prLoadToken += 1
        prSources = []
        prOverlay = nil
    }

    // MARK: - Pull request overlay

    /// Set when the PR X-Ray opens without a change chosen: show all local changes vs main.
    var selectDefaultSource = false

    func refreshPRSources(root: URL) {
        Task {
            let repo = gitHubRepo
            // Pull requests on GitHub need `gh`: only the opt-in integration may run it. The switch
            // is read here, on the main actor, once per refresh.
            let gitHub = GitHubSettings.enabled
            let sources = await Task.detached { ChangeSource.list(root: root, repo: repo, gitHub: gitHub) }.value
            // Comparisons the person asked for (a branch against this one, a commit of an earlier day) are not in
            // the list git builds.
            let comparisons = prSources.filter {
                (ChangeSource.comparison($0.id) != nil || HistoricalBaseline.commitHash(fromSourceId: $0.id) != nil) && !sources.contains($0)
            }
            prSources = sources + comparisons
            host.bump()
            if selectDefaultSource {
                selectDefaultSource = false
                if prOverlay == nil, let first = sources.first(where: { $0.id == "local" }) ?? sources.first {
                    showPR(first.id, root: root)
                }
            }
        }
    }

    /// Show a branch comparison in the PR view; `title` is what the source picker shows.
    func showComparison(id: String, title: String, root: URL, db: SemanticDatabase?) {
        if !prSources.contains(where: { $0.id == id }) { prSources.append(PRSource(id: id, title: title)) }
        showPR(id, root: root, db: db)
    }

    // MARK: Comparison by date

    /// The person chose a calendar day (`YYYY-MM-DD`) in the PR X-Ray's date picker: read the commits made that
    /// day on every local branch. A day asked for while an earlier one is still being read replaces it.
    func listHistory(day text: String, root: URL) {
        let calendar = Calendar.autoupdatingCurrent
        historyRequest += 1
        let request = historyRequest
        // The page sends valid days; one outside the calendar the history can have (before 1970) has no commits.
        guard let day = HistoricalBaseline.day(from: text, calendar: calendar) else {
            historyPicker = HistoryPicker(day: text, state: "ready", commits: [])
            host.bump()
            return
        }
        historyPicker = HistoryPicker(day: text, state: "loading", commits: [])
        host.bump()
        Task {
            let commits = await Task.detached {
                HistoricalBaseline.commits(on: day, calendar: calendar) {
                    ChangeSource.git($0, in: root)
                }
            }.value
            guard request == historyRequest else { return }
            historyPicker = HistoryPicker(day: text, state: commits == nil ? "unavailable" : "ready",
                                          commits: (commits ?? []).map {
                                              HistoryPicker.Entry(sha: $0.sha, short: $0.shortSha, subject: $0.subject,
                                                                  author: $0.author, time: $0.committed.timeIntervalSince1970)
                                          })
            host.bump()
        }
    }

    /// The person chose a commit of that day: show the working copy against it, like a branch comparison (no AI
    /// run until asked: Analyze and Review are buttons in the view).
    func compareWithCommit(sha: String, root: URL, db: SemanticDatabase?) {
        guard let id = HistoricalBaseline.sourceId(for: sha), let arguments = HistoricalBaseline.logArguments(forCommit: sha) else { return }
        let calendar = Calendar.autoupdatingCurrent
        Task {
            let commit = await Task.detached { () -> HistoricalBaseline.Commit? in
                ChangeSource.git(arguments, in: root)
                    .flatMap { HistoricalBaseline.parse($0).first }
            }.value
            guard let commit, commit.sha == sha else {
                host.setError("That commit is no longer in this repository.")
                host.bump()
                return
            }
            historyRequest += 1
            historyPicker = nil
            showComparison(id: id, title: HistoricalBaseline.title(for: commit, calendar: calendar), root: root, db: db)
        }
    }

    /// The change's version of `path`, written to MarkView's cache so the viewer shows the
    /// code under review (not the working copy): a fetched pull request's head, or — for a
    /// file the change removes — the version before it. Nil when the working copy is it.
    /// Runs `git show` off the main actor with a 15-second timeout (AR-06).
    func resolvePRFileURL(path: String) async -> URL? {
        guard let root = prRoot, !path.split(separator: "/").contains("..") else { return nil }
        let commit: String
        let cache: URL
        if prOverlay?.files.first(where: { $0.path == path })?.deleted == true, let base = prBase {
            commit = base
            cache = ChangeSource.cacheRoot(root: root, label: "base-" + base.prefix(10))
        } else if let checkout = prCheckout {
            commit = checkout.head
            cache = ChangeSource.cacheRoot(root: root, label: "PR-\(checkout.number)-\(checkout.head.prefix(10))")
        } else {
            return nil
        }
        return await ChangeSource.materialize(path: path, at: commit, into: cache, root: root)
    }

    /// Synchronous cache lookup for an already-materialized PR file URL (use `resolvePRFileURL` to fetch off the main actor).
    func prFileURL(path: String) -> URL? {
        guard let root = prRoot, !path.split(separator: "/").contains("..") else { return nil }
        let cache: URL
        if prOverlay?.files.first(where: { $0.path == path })?.deleted == true, let base = prBase {
            cache = ChangeSource.cacheRoot(root: root, label: "base-" + base.prefix(10))
        } else if let checkout = prCheckout {
            cache = ChangeSource.cacheRoot(root: root, label: "PR-\(checkout.number)-\(checkout.head.prefix(10))")
        } else {
            return nil
        }
        let file = cache.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Project-relative path of a file shown from the change's cache (see `prFileURL`), else nil.
    func prRelativePath(for url: URL) -> String? {
        guard let root = prRoot else { return nil }
        var labels: [String] = []
        if let checkout = prCheckout { labels.append("PR-\(checkout.number)-\(checkout.head.prefix(10))") }
        if let base = prBase { labels.append("base-" + base.prefix(10)) }
        let path = url.standardizedFileURL.path
        for label in labels {
            let base = ChangeSource.cacheRoot(root: root, label: label).standardizedFileURL.path + "/"
            if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
        }
        return nil
    }

    /// Show which files a change touches (no AI).
    /// Set by "Review" on a pull request: start the AI review as soon as it is loaded.
    var reviewWhenLoaded = false

    func showPR(_ sourceId: String, root: URL, db: SemanticDatabase? = nil) {
        // The wishes of the caller belong to this request: taken now, so that a failed or replaced load cannot leave
        // them behind for the next, unrelated one.
        let review = reviewWhenLoaded, analyze = analyzeWhenLoaded
        reviewWhenLoaded = false
        analyzeWhenLoaded = false
        // Any pull request by number, also one not in the list (older, merged, closed).
        if sourceId.hasPrefix("gh:"), !prSources.contains(where: { $0.id == sourceId }), Int(sourceId.dropFirst(3)) != nil {
            prSources.append(PRSource(id: sourceId, title: "#" + sourceId.dropFirst(3)))
        }
        guard let source = prSources.first(where: { $0.id == sourceId }) else {
            prOverlay = nil
            host.bump()
            return
        }
        host.setError(nil)
        Task {
            guard await loadPR(source, root: root) else { return }
            if review { reviewPR(root: root, db: db) }
            if analyze { analyzePR(root: root, db: nil) }
        }
    }

    /// Read the change as it is now: diff, files, links. Questions asked so far are kept
    /// when it is the change already shown.
    @discardableResult
    private func loadPR(_ source: PRSource, root: URL, keepReview: Bool = false) async -> Bool {
        // Loads can overlap (a comparison with an old commit takes seconds to read): the last one started is the one
        // that shows. A replaced load returns false without writing anything.
        prLoadToken += 1
        let token = prLoadToken
        prRoot = root
        host.setStatus("Loading \(source.title)…")
        // A reload keeps the repository the pull request came from.
        let repo = prOverlay?.source.id == source.id && prRepo != nil ? prRepo : gitHubRepo
        let gitHub = GitHubSettings.enabled
        let (diff, checkout, base) = await Task.detached { ChangeSource.read(source, root: root, repo: repo, gitHub: gitHub) }.value
        guard token == prLoadToken else { return false }
        guard let diff else {
            host.setError(HistoricalBaseline.commitHash(fromSourceId: source.id) != nil
                ? "Could not read the changes since that commit. It may no longer be in this repository."
                : !source.id.hasPrefix("gh:") ? "Could not read the changes from git."
                : gitHub ? "Could not load the pull request. Check that GitHub CLI (gh) is installed and signed in."
                : "Could not load the pull request: the GitHub integration is turned off in Settings.")
            host.setStatus(nil)
            return false
        }
        prCheckout = checkout
        prBase = base
        prRepo = source.id.hasPrefix("gh:") ? repo : nil
        let files = host.snapshot?.view("modules")?.nodes.filter { $0.kind == "file" }.compactMap(\.path) ?? []
        // A diff against an old commit can be tens of megabytes: read it off the main thread.
        let (dependencies, parsedFiles, fileDiffs) = await Task.detached { () -> ([PRDependency], [PRFileChange], [String: String]) in
            let dependencies = ArchitectureScanner.dependencyChanges(lines: ChangeDiff.lines(diff), projectFiles: files)
                .map { PRDependency(source: $0.source, target: $0.target, change: $0.added ? "added" : "removed") }
            return (dependencies, ChangeDiff.files(diff), ChangeDiff.split(diff))
        }.value
        guard token == prLoadToken else { return false }
        let previous = prOverlay?.source.id == source.id ? prOverlay : nil
        let changed = diff != prDiffText
        prDiffText = diff
        prFileDiffs = fileDiffs
        var overlay = PROverlay(source: source, files: parsedFiles, reviewed: false, dependencies: dependencies)
        overlay.chat = previous?.chat ?? []
        // A reload after the code changed keeps the review, marked outdated.
        if keepReview, let previous {
            let reviewed = Dictionary(previous.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            for i in overlay.files.indices {
                guard let old = reviewed[overlay.files[i].path] else { continue }
                overlay.files[i].verdict = old.verdict
                overlay.files[i].risk = old.risk
                overlay.files[i].summary = old.summary
                overlay.files[i].findings = old.findings
            }
            overlay.reviewed = previous.reviewed
            overlay.reviewSummary = previous.reviewSummary
            overlay.analysis = previous.analysis
            if changed && (previous.reviewed || previous.analysis != nil) { overlay.reviewOutdated = true }
            else { overlay.reviewOutdated = previous.reviewOutdated }
        }
        if let previous, previous.info != nil { overlay.info = previous.info }
        prOverlay = overlay
        host.setStatus(nil)
        if source.id.hasPrefix("gh:"), let number = Int(source.id.dropFirst(3)) { loadPRInfo(number, root: root) }
        return true
    }

    /// The code changed, or the review should be redone: read the change again, then
    /// review it (and repeat the architectural analysis if there was one) without the
    /// cached answers.
    func reviewAgain(root: URL, db: SemanticDatabase?) {
        guard !host.isBusy, let source = prOverlay?.source else { return }
        let hadAnalysis = prOverlay?.analysis != nil
        Task {
            guard await loadPR(source, root: root) else { return }
            reviewPR(root: root, db: db, fresh: true)
            if hadAnalysis { analyzePR(root: root, db: db, fresh: true) }
        }
    }

    /// The review's findings and the analysis's checks as a task list — to paste into the
    /// AI terminal or the clipboard. Nil when there is nothing to do.
    func prTasksText() -> String? { prOverlay?.tasksText() }

    /// Show one changed file's diff in the PR X-Ray.
    func showFileDiff(path: String) {
        guard prOverlay != nil else { return }
        prOverlay?.fileDiff = PRFileDiff(path: path, text: prFileDiffs[path] ?? "")
        host.bump()
    }

    // MARK: Changes inside a file

    func markPRFocus(path: String) {
        prFocusPaths.insert(path)
    }

    func prFileNotes(path: String, content: String) -> PRFileNotes? {
        guard let overlay = prOverlay.map(withChangeNotes),
              let file = overlay.files.first(where: { $0.path == path }) else { return nil }
        let notes = ChangeDiff.fileNotes(overlay: overlay, file: file, diff: prFileDiffs[path] ?? "", content: content,
                                         focus: prFocusPaths.contains(path))
        // Local changes moved on (new commits, edits): read them again, at most every 10 s.
        if file.deleted != true, notes.remapped,
           overlay.source.id == "local" || HistoricalBaseline.commitHash(fromSourceId: overlay.source.id) != nil, let root = prRoot,
           Date().timeIntervalSince(prReloadedAt) > 10 {
            prReloadedAt = Date()
            let source = overlay.source
            Task { await loadPR(source, root: root, keepReview: true) }
        }
        return notes
    }

    private func explanationKey(_ source: PRSource, _ path: String) -> String {
        source.id + "|" + path + "|" + String(ContentHash.of(prFileDiffs[path] ?? "").prefix(16))
    }

    /// The overlay with what changed inside each file: the AI's explanation when there is
    /// one, else the touched lines placed in the file's X-Ray parts and items.
    func withChangeNotes(_ overlay: PROverlay) -> PROverlay {
        var next = overlay
        for i in next.files.indices {
            let path = next.files[i].path
            let key = explanationKey(overlay.source, path)
            let spans = ChangeDiff.itemSpans(host.outline(for: path))
            if let explained = prExplanations[key] {
                next.files[i].changeSummary = explained.summary
                next.files[i].changes = explained.notes.map { note in
                    var note = note
                    if note.part?.isEmpty != false { note.part = ChangeDiff.part(at: note.start, in: spans) }
                    return note
                }
            } else {
                next.files[i].changes = ChangeDiff.changeNotes(hunks: ChangeDiff.changedRanges(prFileDiffs[path] ?? ""), spans: spans)
            }
            next.files[i].explaining = prExplaining.contains(key) ? true : nil
        }
        return next
    }

    /// The AI's reading of one file's change — only what changed, split into its logical
    /// changes with what each does and why. The diff and the file's X-Ray parts are the
    /// whole input (no file reading); cached by the diff.
    func explainPRFile(path: String, root: URL, db: SemanticDatabase?) {
        guard let overlay = prOverlay, let diff = prFileDiffs[path], !diff.isEmpty else { return }
        let key = explanationKey(overlay.source, path)
        guard prExplanations[key] == nil, !prExplaining.contains(key) else { return }
        prExplaining.insert(key)
        host.bump()
        let spans = ChangeDiff.itemSpans(host.outline(for: path))
        var parts: [(name: String, start: Int, end: Int)] = []
        for span in spans {
            if let last = parts.last, last.name == span.part {
                parts[parts.count - 1].end = span.end == Int.max ? span.start : span.end
            } else {
                parts.append((span.part, span.start, span.end == Int.max ? span.start : span.end))
            }
        }
        var prompt = "Change: \(overlay.source.title)\nFile: \(path)\n"
        if !parts.isEmpty {
            prompt += "\nParts of the file (new line numbers):\n"
                + parts.map { "- \($0.name): lines \($0.start)–\($0.end)" }.joined(separator: "\n") + "\n"
        }
        prompt += "\nDiff (new-file line numbers on the left):\n" + ChangeDiff.numbered(diff)
        let outputLanguage = ActionOutputLanguage.current
        var request = CLICompletion.Request(
            project: host.project,
            prompt: prompt,
            systemPrompt: """
            You explain one file's part of a code change (a pull request) to a reviewer who is looking \
            at that file inside an architecture diagram. Explain ONLY what changed — never describe what \
            the file does in general. Split the diff into its logical changes (usually one per touched \
            function, type, section or item; merge hunks that belong to one change; 1-15 changes). For \
            each: a short title naming what changed ("Retry on timeout in fetchOrders"); its kind \
            (added, changed, removed or moved); the new-file lines it covers (startLine and endLine from \
            the numbers on the left; for a pure removal, the line where the text was); the part of the \
            file it belongs to when parts are listed (the exact part name); and why: what the change does \
            and why it was probably made, in one or two sentences. Also give a summary of the whole \
            file's change in one or two sentences.
            \(XRayContent.languageLine(summaries: outputLanguage == ActionOutputLanguage.documentLanguage
                                                   ? "the language of the file" : outputLanguage))
            """,
            jsonSchema: [
                "type": "object",
                "properties": [
                    "summary": ["type": "string"],
                    "changes": ["type": "array", "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "kind": ["type": "string", "enum": ["added", "changed", "removed", "moved"]],
                            "startLine": ["type": "integer"],
                            "endLine": ["type": "integer"],
                            "part": ["type": "string"],
                            "why": ["type": "string"],
                        ],
                        "required": ["title", "kind", "startLine", "endLine", "why"],
                    ]],
                ],
                "required": ["summary", "changes"],
            ])
        request.timeout = 300
        Task {
            defer { prExplaining.remove(key); host.bump() }
            do {
                let object = try await host.assistantCall(request, root: root, db: db, call: 98, fresh: false)
                let partNames = Set(parts.map(\.name))
                let notes = (object["changes"] as? [[String: Any]] ?? []).compactMap { raw -> PRChangeNote? in
                    guard let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
                    let start = max(1, raw["startLine"] as? Int ?? 1)
                    let end = max(start, raw["endLine"] as? Int ?? start)
                    let part = (raw["part"] as? String).flatMap { partNames.contains($0) ? $0 : nil }
                    return PRChangeNote(part: part, title: title, start: start, end: end,
                                        kind: raw["kind"] as? String, why: raw["why"] as? String)
                }
                guard !notes.isEmpty else { return }
                prExplanations[key] = (object["summary"] as? String ?? "", notes.sorted { $0.start < $1.start })
            } catch is CancellationError {
            } catch {
                host.setError("Could not explain the changes in \((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Ask the AI about the loaded change — the whole of it, or one file — with the
    /// analysis and the diff as context. The answer streams into the chat.
    func askPR(question: String, path: String?, root: URL, db: SemanticDatabase?) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let overlay = prOverlay, !question.isEmpty else { return }
        let index = overlay.chat.count
        prOverlay?.chat.append(PRChat(question: question, path: path, answer: "", pending: true))
        host.bump()
        var context = "Change: \(overlay.source.title)\n"
        if let a = overlay.analysis {
            context += "Architectural review: \(a.summary)\nRisks:\n" + a.risks.map { "- " + $0 }.joined(separator: "\n") + "\n"
        }
        let earlier = overlay.chat.suffix(4).map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
        if !earlier.isEmpty { context += "\nEarlier questions:\n" + earlier + "\n" }
        let diff = path.flatMap { prFileDiffs[$0] }.map { "Diff of \(path!):\n" + $0 } ?? prDiffText
        let clipped = diff.count > 120_000 ? String(diff.prefix(120_000)) + "\n[diff truncated]" : diff
        var request = CLICompletion.Request(
            project: host.project,
            prompt: context + "\n```diff\n" + clipped + "\n```\n\nQuestion: " + question,
            systemPrompt: """
            You are a senior engineer and architect answering a reviewer's question about a pull request. Answer \
            directly and concretely from the diff: name files, functions and lines; say when the diff does not \
            show enough to be sure. Short paragraphs or a few bullets; plain text, no headings.
            """ + "\n\n" + ActionOutputLanguage.explanationLine())
        request.model = request.xrayModel
        request.effort = "low"
        request.timeout = 300
        let source = overlay.source.id
        Task {
            var streamed = ""
            var pendingRefresh = false
            do {
                let (answer, result) = try await AIOperation<CLICompletion.Request, String>.text(name: "xray-pr-question").execute(request, onDelta: { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.prOverlay?.source.id == source, index < (self.prOverlay?.chat.count ?? 0) else { return }
                        streamed += text
                        self.prOverlay?.chat[index].answer = streamed
                        guard !pendingRefresh else { return }
                        pendingRefresh = true
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        pendingRefresh = false
                        self.host.bump()
                    }
                })
                result.record(in: db)
                if prOverlay?.source.id == source, index < (prOverlay?.chat.count ?? 0) {
                    prOverlay?.chat[index].answer = answer.isEmpty ? streamed : answer
                }
            } catch is CancellationError {
            } catch {
                if prOverlay?.source.id == source, index < (prOverlay?.chat.count ?? 0) {
                    prOverlay?.chat[index].answer = "Failed: \(error.localizedDescription)"
                }
            }
            if prOverlay?.source.id == source, index < (prOverlay?.chat.count ?? 0) { prOverlay?.chat[index].pending = false }
            host.bump()
        }
    }

    /// Set by the PR X-Ray tab: analyse the change as soon as it is loaded.
    var analyzeWhenLoaded = false

    /// The AI's architectural reading of the loaded change: what it does, which components
    /// it touches and how risky that is, new or broken links between parts, and what to
    /// check. One pass over the diff and the X-Ray's structure (no file reading), cached.
    func analyzePR(root: URL, db: SemanticDatabase?, fresh: Bool = false) {
        guard var overlay = prOverlay, overlay.analyzing != true else { return }
        overlay.analyzing = true
        prOverlay = overlay
        host.bump()
        let source = overlay.source
        let current = host.snapshot
        Task {
            defer { prOverlay?.analyzing = nil; host.bump(); host.setStatus(nil) }
            host.setStatus("Analysing \(source.title)…")
            let repo = prRepo ?? gitHubRepo
            let gitHub = GitHubSettings.enabled
            let diff = await Task.detached { ChangeSource.diff(for: source, root: root, repo: repo, gitHub: gitHub) }.value ?? ""
            // Which component each changed file belongs to, from the X-Ray.
            let fileNodes = Dictionary((current?.view("modules")?.nodes ?? []).filter { $0.kind == "file" }
                .compactMap { node in node.path.map { ($0, node) } }, uniquingKeysWith: { a, _ in a })
            let components = Dictionary((current?.components ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // New files are not in the X-Ray yet: they belong to their nearest known folder's component.
            func component(of path: String) -> String {
                if let known = fileNodes[path]?.component { return known }
                var folder = (path as NSString).deletingLastPathComponent
                while true {
                    if let assigned = current?.overrides[folder] ?? current?.assignments[folder]?.component { return assigned }
                    if folder.isEmpty { return "" }
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
            var byComponent: [String: [PRFileChange]] = [:]
            for file in overlay.files { byComponent[component(of: file.path), default: []].append(file) }
            let touched = byComponent.sorted { $0.key < $1.key }.map { id, files -> String in
                let name = components[id].map { "\($0.name) [\(id)] — \($0.purpose)" } ?? "(no component)"
                return "- \(name)\n" + files.map { "    \($0.path) +\($0.additions) −\($0.deletions)" }.joined(separator: "\n")
            }.joined(separator: "\n")
            let links = overlay.dependencies.map { "- \($0.change): \($0.source) → \($0.target)" }.joined(separator: "\n")
            let limit = 120_000
            let clipped = diff.count > limit ? String(diff.prefix(limit)) + "\n[diff truncated]" : diff
            let schema: [String: Any] = [
                "type": "object",
                "properties": [
                    "summary": ["type": "string", "description": "2-3 sentences: what the change does and why it matters architecturally."],
                    "verdict": ["type": "string", "enum": ["approve", "attention", "risky"]],
                    "impact": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "component": ["type": "string", "description": "Component id in brackets from the list, or empty."],
                                "risk": ["type": "string", "enum": ["low", "medium", "high"]],
                                "note": ["type": "string", "description": "At most 20 words: how the change affects this component."],
                            ],
                            "required": ["component", "risk", "note"],
                        ],
                    ],
                    "risks": ["type": "array", "items": ["type": "string"], "description": "Architectural risks: new coupling, broken layering, contract/API/schema changes, deployment impact."],
                    "checks": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string"],
                                "line": ["type": "integer", "description": "Line in the new file, or 0."],
                                "note": ["type": "string", "description": "What to check there, at most 15 words."],
                            ],
                            "required": ["path", "line", "note"],
                        ],
                    ],
                ],
                "required": ["summary", "verdict", "impact", "risks", "checks"],
            ]
            var request = CLICompletion.Request(
                project: host.project,
                prompt: """
                System: \(current?.systemName ?? root.lastPathComponent) — \(current?.systemPurpose ?? "")
                Change: \(source.title)

                Components touched (files +added −removed):
                \(touched)

                Dependencies added or removed:
                \(links.isEmpty ? "(none found)" : links)

                ```diff
                \(clipped)
                ```
                """,
                systemPrompt: """
                You are a software architect reviewing a pull request for its effect on the system's architecture, \
                not code style. Say what the change does, how each touched component is affected and how risky that \
                is, which architectural risks it brings (new coupling between components or layers, broken \
                boundaries, changed contracts, APIs, schemas or events, deployment or migration impact), and the few \
                places a reviewer must check. Work only from what is given. Be concise.
                """ + "\n\n" + ArchitectureStore.graphLanguageLine,
                jsonSchema: schema)
            request.timeout = 300
            do {
                let object = try await host.assistantCall(request, root: root, db: db, call: 0, fresh: fresh)
                let analysis = PRAnalysis(
                    summary: object["summary"] as? String ?? "",
                    verdict: object["verdict"] as? String ?? "attention",
                    impact: (object["impact"] as? [[String: Any]] ?? []).map {
                        .init(component: ($0["component"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[] ")),
                              risk: $0["risk"] as? String ?? "low", note: $0["note"] as? String ?? "")
                    },
                    risks: object["risks"] as? [String] ?? [],
                    checks: (object["checks"] as? [[String: Any]] ?? []).compactMap { raw in
                        guard let path = raw["path"] as? String else { return nil }
                        return .init(path: path.hasPrefix("b/") ? String(path.dropFirst(2)) : path,
                                     line: raw["line"] as? Int ?? 0, note: raw["note"] as? String ?? "")
                    })
                if prOverlay?.source.id == source.id { prOverlay?.analysis = analysis }
            } catch is CancellationError {
            } catch {
                host.setError("PR analysis failed: \(error.localizedDescription)")
            }
        }
    }

    /// Ask the assistant to review the loaded change file by file.
    func reviewPR(root: URL, db: SemanticDatabase?, fresh: Bool = false) {
        guard !host.isBusy, let overlay = prOverlay else { return }
        let token = host.beginRun()
        let source = overlay.source
        Task {
            defer { host.endRun(token) }
            host.setStatus("Reviewing \(source.title)…")
            let repo = prRepo ?? gitHubRepo
            let gitHub = GitHubSettings.enabled
            let diff = await Task.detached { ChangeSource.diff(for: source, root: root, repo: repo, gitHub: gitHub) }.value ?? ""
            let key = SHA256.hash(data: Data(diff.utf8)).map { String(format: "%02x", $0) }.joined()
            reviewKey = (key, db)
            if !fresh, let cached = await db?.loadArchitectureReview(key: key),
               let data = cached.data(using: .utf8),
               var reviewed = try? JSONDecoder().decode(PROverlay.self, from: data) {
                reviewed.info = prOverlay?.info
                prOverlay = reviewed
                host.setStatus(nil)
                return
            }
            let limit = 200_000
            let clipped = diff.count > limit ? String(diff.prefix(limit)) + "\n[diff truncated]" : diff
            let schema: [String: Any] = [
                "type": "object",
                "properties": [
                    "summary": ["type": "string", "description": "2-3 sentences on what the change does and its overall risk."],
                    "files": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string"],
                                "verdict": ["type": "string", "enum": ["ok", "concern", "bug"]],
                                "risk": ["type": "string", "enum": ["low", "medium", "high"]],
                                "summary": ["type": "string"],
                                "findings": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "line": ["type": "integer", "description": "Line number in the new version of the file."],
                                            "severity": ["type": "string", "enum": ["info", "warning", "bug"]],
                                            "message": ["type": "string"],
                                        ],
                                        "required": ["line", "severity", "message"],
                                    ],
                                ],
                            ],
                            "required": ["path", "verdict", "risk", "summary", "findings"],
                        ],
                    ],
                ],
                "required": ["summary", "files"],
            ]
            var request = CLICompletion.Request(
                project: host.project,
                prompt: "Change: \(source.title)\n\n```diff\n\(clipped)\n```",
                systemPrompt: """
                You are a senior engineer reviewing a code change. For every changed file judge whether the change \
                is correct and complete: verdict ok (no problems), concern (questionable design, missing handling, \
                risky), or bug (a defect that will misbehave). Report concrete findings with the line number in the \
                new file. Work only from the diff. Do not report style nits; keep messages short.
                """ + "\n\n" + ArchitectureStore.graphLanguageLine,
                jsonSchema: schema)
            request.model = request.xrayModel
            request.effort = "low"
            request.timeout = 600
            do {
                let (object, result) = try await AIOperation<CLICompletion.Request, [String: Any]>.object(name: "xray-pr-review").execute(request)
                result.record(in: db)
                var byPath: [String: [String: Any]] = [:]
                for item in object["files"] as? [[String: Any]] ?? [] {
                    if let path = item["path"] as? String { byPath[path.hasPrefix("b/") ? String(path.dropFirst(2)) : path] = item }
                }
                var next = prOverlay ?? overlay
                for i in next.files.indices {
                    guard let item = byPath[next.files[i].path] else { continue }
                    next.files[i].verdict = item["verdict"] as? String
                    next.files[i].risk = item["risk"] as? String
                    next.files[i].summary = item["summary"] as? String
                    next.files[i].findings = (item["findings"] as? [[String: Any]] ?? []).compactMap { finding in
                        guard let message = finding["message"] as? String else { return nil }
                        return PRFinding(line: finding["line"] as? Int ?? 0,
                                         severity: finding["severity"] as? String ?? "info", message: message)
                    }
                }
                next.reviewed = true
                next.reviewSummary = object["summary"] as? String
                prOverlay = next
                if let data = try? JSONEncoder().encode(next) {
                    saveReview(key: key, json: String(decoding: data, as: UTF8.self), db: db)
                }
            } catch is CancellationError {
            } catch {
                host.setError("Review failed: \(error.localizedDescription)")
            }
            host.setStatus(nil)
        }
    }

    // MARK: - Pull request on GitHub: header and finding actions

    /// Cache key of the review shown, to save the reviewer's marks on its findings.
    private var reviewKey: (key: String, db: SemanticDatabase?)?

    private func saveReviewMarks() {
        guard let (key, db) = reviewKey, var overlay = prOverlay, overlay.reviewed else { return }
        // Only what lasts: no work in progress, no GitHub state (loaded fresh each time).
        overlay.info = nil
        overlay.analyzing = nil
        overlay.fileDiff = nil
        for f in overlay.files.indices {
            overlay.files[f].explaining = nil
            for i in (overlay.files[f].findings ?? []).indices { overlay.files[f].findings?[i].explaining = nil }
        }
        guard let data = try? JSONEncoder().encode(overlay) else { return }
        saveReview(key: key, json: String(decoding: data, as: UTF8.self), db: db)
    }

    /// The review save in flight: marks reach the database in the order they were made.
    private var reviewSave: Task<Void, Never>?

    private func saveReview(key: String, json: String, db: SemanticDatabase?) {
        guard let db else { return }
        let previous = reviewSave
        reviewSave = Task {
            await previous?.value
            await db.saveArchitectureReview(key: key, json: json)
        }
    }

    /// The shown pull request's repository; for local changes, the selected one (issues).
    private func githubClient(root: URL) -> GitHubClient? {
        (prRepo ?? gitHubRepo).map { GitHubClient(root: root, repo: $0) }
    }

    /// The pull request number of the change shown, when it is one on GitHub.
    var shownPRNumber: Int? {
        guard let id = prOverlay?.source.id, id.hasPrefix("gh:") else { return nil }
        return Int(id.dropFirst(3))
    }

    /// State, checks and review decision of pull request `number`, for the panel's header.
    func loadPRInfo(_ number: Int, root: URL) {
        guard let client = githubClient(root: root) else { return }
        Task {
            guard let pr = try? await client.pullRequest(number), shownPRNumber == number else { return }
            let checks = pr.checks
            let info = PRInfo(number: number, url: pr.url, state: pr.state, isDraft: pr.isDraft ?? false,
                              author: pr.author?.login ?? "", head: pr.headRefName, base: pr.baseRefName,
                              reviewDecision: pr.reviewDecision ?? "", checksPassed: pr.passedChecks,
                              checksFailed: checks.filter { $0.outcome == .failure }.count, checksTotal: checks.count,
                              mergeable: pr.mergeable ?? "UNKNOWN", headOid: pr.headRefOid ?? prCheckout?.head ?? "",
                              busy: nil, message: prOverlay?.info?.message, ok: prOverlay?.info?.ok)
            prOverlay?.info = info
            host.bump()
        }
    }

    /// Approve, request changes, comment, merge or close the pull request shown.
    func prAction(_ action: String, body: String, method: String, root: URL) {
        guard let number = shownPRNumber, let client = githubClient(root: root), prOverlay?.info?.busy != true else { return }
        prOverlay?.info?.busy = true
        prOverlay?.info?.message = nil
        prOverlay?.info?.ok = nil
        host.bump()
        Task {
            var message: String
            var ok = true
            do {
                switch action {
                case "approve":
                    try await client.review(number, action: "approve", body: body); message = "Approved."
                case "requestChanges":
                    try await client.review(number, action: "request-changes", body: body); message = "Changes requested."
                case "comment":
                    try await client.commentPR(number, body: body); message = "Comment posted."
                case "merge":
                    try await client.merge(number, method: method); message = "Merged (\(method))."
                case "close":
                    try await client.closePR(number); message = "Closed."
                default: message = ""
                }
            } catch { message = error.localizedDescription; ok = false }
            guard shownPRNumber == number else { return }
            prOverlay?.info?.busy = nil
            prOverlay?.info?.message = message
            prOverlay?.info?.ok = ok
            host.bump()
            loadPRInfo(number, root: root)
        }
    }

    private func findingIndex(path: String, index: Int) -> (Int, Int)? {
        guard let f = prOverlay?.files.firstIndex(where: { $0.path == path }),
              let findings = prOverlay?.files[f].findings, findings.indices.contains(index) else { return nil }
        return (f, index)
    }

    /// The prompt that asks the AI terminal to fix one finding.
    func findingFixPrompt(path: String, index: Int) -> String? {
        guard let (f, i) = findingIndex(path: path, index: index), let overlay = prOverlay,
              let finding = overlay.files[f].findings?[i] else { return nil }
        var prompt = "Fix this problem found by the review of \(overlay.source.title):\n\n"
        prompt += "\(path)\(finding.line > 0 ? ":\(finding.line)" : "") (\(finding.severity)) — \(finding.message)\n"
        if let explanation = finding.explanation, !explanation.isEmpty { prompt += "\nExplanation:\n\(explanation)\n" }
        prompt += "\nCheck that it is a real problem first; if it is not, say why and change nothing. Keep the fix focused."
        return prompt
    }

    func dismissFinding(path: String, index: Int) {
        guard let (f, i) = findingIndex(path: path, index: index) else { return }
        let dismissed = prOverlay?.files[f].findings?[i].dismissed == true
        prOverlay?.files[f].findings?[i].dismissed = dismissed ? nil : true
        host.bump()
        saveReviewMarks()
    }

    private func updateFinding(source: String, path: String, index: Int, _ change: (inout PRFinding) -> Void) {
        guard prOverlay?.source.id == source, let (f, i) = findingIndex(path: path, index: index),
              var finding = prOverlay?.files[f].findings?[i] else { return }
        change(&finding)
        prOverlay?.files[f].findings?[i] = finding
    }

    /// Explain one finding inline: why it is a problem and how to fix it (streamed).
    func explainFinding(path: String, index: Int, db: SemanticDatabase?) {
        guard let (f, i) = findingIndex(path: path, index: index), let overlay = prOverlay,
              let finding = overlay.files[f].findings?[i], finding.explaining != true else { return }
        prOverlay?.files[f].findings?[i].explaining = true
        prOverlay?.files[f].findings?[i].explanation = ""
        host.bump()
        let diff = prFileDiffs[path] ?? ""
        let clipped = diff.count > 60_000 ? String(diff.prefix(60_000)) + "\n[diff truncated]" : diff
        var request = CLICompletion.Request(
            project: host.project,
            prompt: "Change: \(overlay.source.title)\nFinding in \(path) line \(finding.line) (\(finding.severity)): \(finding.message)\n\n```diff\n\(clipped)\n```",
            systemPrompt: """
            You are a senior engineer explaining one code review finding to the author. Say concretely why it is \
            (or is not) a problem, what input or situation triggers it, and the smallest fix, quoting the code. \
            Short paragraphs or bullets; plain text, no headings.
            """ + "\n\n" + ActionOutputLanguage.explanationLine())
        request.model = request.xrayModel
        request.effort = "low"
        request.timeout = 300
        let source = overlay.source.id
        Task {
            var streamed = ""
            var pendingRefresh = false
            do {
                let (answer, result) = try await AIOperation<CLICompletion.Request, String>.text(name: "xray-finding").execute(request, onDelta: { text in
                    Task { @MainActor in
                        streamed += text
                        self.updateFinding(source: source, path: path, index: index) { $0.explanation = streamed }
                        guard !pendingRefresh else { return }
                        pendingRefresh = true
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        pendingRefresh = false
                        self.host.bump()
                    }
                })
                result.record(in: db)
                let text = answer.isEmpty ? streamed : answer
                updateFinding(source: source, path: path, index: index) { $0.explanation = text }
            } catch is CancellationError {
            } catch {
                let message = "Failed: \(error.localizedDescription)"
                updateFinding(source: source, path: path, index: index) { $0.explanation = message }
            }
            updateFinding(source: source, path: path, index: index) { $0.explaining = nil }
            host.bump()
            saveReviewMarks()
        }
    }

    /// Post a finding to the pull request as a comment on its line.
    func commentFinding(path: String, index: Int, root: URL) {
        guard let number = shownPRNumber, let client = githubClient(root: root),
              let (f, i) = findingIndex(path: path, index: index), let finding = prOverlay?.files[f].findings?[i],
              let commit = prOverlay?.info?.headOid ?? prCheckout?.head, !commit.isEmpty else {
            host.setError("Only a pull request fetched from GitHub can get line comments.")
            host.bump()
            return
        }
        var body = "**\(finding.severity.capitalized):** \(finding.message)"
        if let explanation = finding.explanation, !explanation.isEmpty { body += "\n\n" + explanation }
        let source = prOverlay?.source.id ?? ""
        Task {
            do {
                if finding.line > 0 {
                    try await client.lineComment(number, commit: commit, path: path, line: finding.line, body: body)
                } else {
                    try await client.commentPR(number, body: "`\(path)`: " + body)
                }
                updateFinding(source: source, path: path, index: index) { $0.commented = true }
                saveReviewMarks()
            } catch {
                host.setError("Comment failed: \(error.localizedDescription)")
            }
            host.bump()
        }
    }

    /// Create a GitHub issue from a finding.
    func issueFromFinding(path: String, index: Int, root: URL) {
        guard let client = githubClient(root: root), let overlay = prOverlay,
              let (f, i) = findingIndex(path: path, index: index), let finding = overlay.files[f].findings?[i] else {
            host.setError("No GitHub repository for this folder.")
            host.bump()
            return
        }
        let title = String(finding.message.prefix(90))
        var body = "Found by the review of \(overlay.source.title)"
        if let url = overlay.info?.url { body += " (\(url))" }
        body += ".\n\n`\(path)\(finding.line > 0 ? ":\(finding.line)" : "")` — \(finding.severity)\n\n\(finding.message)"
        if let explanation = finding.explanation, !explanation.isEmpty { body += "\n\n" + explanation }
        let source = overlay.source.id
        Task {
            do {
                let url = try await client.createIssue(title: title, body: body)
                updateFinding(source: source, path: path, index: index) { $0.issueURL = url }
                saveReviewMarks()
            } catch {
                host.setError("Issue failed: \(error.localizedDescription)")
            }
            host.bump()
        }
    }
}
