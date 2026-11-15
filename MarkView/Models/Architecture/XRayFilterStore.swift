import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The filters of the X-Ray: the importance rating and the person's own filters (a criterion rated over the project as the person
/// zooms in), the quick search ("Search with AI"), and the answers of "I need to understand": their state while the assistant works,
/// their ratings and sources, the notes the code viewer shows for a search, and what is saved from them. It owns that state; what is
/// shared with the rest of the X-Ray (the snapshot and where it is committed, the status line, the error, the project and the answer
/// cache) it asks of the host.
@MainActor
final class XRayFilterStore {
    unowned let host: ArchitectureHost

    init(host: ArchitectureHost) {
        self.host = host
    }

    /// Containers whose children are being rated for importance, and filters being searched.
    private var rating: Set<String> = []

    /// A new workspace: answers, ratings and live text of the old one are dropped and their jobs stopped. The window's one-off filter,
    /// the code elements of a search and the filter to switch to belong to the window, not to the workspace, and stay.
    func reset() {
        clearUnderstandingAttachments()
        understandingTasks.values.forEach { $0.cancel() }
        understandingTasks = [:]
        understandingTokens = [:]
        understandingAnswers = [:]
        understandingInputAttachments = [:]
        understandingRatings = [:]
        searchAnswers = [:]
        searchSummaries = [:]
        liveSearch = [:]
    }

    // MARK: - Importance

    /// Drop ratings of files and folders whose content changed since they were rated.
    nonisolated static func keepCurrentRatings(_ ratings: [String: ImportanceRater.Rating],
                                               modules: ArchView) -> [String: ImportanceRater.Rating] {
        let signatures = Dictionary(modules.nodes.compactMap { node in node.path.map { ("p:" + $0, node.signature) } },
                                    uniquingKeysWith: { a, _ in a })
        return ratings.filter { key, rating in
            guard key.hasPrefix("p:"), let current = signatures[key] else { return true }
            return rating.signature == nil || rating.signature == current
        }
    }

    /// Rate the children of `parentId` (components, folders, files, documents or
    /// document sections) with the AI. Called as the user zooms in with the
    /// Importance overlay on.
    func rateImportance(viewId: String, parentId: String, filterId: String, root: URL, db: SemanticDatabase?) {
        guard let current = host.snapshot, let view = current.view(viewId),
              let filter = allFilters.first(where: { $0.id == filterId }),
              !rating.contains(filterId + "|" + viewId + "|" + parentId) else { return }
        let existing = current.ratings[filterId] ?? [:]
        let byId = Dictionary(view.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let children = view.nodes.filter { $0.parent == parentId }
        guard !children.isEmpty else { return }

        // Fan-in from the Structure view's file edges, as a hint for code.
        var usedBy: [String: Int] = [:]
        if let modules = current.view("modules") {
            for edge in modules.edges where edge.source.hasPrefix("m:") { usedBy[edge.target, default: 0] += 1 }
        }
        var documentText: [String: String] = [:]
        func text(of path: String) -> String {
            if let cached = documentText[path] { return cached }
            let value = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
            documentText[path] = value
            return value
        }

        var items: [ImportanceRater.Item] = []
        var signatures: [String: String] = [:]
        for node in children {
            switch node.kind {
            case "component":
                let key = "c:" + node.id.replacingOccurrences(of: "l:c:", with: "")
                items.append(.init(key: key, label: node.name,
                                   detail: "Component: \(node.summary ?? "") (\(node.files) files, \(node.loc) lines)"))
            case "dir", "package", "file":
                guard let path = node.path else { continue }
                let fanIn = node.kind == "file" ? usedBy["m:" + path] ?? 0 : 0
                var detail = "\(node.kind == "file" ? "File" : "Folder") \(path), \(node.loc) lines"
                if node.kind != "file" { detail += ", \(node.files) files" }
                if fanIn > 0 { detail += ", imported by \(fanIn) files" }
                if let summary = node.summary { detail += "\nWhat it does: " + summary }
                if let tags = node.tags, !tags.isEmpty { detail += "\nTags: " + tags.joined(separator: ", ") }
                items.append(.init(key: "p:" + path, label: node.name, detail: detail))
                if let signature = node.signature { signatures["p:" + path] = signature }
            case "doc":
                guard let path = node.path else { continue }
                let body = text(of: path)
                items.append(.init(key: "p:" + path, label: node.name,
                                   detail: "Document \(path), \(node.loc) lines\n" + String(body.prefix(700))))
            case "section":
                guard let path = node.path, let line = node.line else { continue }
                items.append(.init(key: node.id, label: node.name,
                                   detail: ImportanceRater.sectionText(text(of: path), fromLine: line, toLine: node.endLine ?? Int.max)))
            default:
                continue
            }
        }
        items = items.filter { existing[$0.key] == nil }
        guard !items.isEmpty else { return }

        let parent = byId[parentId]
        let isDocs = viewId == "docs"
        var context = "System: \(current.systemName ?? root.lastPathComponent)"
        if let purpose = current.systemPurpose { context += " — " + purpose }
        if let parent, parent.kind != "root" {
            context += "\nThese items are inside \(parent.kind == "doc" ? "the document" : "") \(parent.path ?? parent.name)"
            if let summary = parent.summary { context += ": " + summary }
        }
        let key = filterId + "|" + viewId + "|" + parentId
        rating.insert(key)
        let progress = "Rating \(filter.name.lowercased())…"
        host.setStatus(progress)
        Task {
            defer { rating.remove(key); if host.status == progress { host.setStatus(nil) } }
            let request = ImportanceRater.request(subject: isDocs ? .documentation : .code, filter: filter,
                                                  context: context, items: items,
                                                  language: ArchitectureStore.reasonLanguage, project: host.project)
            do {
                let (ratings, result) = try await ImportanceRater.operation(keys: Set(items.map(\.key)), filter: filter).execute(request)
                result.record(in: db)
                guard var next = host.snapshot else { return }
                for (k, var value) in ratings {
                    value.signature = signatures[k]
                    next.ratings[filterId, default: [:]][k] = value
                }
                host.commit(next, db: db)
            } catch {
                host.setError("\(filter.name) rating failed: \(error.localizedDescription)")
            }
        }
    }

    /// A user (or quick) filter over the whole project at once. A keyword search gives
    /// every file and document section a provisional level in seconds; the AI then
    /// confirms the strongest candidates, shown as each answer streams in.
    func searchFilter(filterId: String, root: URL, db: SemanticDatabase?) {
        // I Need to Understand owns a separate answer job, started before the scan finishes.
        if understandingAnswers[filterId] != nil { return }
        guard let current = host.snapshot, filterId != ImportanceRater.importance.id,
              let filter = allFilters.first(where: { $0.id == filterId }),
              rating.insert("search|" + filterId).inserted else { return }
        // The ⚡ quick filter is a search: only what really matters is marked.
        if ImportanceRater.isTemporary(filterId) {
            aiSearch(filter: filter, snapshot: current, root: root, db: db)
            return
        }
        let files = current.view("modules")?.nodes.filter { $0.kind == "file" }.compactMap(\.path) ?? []
        let sections = ArchitectureStore.bookSections(in: current)
        let names = Dictionary((current.view("docs")?.nodes ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let label = "Finding “\(filter.criterion)”…"
        host.setStatus(label)
        let cache = host.answerCache(root)
        let context = "System: \(current.systemName ?? root.lastPathComponent)" + (current.systemPurpose.map { " — " + $0 } ?? "")
        Task {
            defer { rating.remove("search|" + filterId); if host.status?.hasPrefix("Finding") == true || host.status?.hasPrefix("Checking") == true { host.setStatus(nil) } }
            do {
                let terms = try await FilterSearch.terms(for: filter, cache: cache, project: host.project)
                let found = await Task.detached(priority: .userInitiated) { () -> ([String: FilterSearch.Match], [String: FilterSearch.Match]) in
                    let byFile = FilterSearch.scoreFiles(files, root: root, terms: terms)
                    var bySection: [String: FilterSearch.Match] = [:]
                    var texts: [String: String] = [:]
                    for section in sections {
                        let text = texts[section.path] ?? ((try? String(contentsOf: root.appendingPathComponent(section.path), encoding: .utf8)) ?? "")
                        texts[section.path] = text
                        bySection[section.id] = FilterSearch.score(name: names[section.id] ?? "",
                            text: ImportanceRater.sectionText(text, fromLine: section.line, toLine: section.end, limit: 6000), terms: terms)
                    }
                    return (byFile, bySection)
                }.value
                // Provisional levels for everything, right away.
                var table: [String: ImportanceRater.Rating] = [:]
                func reason(_ match: FilterSearch.Match?) -> String {
                    guard let hits = match?.hits, !hits.isEmpty else { return "No mention found" }
                    return "Mentions " + hits.prefix(4).joined(separator: ", ")
                }
                for (path, level) in FilterSearch.levels(found.0.mapValues(\.score)) {
                    table["p:" + path] = .init(level: level, reason: reason(found.0[path]), provisional: true)
                }
                for (id, level) in FilterSearch.levels(found.1.mapValues(\.score)) {
                    table[id] = .init(level: level, reason: reason(found.1[id]), provisional: true)
                }
                guard var next = host.snapshot else { return }
                next.ratings[filterId] = table
                host.commit(next, db: db)

                // The AI confirms the strongest candidates (evidence: the lines around the hit).
                let top = found.0.filter { $0.value.score > 0 }.sorted { ($0.value.score, $1.key) > ($1.value.score, $0.key) }.prefix(40)
                guard !top.isEmpty else { return }
                host.setStatus("Checking \(top.count) candidates…")
                let items = await Task.detached { () -> [ImportanceRater.Item] in
                    top.map { path, match in
                        let text = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
                        return ImportanceRater.Item(key: "p:" + path, label: (path as NSString).lastPathComponent,
                                                    detail: "File \(path)\nMentions: \(match.hits.prefix(6).joined(separator: ", "))\n"
                                                        + FilterSearch.excerpt(of: text, terms: terms))
                    }
                }.value
                let request = ImportanceRater.request(subject: .code, filter: filter, context: context, items: items,
                                                      language: ArchitectureStore.reasonLanguage, project: host.project)
                let keys = Set(items.map(\.key))
                let (ratings, result) = try await ImportanceRater.operation(keys: keys, filter: filter).execute(request, onActivity: { [weak self] activity in
                    guard case .answerDelta(let text) = activity else { return }
                    Task { @MainActor in self?.receiveRatings(text, filterId: filterId, filter: filter, keys: keys) }
                })
                result.record(in: db)
                liveRatings[filterId] = nil
                guard var confirmed = host.snapshot else { return }
                for (k, value) in ratings {
                    confirmed.ratings[filterId, default: [:]][k] = value
                }
                host.commit(confirmed, db: db)
            } catch is CancellationError {
            } catch {
                host.setError("\(filter.name) filter failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - ⚡ Search filter

    struct UnderstandingState: Encodable {
        var question: String
        var state: String = "loading"
        var message: String = "Reading the project and its history…"
        var answer: UnderstandingAnswer?
        var saveMessage: String?
        var attachments: [String] = []
    }
    private(set) var understandingAnswers: [String: UnderstandingState] = [:]
    private var understandingRatings: [String: [String: ImportanceRater.Rating]] = [:]
    private var understandingTasks: [String: Task<Void, Never>] = [:]
    private var understandingTokens: [String: UUID] = [:]
    private var understandingAttachmentFolders: [String: URL] = [:]
    private var understandingInputAttachments: [String: [URL]] = [:]

    private func clearUnderstandingAttachments(filterId: String? = nil) {
        let folders: [URL]
        if let filterId { folders = understandingAttachmentFolders.removeValue(forKey: filterId).map { [$0] } ?? [] }
        else { folders = Array(understandingAttachmentFolders.values); understandingAttachmentFolders = [:] }
        Task.detached { for folder in folders { try? FileManager.default.removeItem(at: folder) } }
    }

    /// Both intake entry points use this job. It can answer before X-Ray's first scan,
    /// and retains provisional/streamed evidence when generation or validation fails.
    func understand(filter: ImportanceRater.Filter, root: URL, db: SemanticDatabase?, attachments: [URL]? = nil) {
        let id = filter.id
        understandingTasks[id]?.cancel()
        let previousAttachments = understandingAnswers[id]?.attachments ?? []
        if let attachments {
            clearUnderstandingAttachments(filterId: id)
            understandingInputAttachments[id] = attachments
        }
        let token = UUID()
        // A folder X-Ray answers from its folder, but the question may name any file of the open
        // project (Boris asked about docs/raw/… from a feature folder's X-Ray): the whole project is
        // readable too, and the agent is told so.
        let wholeProject: [URL] = (host.projectRoot?.standardizedFileURL).map { $0.path == root.standardizedFileURL.path ? [] : [$0] } ?? []
        let wholeProjectNote: String? = wholeProject.first.map {
            "\n\nThe working directory is one folder of the project \($0.path); the whole project is readable too (an additional directory). Read any file the question names, by its absolute path if given; paths in the answer may be absolute or relative to the working directory."
        }
        let attachmentFolder = attachments?.isEmpty == false ? ProjectPaths.understandingFolder(root).appendingPathComponent(token.uuidString) : nil
        if let attachmentFolder { understandingAttachmentFolders[id] = attachmentFolder }
        understandingTokens[id] = token
        understandingAnswers[id] = .init(question: filter.criterion)
        if attachments == nil { understandingAnswers[id]?.attachments = previousAttachments }
        liveSearch[id] = nil
        host.bump()
        let current = host.snapshot
        let sections = ArchitectureStore.bookSections(in: current)
        let files = Array(Set((current?.view("modules")?.nodes.compactMap(\.path) ?? [])
                             + (current?.view("docs")?.nodes.compactMap(\.path) ?? [])))
        understandingTasks[id] = Task {
            defer {
                if understandingTokens[id] != token, let attachmentFolder {
                    Task.detached { try? FileManager.default.removeItem(at: attachmentFolder) }
                }
                if understandingTokens[id] == token {
                    understandingTasks[id] = nil
                    liveSearch[id] = nil
                }
            }
            do {
                if let attachmentFolder, let attachments {
                    let paths = try await Task.detached {
                        try UnderstandingAttachments.copy(attachments, to: attachmentFolder, root: root)
                    }.value
                    guard understandingTokens[id] == token else { return }
                    understandingAnswers[id]?.attachments = paths
                }
                let attachmentPaths = understandingAnswers[id]?.attachments ?? []
                // Local candidates are useful even when the CLI is unavailable. Answer
                // generation does not depend on a second AI call to extract keywords.
                let terms = filter.criterion.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .filter { $0.count >= 3 }.map(String.init)
                let found = await Task.detached(priority: .userInitiated) {
                    FilterSearch.scoreFiles(files, root: root, terms: terms)
                }.value
                guard understandingTokens[id] == token else { return }
                let paths = found.filter { $0.value.score > 0 }.sorted { $0.value.score > $1.value.score }.prefix(30).map(\.key)
                var candidates = understandingRatings[id] ?? [:]
                for path in paths { candidates["p:" + path] = .init(level: "strong", reason: "Question keyword candidate", provisional: true) }
                understandingRatings[id] = candidates
                if var next = host.snapshot {
                    next.ratings[id] = candidates
                    host.show(next)
                    host.bump()
                }
                understandingAnswers[id]?.message = "Finding evidence in code and documents…"
                host.bump()
                var historyFiles: [XRaySearch.HistoryFile] = []
                do {
                    var scopeRequest = XRaySearch.understandingScopeRequest(query: filter.criterion, root: root, attachments: attachmentPaths, project: host.project)
                    scopeRequest.extraReadableFolders = wholeProject
                    if let note = wholeProjectNote { scopeRequest.prompt += note }
                    let scope = try await AIOperation<CLICompletion.Request, CLICompletion.Result>.ask(scopeRequest, name: "understand-scope")
                    guard understandingTokens[id] == token else { return }
                    scope.record(in: db)
                    historyFiles = await Task.detached { XRaySearch.historyFiles(scope.structured, root: root) }.value
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // Discovery is a hint, never a gate. The answer agent can still read
                    // all files; unavailable history is explicitly noted in its context.
                }
                guard understandingTokens[id] == token else { return }
                if historyFiles.isEmpty {
                    historyFiles = await Task.detached {
                        XRaySearch.historyFiles(["files": paths.prefix(8).map { ["path": $0, "start": 1, "end": 120] }], root: root)
                    }.value
                }
                for file in historyFiles { understandingRatings[id, default: [:]]["p:" + file.path] = .init(level: "strong", reason: "Answer evidence candidate", provisional: true) }
                // Pull requests need `gh`: only the opt-in GitHub integration may run it. Read the
                // switch once so the progress line and the history agree.
                let includePullRequests = GitHubSettings.enabled
                understandingAnswers[id]?.message = includePullRequests ? "Reading git history and pull requests…" : "Reading git history…"
                host.bump()
                let context = await XRaySearch.provenance(root: root, files: historyFiles, includePullRequests: includePullRequests)
                try Task.checkCancellation()
                guard understandingTokens[id] == token else { return }
                let components = host.snapshot?.components ?? []
                let nodes = host.snapshot?.view("deployment")?.nodes.filter { $0.kind != "root" && $0.kind != "moduleRef" } ?? []
                let bookHints = host.snapshot.map { ArchitectureStore.bookHints(for: filter.criterion, in: $0) } ?? []
                var request = XRaySearch.understandingRequest(query: filter.criterion,
                    hints: historyFiles.map { "- \($0.path):\($0.start)-\($0.end)" } + bookHints, root: root,
                    context: context, components: components.map { "\($0.id) — \($0.name): \($0.purpose)" },
                    deployment: nodes.map { "\($0.id.dropFirst(2)) — \($0.name): \($0.summary ?? $0.kind)" }, attachments: attachmentPaths,
                    project: host.project)
                request.extraReadableFolders = wholeProject
                if let note = wholeProjectNote { request.prompt += note }
                let result = try await AIOperation<CLICompletion.Request, CLICompletion.Result>.ask(request, name: "understand", onActivity: { activity in
                    Task { @MainActor in
                        guard self.understandingTokens[id] == token, self.understandingAnswers[id]?.state == "loading" else { return }
                        if case .read(let path) = activity {
                            self.understandingAnswers[id]?.message = "Reading " + (path as NSString).lastPathComponent + "…"
                            self.host.bump()
                        }
                        if case .answerDelta = activity {
                            self.receiveSearch(activity, filterId: id, root: root, sections: sections)
                        }
                    }
                })
                try Task.checkCancellation()
                guard understandingTokens[id] == token else { return }
                result.record(in: db)
                let object = result.structured as? [String: Any]
                let places = await Task.detached { XRaySearch.places(from: object?["steps"], root: root) }.value
                guard understandingTokens[id] == token else { return }
                understandingRatings[id, default: [:]].merge(XRayFilterStore.searchTable(places, sections: sections, confirmed: true)) { _, confirmed in confirmed }
                // Keep these even if the explanatory part is empty or invalid.
                if var next = host.snapshot {
                    var table = next.ratings[id] ?? [:]
                    table.merge(XRayFilterStore.searchTable(places, sections: sections, confirmed: true)) { _, confirmed in confirmed }
                    next.ratings[id] = table
                    host.show(next)
                    host.bump()
                }
                let projectURL = host.projectRoot
                let parsed = try await Task.detached {
                    try UnderstandingAnswer.parse(object?["explanation"], root: root, components: Set(components.map(\.id)),
                        deployment: Set(nodes.map { String($0.id.dropFirst(2)) }), commits: context.commits, pullRequests: context.pullRequests,
                        project: projectURL)
                }.value
                guard understandingTokens[id] == token else { return }
                // Typed citations are authoritative, even if the AI forgot a highlight/step.
                let citedPlaces = parsed.sources.filter { $0.kind == .code || $0.kind == .document }.map {
                    XRaySearch.Place(path: $0.path, start: $0.start, end: $0.end, title: $0.label, why: "Cited in the answer", step: "Evidence")
                }
                let allPlaces = Array(Set(places + citedPlaces)).sorted { ($0.path, $0.start) < ($1.path, $1.start) }
                var table = XRayFilterStore.searchTable(allPlaces, sections: sections, confirmed: true)
                for source in parsed.sources {
                    if source.kind == .component { table["c:" + source.target] = .init(level: "strong", reason: source.label, provisional: false) }
                    if source.kind == .deployment { table["dep:" + source.target] = .init(level: "strong", reason: source.label, provisional: false) }
                }
                understandingRatings[id] = table
                if var next = host.snapshot {
                    next.ratings[id] = table
                    host.show(next)
                }
                searchAnswers[id] = .init(question: filter.criterion, answer: parsed.markdown(question: filter.criterion),
                    steps: [.init(title: "Evidence", places: allPlaces.map { .init(path: $0.path, start: $0.start, end: $0.end, title: $0.title, why: $0.why) })])
                understandingAnswers[id]?.answer = parsed
                understandingAnswers[id]?.state = "ready"
                understandingAnswers[id]?.message = ""
                host.bump()
            } catch {
                guard understandingTokens[id] == token else { return }
                understandingAnswers[id]?.state = "failed"
                understandingAnswers[id]?.message = error is CancellationError ? "Answer generation was cancelled." : error.localizedDescription
                host.bump()
            }
        }
    }

    /// The window's one-off filter (`WorkspaceManager.setTemporaryFilter` hands it to every store of the window).
    var temporaryFilter: ImportanceRater.Filter?
    var allFilters: [ImportanceRater.Filter] { ImportanceRater.allFilters(temporary: temporaryFilter) }

    func retryUnderstanding(filterId: String, root: URL, db: SemanticDatabase?) {
        guard understandingAnswers[filterId]?.state == "failed",
              let filter = temporaryFilter, filter.id == filterId else { return }
        let retryCopy = understandingAnswers[filterId]?.attachments.isEmpty == true
            ? understandingInputAttachments[filterId] : nil
        understand(filter: filter, root: root, db: db, attachments: retryCopy)
    }

    func understandingSource(filterId: String, sourceId: String) -> UnderstandingAnswer.Source? {
        understandingAnswers[filterId]?.answer?.sources.first { $0.id == sourceId }
    }

    func saveUnderstanding(filterId: String, root: URL, author: String) async -> URL? {
        guard let state = understandingAnswers[filterId], state.state == "ready", let answer = state.answer,
              state.saveMessage != "Saving…" else { return nil }
        understandingAnswers[filterId]?.saveMessage = "Saving…"
        host.bump()
        let date = FeatureStore.today
        do {
            let file = try await Task.detached {
                try answer.save(question: state.question, root: root, author: author, date: date,
                    attachments: state.attachments.map { root.appendingPathComponent($0) })
            }.value
            understandingAnswers[filterId]?.saveMessage = "Saved as " + file.lastPathComponent
            host.bump()
            return file
        } catch {
            understandingAnswers[filterId]?.saveMessage = "Could not save: " + error.localizedDescription
            host.bump()
            return nil
        }
    }

    /// Code elements behind search queries ("Explain with AI — everything related"), by criterion.
    var searchSymbols: [String: XRaySearch.Symbol] = [:]
    /// Tells the X-Ray to switch to this filter (a search started outside the X-Ray).
    private(set) var activateFilter: String?
    private var activateToken = 0

    /// Show the filter `id` in the X-Ray (the next payload switches the overlay to it).
    func activate(filterId: String) {
        activateToken += 1
        activateFilter = "\(filterId)|\(activateToken)"
        host.bump()
    }

    /// The ⚡ search: keyword candidates first (dashed red outlines, in seconds), then the AI
    /// reads the project and returns the places that matter; their files turn red and every
    /// other file stays uncoloured. Places stream in as the AI writes them.
    private func aiSearch(filter: ImportanceRater.Filter, snapshot current: ArchitectureSnapshot, root: URL, db: SemanticDatabase?) {
        let filterId = filter.id
        // Code files and every chapter of the Book (text documents beyond Markdown included).
        let files = Array(Set((current.view("modules")?.nodes.filter { $0.kind == "file" }.compactMap(\.path) ?? [])
                             + (current.view("docs")?.nodes.filter { $0.kind == "doc" }.compactMap(\.path) ?? [])))
        let sections = ArchitectureStore.bookSections(in: current)
        let symbol = searchSymbols[filter.criterion]
        host.setStatus(symbol != nil ? "Finding everything related to \(symbol!.name)…" : "Searching “\(filter.criterion)”…")
        let cache = host.answerCache(root)
        Task {
            defer { rating.remove("search|" + filterId); if host.status?.hasPrefix("Search") == true || host.status?.hasPrefix("Finding") == true || host.status?.hasPrefix("AI") == true { host.setStatus(nil) } }
            do {
                // 1. Candidates in seconds: keyword hits, or where the element is defined and used.
                var hints: [String]
                var table: [String: ImportanceRater.Rating] = [:]
                if let symbol {
                    hints = await Task.detached(priority: .userInitiated) { XRaySearch.symbolHints(symbol, root: root) }.value
                    table["p:" + symbol.path] = .init(level: "strong", reason: "Defines \(symbol.name)", provisional: true)
                } else {
                    let terms = try await FilterSearch.terms(for: filter, cache: cache, project: host.project)
                    let found = await Task.detached(priority: .userInitiated) { FilterSearch.scoreFiles(files, root: root, terms: terms) }.value
                    let levels = FilterSearch.levels(found.mapValues(\.score))
                    for (path, level) in levels where level == "strong" {
                        table["p:" + path] = .init(level: "strong", reason: "Mentions " + (found[path]?.hits.prefix(4).joined(separator: ", ") ?? ""), provisional: true)
                    }
                    hints = found.filter { $0.value.score > 0 }
                        .sorted { ($0.value.score, $1.key) > ($1.value.score, $0.key) }
                        .prefix(30)
                        .map { "- \($0.key) (mentions \($0.value.hits.prefix(4).joined(separator: ", ")))" }
                }
                hints += ArchitectureStore.bookHints(for: filter.criterion, in: current)
                guard var next = host.snapshot else { return }
                next.ratings[filterId] = table
                host.commit(next, db: db)
                host.setStatus("AI is reading the project for “\(symbol?.name ?? filter.criterion)”…")

                // 2. The AI's places: their files (and document sections) are what matters.
                let componentLines = current.components.map { "\($0.id) — \($0.name): \($0.purpose)" }
                let deploymentLines = (current.view("deployment")?.nodes ?? [])
                    .filter { $0.kind != "root" && $0.kind != "moduleRef" }
                    .map { "\($0.id.dropFirst(2)) — \($0.name): \($0.summary ?? $0.kind)" }
                let request = XRaySearch.request(query: filter.criterion, symbol: symbol, hints: hints, root: root,
                                                 components: componentLines, deployment: deploymentLines, project: host.project)
                let result = try await AIOperation<CLICompletion.Request, CLICompletion.Result>.ask(request, name: "xray-search", onActivity: { activity in
                    Task { @MainActor in self.receiveSearch(activity, filterId: filterId, root: root, sections: sections) }
                })
                result.record(in: db)
                liveSearch[filterId] = nil
                let object = result.structured as? [String: Any]
                let places = await Task.detached { XRaySearch.places(from: object?["steps"], root: root) }.value
                guard var done = host.snapshot else { return }
                var final = XRayFilterStore.searchTable(places, sections: sections, confirmed: true)
                // Logical components and deployment nodes the AI named (besides those containing its files).
                let knownComponents = Set(current.components.map(\.id))
                for id in object?["components"] as? [String] ?? [] where knownComponents.contains(id) {
                    final["c:" + id] = .init(level: "strong", reason: "Takes part (AI)", provisional: false)
                }
                let knownDeployment = Set((current.view("deployment")?.nodes ?? []).map { String($0.id.dropFirst(2)) })
                for id in object?["deployment"] as? [String] ?? [] where knownDeployment.contains(id) {
                    final["dep:" + id] = .init(level: "strong", reason: "Involved (AI)", provisional: false)
                }
                done.ratings[filterId] = final
                host.commit(done, db: db)
                if let summary = (object?["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    searchSummaries[filterId] = summary
                }
                let stepValues = (object?["steps"] as? [[String: Any]] ?? []).map { step -> SearchAnswer.Step in
                    let stepPlaces = XRaySearch.places(from: [step], root: root)
                    return SearchAnswer.Step(title: step["title"] as? String ?? "",
                                             places: stepPlaces.map { .init(path: $0.path, start: $0.start, end: $0.end, title: $0.title, why: $0.why) })
                }
                searchAnswers[filterId] = SearchAnswer(question: filter.criterion,
                                                       answer: (object?["answer"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                                       steps: stepValues)
                host.bump()
            } catch is CancellationError {
            } catch {
                host.setError("Search failed: \(error.localizedDescription)")
            }
        }
    }

    /// What the AI said about the search as a whole, by filter id (shown in the details panel).
    private(set) var searchSummaries: [String: String] = [:]

    /// The ⚡ search's full answer: the question answered, and the flow step by step with its places.
    struct SearchAnswer: Codable {
        struct Place: Codable { var path: String; var start: Int; var end: Int; var title: String; var why: String }
        struct Step: Codable { var title: String; var places: [Place] }
        var question: String
        var answer: String
        var steps: [Step]
    }
    private(set) var searchAnswers: [String: SearchAnswer] = [:]

    /// The ⚡ search's places inside one file, for the code viewer's "⚡" lens.
    struct SearchNotes: Encodable {
        struct Place: Encodable { var start: Int; var end: Int; var title: String; var why: String; var step: String }
        var question: String
        var places: [Place]
        /// Opened from the search: the viewer starts on this lens.
        var focus: Bool
    }
    private var searchFocusPaths: Set<String> = []

    func markSearchFocus(path: String) { searchFocusPaths.insert(path) }

    /// Keep a ⚡ search's answer as a document: docs/research/RES-nnn-<title>.md with the answer
    /// and every place as a `path:line` link. No new AI call. Returns the file.
    func saveSearchAnswer(filterId: String, root: URL, author: String) -> URL? {
        guard let answer = searchAnswers[filterId] else { return nil }
        let folder = root.appendingPathComponent("docs/research", isDirectory: true)
        let id = FeatureAssistant.nextNumbered("RES", in: folder)
        let title = String(answer.question.prefix(90))
        var body = "# \(title)\n\n> \(answer.question.replacingOccurrences(of: "\n", with: "\n> "))\n\n## Answer\n\n"
        body += answer.answer.isEmpty ? (searchSummaries[filterId] ?? "") : answer.answer
        body += "\n"
        for step in answer.steps where !step.places.isEmpty {
            body += "\n## \(step.title)\n\n"
            for place in step.places {
                body += "- [\(place.path):\(place.start)](../../\(place.path)) — **\(place.title)**: \(place.why)\n"
            }
        }
        var front = FrontMatter()
        front.set("type", "research")
        front.set("id", id)
        front.set("title", title)
        front.set("question", String(answer.question.prefix(500)))
        front.set("created", FeatureStore.today)
        front.set("author", author)
        front.set("provenance", "X-Ray ⚡ search")
        let file = folder.appendingPathComponent("\(id)-\(featureSlug(title).prefix(50)).md")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(front.join(body: body).utf8).write(to: file, options: .withoutOverwriting)
        } catch {
            host.setError("Could not save the answer: \(error.localizedDescription)")
            host.bump()
            return nil
        }
        return file
    }

    func searchNotes(path: String) -> SearchNotes? {
        guard let id = temporaryFilter?.id, let answer = searchAnswers[id] else { return nil }
        let places = answer.steps.flatMap { step in
            step.places.filter { $0.path == path }.map { SearchNotes.Place(start: $0.start, end: $0.end, title: $0.title, why: $0.why, step: step.title) }
        }
        guard !places.isEmpty else { return nil }
        return SearchNotes(question: answer.question, places: places.sorted { $0.start < $1.start },
                           focus: searchFocusPaths.contains(path))
    }

    private var liveSearch: [String: String] = [:]
    private var liveSearchPending: Set<String> = []

    private func receiveSearch(_ activity: CLICompletion.Activity, filterId: String, root: URL,
                               sections: [ArchitectureStore.BookSection]) {
        switch activity {
        case .read(let path):
            let base = root.standardizedFileURL.path + "/"
            host.setStatus("AI is reading " + (path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path))
        case .answerDelta(let text):
            liveSearch[filterId, default: ""] += text
            guard liveSearchPending.insert(filterId).inserted else { return }
            let token = understandingTokens[filterId]
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                liveSearchPending.remove(filterId)
                guard understandingTokens[filterId] == token, let answer = liveSearch[filterId] else { return }
                let places = await Task.detached {
                    XRaySearch.places(from: XRayDigest.completedObjects(in: answer, key: "steps"), root: root)
                }.value
                guard !places.isEmpty, var next = host.snapshot, liveSearch[filterId] != nil, understandingTokens[filterId] == token else { return }
                // Keyword candidates stay dashed until the answer is complete.
                var table = next.ratings[filterId] ?? [:]
                for (key, value) in XRayFilterStore.searchTable(places, sections: sections, confirmed: true) where value.level == "strong" {
                    table[key] = value
                }
                next.ratings[filterId] = table
                if understandingAnswers[filterId] != nil { understandingRatings[filterId] = table }
                host.show(next)     // live; saved when the answer is complete
                host.bump()
            }
        default:
            break
        }
    }

    /// Ratings from the search's places: "strong" for every file with a place (and every
    /// document section a place falls in), "none" for nothing else — unrated means uncoloured.
    nonisolated private static func searchTable(_ places: [XRaySearch.Place], sections: [ArchitectureStore.BookSection],
                                                confirmed: Bool) -> [String: ImportanceRater.Rating] {
        var table: [String: ImportanceRater.Rating] = [:]
        let byPath = Dictionary(grouping: places, by: \.path)
        for (path, found) in byPath {
            table["p:" + path] = .init(level: "strong", reason: XRaySearch.reason(for: found), provisional: !confirmed)
        }
        // Every section whose lines a place touches: nested sections and their parents alike.
        let sectionsByPath = Dictionary(grouping: sections, by: \.path)
        for (path, found) in byPath {
            for section in sectionsByPath[path] ?? [] {
                let inside = found.filter { $0.start <= section.end && $0.end >= section.line }
                if !inside.isEmpty {
                    table[section.id] = .init(level: "strong", reason: XRaySearch.reason(for: inside), provisional: !confirmed)
                }
            }
        }
        return table
    }

    /// Streamed rating answers per filter, shown before the answer is complete.
    private var liveRatings: [String: String] = [:]
    private var liveRatingsPending: Set<String> = []

    private func receiveRatings(_ text: String, filterId: String, filter: ImportanceRater.Filter, keys: Set<String>) {
        liveRatings[filterId, default: ""] += text
        guard liveRatingsPending.insert(filterId).inserted else { return }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            liveRatingsPending.remove(filterId)
            guard let answer = liveRatings[filterId], var next = host.snapshot else { return }
            let rows = XRayDigest.completedObjects(in: answer, key: "ratings")
            let parsed = ImportanceRater.parse(["ratings": rows], keys: keys, filter: filter)
            guard !parsed.isEmpty else { return }
            for (k, value) in parsed { next.ratings[filterId, default: [:]][k] = value }
            host.show(next)     // live; saved when the answer is complete
            host.bump()
        }
    }

    /// Filters changed elsewhere (created in the code viewer); re-render.
    func filtersChanged() { host.bump() }

    /// Drop this project's ratings for a deleted filter.
    func forgetRatings(filterId: String, db: SemanticDatabase?) {
        clearUnderstandingAttachments(filterId: filterId)
        understandingTokens[filterId] = nil
        understandingTasks.removeValue(forKey: filterId)?.cancel()
        understandingAnswers[filterId] = nil
        understandingInputAttachments[filterId] = nil
        understandingRatings[filterId] = nil
        searchAnswers[filterId] = nil
        searchSummaries[filterId] = nil
        liveSearch[filterId] = nil
        guard var next = host.snapshot, next.ratings[filterId] != nil else { host.bump(); return }
        next.ratings[filterId] = nil
        host.commit(next, db: db)
    }

    /// Scans and analysis may finish while the answer runs. Keep transient evidence
    /// outside their persisted snapshots, and project it onto the current graph.
    func withUnderstandingEvidence(_ value: ArchitectureSnapshot) -> ArchitectureSnapshot {
        var next = value
        let sections = ArchitectureStore.bookSections(in: value)
        for (id, ratings) in understandingRatings {
            var table = ratings
            if let answer = searchAnswers[id] {
                let places = answer.steps.flatMap { step in step.places.map {
                    XRaySearch.Place(path: $0.path, start: $0.start, end: $0.end, title: $0.title, why: $0.why, step: step.title)
                } }
                table.merge(XRayFilterStore.searchTable(places, sections: sections, confirmed: true)) { _, confirmed in confirmed }
            }
            next.ratings[id] = table
        }
        // The agent may cite a readable source the scanner does not index (for example
        // an uncommon extension). Give it a transient, selectable place in Structure,
        // and documents a place in Docs as well. These nodes are never persisted.
        for state in understandingAnswers.values {
            for source in state.answer?.sources ?? [] where source.kind == .code || source.kind == .document {
                for viewId in source.kind == .document ? ["modules", "docs"] : ["modules"] {
                    guard let i = next.views.firstIndex(where: { $0.id == viewId }),
                          !next.views[i].nodes.contains(where: { $0.path == source.path }) else { continue }
                    let prefix = viewId == "modules" ? "m:" : "d:"
                    let parent = next.views[i].nodes.first { $0.kind == "root" }?.id
                    next.views[i].nodes.append(ArchNode(id: prefix + source.path, parent: parent,
                        kind: viewId == "modules" ? "file" : "doc", name: (source.path as NSString).lastPathComponent,
                        path: source.path, files: 1, summary: source.label))
                }
            }
        }
        return next
    }
}
