import AppKit
import Combine
import Foundation
import MarkViewCore

/// What the coordinator needs of the window it works in: the tabs it reads and opens, the files, the assistant terminal and the
/// pull-request and insight features that start from an X-Ray. `WorkspaceManager` is the one implementation; the coordinator holds no
/// reference to it beyond this.
@MainActor
protocol CodeXRayHost: AnyObject {
    /// Kind and file of the tab on show.
    var activeTabKind: TabKind? { get }
    var activeTabURL: URL? { get }
    /// The text the open tab for `url` holds (unsaved edits included); nil when the file is not open.
    func openTabContent(for url: URL) -> String?
    /// Open `url` and reveal `line`…`endLine` in the code viewer.
    func openFile(_ url: URL, line: Int?, endLine: Int?)
    /// Show the X-Ray tab of `scope` (the project's, a folder's or the pull request's), opening it when it is not there yet.
    func showXRayTab(scope: String, root: URL)
    /// Open a text file with its Explain notes.
    func explainFile(_ url: URL)
    /// Scroll the open document to `text`.
    func scrollToText(_ text: String)
    func refreshFileTree()
    /// The project's operations, with this window as their presenter.
    func operations() -> ProjectOperationsStore?
    var projectOperations: ProjectOperationsStore? { get }
    func startRecursiveInsight(at target: URL?, title: String?)
    /// Type `prompt` at the assistant's prompt; `submit` presses Enter.
    func sendToAssistant(_ prompt: String, submit: Bool) -> TerminalSession?
    /// Send a fix request for a pull request's code to the assistant, after checking its branch out. Returns an error to show.
    func fixInPullRequest(_ number: Int?, prompt: String) async -> String?
    /// The branch checked out, empty when there is none.
    var gitBranch: String { get }
    /// Who a saved answer is written for.
    var defaultAuthor: String { get }
}

/// Everything a window does with code and the project's X-Ray: the margin notes of the code viewer (Explain, ratings, freshness,
/// filters), go to definition and find usages, the AI answers about selected code and selected text, the X-Ray tabs (the project's, a
/// folder's, a pull request's) with their store, and the requests an X-Ray page sends. It owns that state and its background work
/// (`AR-14` step 11, `AR-19`); `WorkspaceManager` holds one and no longer holds any X-Ray state or dispatches X-Ray requests.
@MainActor
final class CodeAndXRayCoordinator: ObservableObject {
    /// The project's X-Ray (scope "") and the pull-request X-Ray (`TabKind.pullRequestScope`).
    let architecture = ArchitectureStore()
    /// AI margin notes for code files (code viewer → Explain).
    let codeExplain = CodeExplainStore()
    /// Go to definition / find usages, jump history and AI answers about selected code.
    let codeNav = CodeNavigationStore()
    /// The one-off filter of this window (typed into an X-Ray or notes filter box); other windows have their own.
    private(set) var temporaryFilter: ImportanceRater.Filter?

    /// What an AI action on selected text is doing, shown in the bar over the editor.
    struct SelectionActionState: Identifiable {
        enum Phase { case running, completed, stopped, failed }
        let id: UUID
        let title: String
        let scope: String
        let assistant: String
        let started: Date
        var stage: String = "Starting"
        var partial: String = ""
        var phase: Phase = .running
    }
    @Published private(set) var selectionActions: [UUID: SelectionActionState] = [:]

    private let project: any ProjectProviding
    weak var host: (any CodeXRayHost)?
    /// Folder X-Rays by folder path (relative to the project root). The project's own X-Ray is `architecture` (scope "").
    private var folderXRays: [String: ArchitectureStore] = [:]
    /// The coordinator's own one-off background work (`AR-19`): cancelled when the folder switches or the window closes.
    private let tasks = TaskBag()
    private var selectionTasks: [UUID: Task<CLICompletion.Result, Error>] = [:]
    private var stoppedSelectionActions: Set<UUID> = []

    init(project: any ProjectProviding) {
        self.project = project
    }

    /// A folder opens or closes: the stores start over and the work started for the old project stops.
    func reset() {
        tasks.cancelAll()
        architecture.reset()
        folderXRays = [:]
        codeNav.reset()
        codeExplain.reset()
    }

    /// The window closes: the work of the coordinator ends with it, the AI actions on selected text included.
    func close() {
        reset()
        selectionTasks.values.forEach { $0.cancel() }
        selectionTasks.removeAll()
    }

    // MARK: - Selection actions

    func stopSelectionAction(_ id: UUID) {
        stoppedSelectionActions.insert(id)
        selectionTasks[id]?.cancel()
        if var state = selectionActions[id] {
            state.stage = "Stopping…"
            selectionActions[id] = state
        }
    }

    func dismissSelectionAction(_ id: UUID) { selectionActions.removeValue(forKey: id) }

    /// Handle selection actions: translate or explain selected text via the selected AI CLI.
    /// Result is shown in a popup — see `translateDocument` for the whole-document
    /// path, which produces a translated copy in a new tab instead.
    func handleSelectionAction(action: String, text: String, completion: @escaping (String, String) -> Void) async {
        let (systemPrompt, title): (String, String) = {
            switch action {
            case "translate_ru":
                return ("You are a professional translator. Translate the user's text to Russian word-for-word. Do NOT summarize, do NOT shorten, do NOT skip anything. Translate every single sentence. Return ONLY the translated text in markdown format.", "Translation to Russian")
            case "translate_en":
                return ("You are a professional translator. Translate the user's text to English word-for-word. Do NOT summarize, do NOT shorten, do NOT skip anything. Translate every single sentence. Return ONLY the translated text in markdown format.", "Translation to English")
            case "explain":
                return ("You are a knowledgeable assistant. Explain the following text clearly and concisely. Use markdown formatting. If it contains technical terms, define them. If it contains code, explain what it does.", "Explanation")
            default:
                return ("Process the following text.", "Result")
            }
        }()

        var request = CLICompletion.Request(project: project.aiProject, prompt: text, systemPrompt: systemPrompt)
        request.timeout = 120
        let id = UUID()
        let scope = host?.activeTabURL.map { project.relativePath(of: $0) } ?? "Selected text"
        let assistant = AIAssistantPreferences.summary(tool: request.tool,
            model: request.model ?? AIAssistantPreferences.model(for: request.tool, project: request.project) ?? "")
        selectionActions[id] = SelectionActionState(id: id, title: title,
            scope: "\(scope) · selected text", assistant: assistant, started: Date())
        let task = Task { [weak self] in
            try await AIOperation<CLICompletion.Request, CLICompletion.Result>.ask(request, name: "selection-action", onDelta: { [weak self] delta in
                Task { @MainActor in
                    guard var state = self?.selectionActions[id], state.phase == .running else { return }
                    state.partial += delta
                    state.stage = "Writing answer"
                    self?.selectionActions[id] = state
                }
            }, onActivity: { [weak self] activity in
                Task { @MainActor in
                    guard var state = self?.selectionActions[id], state.phase == .running else { return }
                    switch activity {
                    case .thinking: state.stage = "Thinking"
                    case .writing, .answerDelta: state.stage = "Writing answer"
                    case .read, .search, .run: state.stage = "Reading project context"
                    case .webSearch, .webFetch: state.stage = "Reading web context"
                    }
                    self?.selectionActions[id] = state
                }
            })
        }
        selectionTasks[id] = task
        defer {
            selectionTasks.removeValue(forKey: id)
            stoppedSelectionActions.remove(id)
        }
        do {
            let result = try await task.value
            if stoppedSelectionActions.contains(id) {
                finishSelectionAction(id, phase: .stopped, stage: "Stopped · partial answer retained")
                completion(title, selectionActions[id]?.partial ?? "Stopped")
                return
            }
            result.record(in: project.database)
            finishSelectionAction(id, phase: .completed, stage: "Completed")
            completion(title, result.text)
        } catch is CancellationError {
            finishSelectionAction(id, phase: .stopped, stage: "Stopped · partial answer retained")
            completion(title, selectionActions[id]?.partial ?? "Stopped")
        } catch {
            if stoppedSelectionActions.contains(id) {
                finishSelectionAction(id, phase: .stopped, stage: "Stopped · partial answer retained")
                completion(title, selectionActions[id]?.partial ?? "Stopped")
                return
            }
            finishSelectionAction(id, phase: .failed, stage: error.localizedDescription)
            completion(title, "Error: \(error.localizedDescription)")
        }
    }

    private func finishSelectionAction(_ id: UUID, phase: SelectionActionState.Phase, stage: String) {
        guard var state = selectionActions[id] else { return }
        state.phase = phase
        state.stage = stage
        selectionActions[id] = state
    }

    // MARK: - Code explanations

    private func explainDirectory(for url: URL) -> URL {
        // A pull request's copy of a project file keeps its notes with the project's.
        if architecture.review.prRelativePath(for: url) != nil, let root = project.root {
            return ProjectPaths.explainCacheFolder(root)
        }
        return project.cacheDirectory(for: url).appendingPathComponent("explain", isDirectory: true)
    }

    /// AI filters available to the code viewer: Importance and the user's own.
    private var aiFilters: [ImportanceRater.Filter] { ImportanceRater.allFilters(temporary: temporaryFilter) }

    /// Create or delete a user filter (from the Architecture tab or the code viewer).
    func createFilter(name: String, criterion: String) {
        ImportanceRater.addFilter(name: name, criterion: criterion)
        allXRayStores.forEach { $0.filters.filtersChanged() }
        codeExplain.filtersChanged()
    }

    /// The one-off AI filter from a filter box (X-Ray or notes); empty clears it.
    func setTemporaryFilter(_ criterion: String) {
        let previous = temporaryFilter
        temporaryFilter = ImportanceRater.temporaryFilter(for: criterion)
        allXRayStores.forEach { $0.filters.temporaryFilter = temporaryFilter }
        if let previous {
            architecture.filters.forgetRatings(filterId: previous.id, db: project.database)
            folderXRays.values.forEach { $0.filters.forgetRatings(filterId: previous.id, db: nil) }
        }
        allXRayStores.forEach { $0.filters.filtersChanged() }
        codeExplain.filtersChanged()
    }

    func deleteFilter(id: String) {
        if ImportanceRater.isTemporary(id) {
            if temporaryFilter?.id == id { setTemporaryFilter("") }
            return
        }
        ImportanceRater.removeFilter(id: id)
        architecture.filters.forgetRatings(filterId: id, db: project.database)
        codeExplain.filtersChanged()
    }

    /// Project path of a file in the code viewer. A file shown from a fetched pull request
    /// (MarkView's cache) counts as that project path, so its notes, explanations and PR
    /// lens are all about the same file.
    private func codePath(for url: URL) -> String {
        architecture.review.prRelativePath(for: url) ?? project.relativePath(of: url)
    }

    /// Load cached notes for a code file that just opened.
    func prepareCodeNotes(for url: URL) {
        codeExplain.load(path: codePath(for: url), directory: explainDirectory(for: url))
        codeNav.sendState(url: url)
    }

    /// The margin panel state for `url`, as a JSON object literal.
    func codeNotesJSON(for url: URL) -> String {
        let content = host?.openTabContent(for: url) ?? ""
        let path = codePath(for: url)
        return codeExplain.payloadJSON(path: path, content: content, filters: aiFilters,
                                       pr: architecture.review.prFileNotes(path: path, content: content),
                                       search: architecture.filters.searchNotes(path: path))
    }

    /// Start an explanation of a file's notes when it has none yet.
    func explainIfNeeded(_ url: URL) {
        prepareCodeNotes(for: url)
        if codeExplain.explanations[codePath(for: url)] == nil {
            handleCodeAction("explain", payload: [:], url: url)
        }
    }

    // MARK: - Explain with AI

    /// "Explain with AI — everything related" on a code element: the X-Ray's ⚡ search for
    /// it, with everything connected to it in red.
    func explainSymbol(name: String, path: String, line: Int) {
        guard project.root != nil, CodeNavigator.isNavigable(name) else { return }
        let criterion = "\(name) — \((path as NSString).lastPathComponent):\(line)"
        architecture.filters.searchSymbols[criterion] = XRaySearch.Symbol(name: name, path: path, line: line)
        setTemporaryFilter(criterion)
        openArchitecture()
        if let id = temporaryFilter?.id { architecture.filters.activate(filterId: id) }
    }

    /// Requests from the code viewer's margin panel.
    func handleCodeAction(_ action: String, payload: [String: Any], url: URL) {
        guard let content = host?.openTabContent(for: url) else { return }
        let root = project.root ?? url.deletingLastPathComponent()
        let path = codePath(for: url)
        let db = project.database
        switch action {
        case "explain":
            codeExplain.explain(path: path, content: content, root: root, directory: explainDirectory(for: url),
                                db: db)
        case "rate":
            let id = payload["filter"] as? String ?? ImportanceRater.importance.id
            guard let filter = aiFilters.first(where: { $0.id == id }) else { return }
            codeExplain.rate(path: path, content: content, filter: filter, root: root,
                             directory: explainDirectory(for: url), db: db)
        case "freshness":
            codeExplain.freshness(path: path, root: root, directory: explainDirectory(for: url))
        case "explainPR":
            architecture.review.explainPRFile(path: path, root: root, db: db)
        case "createFilter":
            createFilter(name: payload["name"] as? String ?? "", criterion: payload["criterion"] as? String ?? "")
        case "tempFilter":
            setTemporaryFilter(payload["criterion"] as? String ?? "")
        case "explainSymbol":
            guard let name = payload["name"] as? String else { return }
            explainSymbol(name: name, path: path, line: (payload["line"] as? NSNumber)?.intValue ?? 1)
        case "navDefinition", "navUsages", "navOpen", "navBack", "navForward", "askAI", "askStop":
            handleNavigation(action, payload: payload, url: url, path: path, root: root)
        default:
            break
        }
    }

    /// Go to definition, find usages, history and AI questions from the code viewer.
    private func handleNavigation(_ action: String, payload: [String: Any], url: URL, path: String, root: URL) {
        let line = (payload["line"] as? NSNumber)?.intValue ?? 1
        let here = CodeNavigationStore.Place(url: url.standardizedFileURL, line: line)
        let open: (URL, Int) -> Void = { [weak self] target, line in self?.host?.openFile(target, line: line, endLine: nil) }
        switch action {
        case "navDefinition":
            guard let name = payload["name"] as? String else { return }
            codeNav.goToDefinition(name: name, line: line, url: url, path: path, root: root, open: open)
        case "navUsages":
            guard let name = payload["name"] as? String else { return }
            codeNav.findUsages(name: name, url: url, path: path, root: root)
        case "navOpen":
            // A result from the viewer's list or a `path:line` in an AI answer: a file inside
            // the project only. A bare or partial path is looked up by its ending.
            guard let target = payload["path"] as? String, let targetLine = (payload["target"] as? NSNumber)?.intValue else { return }
            let base = root.standardizedFileURL.path + "/"
            let file = root.appendingPathComponent(target).standardizedFileURL
            if file.path.hasPrefix(base), FileManager.default.fileExists(atPath: file.path) {
                codeNav.jump(from: here, to: file, line: targetLine, open: open)
                return
            }
            let suffix = "/" + target.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            let current = path
            tasks.store(Task {
                let match = await Task.detached(priority: .userInitiated) { () -> String? in
                    let candidates = ArchitectureScanner.listFiles(root: root).filter { ("/" + $0).hasSuffix(suffix) }
                    // Nearest to the file the question was about.
                    let folder = (current as NSString).deletingLastPathComponent
                    return candidates.max { a, b in
                        a.commonPrefix(with: folder).count < b.commonPrefix(with: folder).count
                    }
                }.value
                guard let match, !Task.isCancelled else { return }
                codeNav.jump(from: here, to: root.appendingPathComponent(match), line: targetLine, open: open)
            }, for: "navOpen")
        case "navBack":
            codeNav.goBack(current: here, open: open)
        case "navForward":
            codeNav.goForward(current: here, open: open)
        case "askAI":
            guard let id = payload["id"] as? String, let question = payload["question"] as? String,
                  let snippet = payload["text"] as? String, !snippet.isEmpty else { return }
            let start = (payload["start"] as? NSNumber)?.intValue ?? 1
            let history = (payload["history"] as? [[String: String]]) ?? []
            codeNav.ask(id: id, question: question, snippet: snippet, start: start,
                        end: (payload["end"] as? NSNumber)?.intValue ?? start, path: path,
                        language: FileType.codeLanguage(for: url), history: history, url: url,
                        root: root, db: project.database)
        case "askStop":
            if let id = payload["id"] as? String { codeNav.stopAnswer(id: id) }
        default:
            break
        }
    }

    // MARK: - X-Ray tabs

    /// The store behind an X-Ray tab.
    func xrayStore(for scope: String) -> ArchitectureStore {
        if scope.isEmpty || scope == TabKind.pullRequestScope { return architecture }
        if let store = folderXRays[scope] { return store }
        let store = ArchitectureStore()
        store.projectRoot = project.root
        if let root = project.root {
            // Kept in the project's .dde, never inside the folder itself.
            let key = String(ContentHash.of(scope).prefix(24))
            let base = ProjectPaths.xrayFoldersFolder(root)
            store.persistenceFile = base.appendingPathComponent(key + ".json")
            store.cacheDirectory = ProjectPaths.xrayCacheFolder(root)
        }
        store.filters.temporaryFilter = temporaryFilter
        folderXRays[scope] = store
        return store
    }

    /// Every X-Ray store that exists (the project's and the folders').
    private var allXRayStores: [ArchitectureStore] { [architecture] + folderXRays.values }

    /// Root folder and database of an X-Ray scope (folder X-Rays keep no database).
    private func xrayContext(_ scope: String) -> (root: URL, db: SemanticDatabase?)? {
        guard let root = project.root else { return nil }
        if scope.isEmpty || scope == TabKind.pullRequestScope { return (root, project.database) }
        return (root.appendingPathComponent(scope), nil)
    }

    /// Open (or switch to) the project's X-Ray. The first time the folder is scanned;
    /// later openings show the stored result.
    func openArchitecture() {
        openXRayTab(scope: "")
    }

    private func openXRayTab(scope: String) {
        guard let root = project.root, let context = xrayContext(scope) else { return }
        host?.showXRayTab(scope: scope, root: root)
        xrayStore(for: scope).open(root: context.root, db: context.db)
    }

    /// A restored X-Ray tab shows what was cached, without a new scan or review during launch.
    func restoreCachedXRay(scope: String) {
        guard let context = xrayContext(scope) else { return }
        xrayStore(for: scope).restoreCached(root: context.root, db: context.db)
    }

    /// The PR X-Ray tab: the project's X-Ray seen through one change — what it touches,
    /// the links it adds or removes, and the AI's architectural reading of it.
    func openPRXRay(source: String?) {
        guard let root = project.root else { return }
        openXRayTab(scope: TabKind.pullRequestScope)
        if let source, !source.isEmpty {
            architecture.review.refreshPRSources(root: root)
            // A comparison with an earlier commit can span months of work: it is shown, and analysed when asked.
            architecture.review.analyzeWhenLoaded = HistoricalBaseline.commitHash(fromSourceId: source) == nil
            architecture.review.showPR(source, root: root, db: project.database)
        } else {
            // Nothing chosen yet: everything on this branch vs main, uncommitted included.
            architecture.review.selectDefaultSource = true
            architecture.review.refreshPRSources(root: root)
        }
    }

    /// "Review" on a pull request: its PR X-Ray, with the AI review started once it loads
    /// (unless turned off in Settings).
    func reviewPullRequest(_ number: Int) {
        architecture.review.reviewWhenLoaded = GitHubSettings.autoReview
        openPRXRay(source: "gh:\(number)")
    }

    /// Compare this checkout with another branch in the PR X-Ray. `reverse` shows what `ref` has that this
    /// branch lacks (read from `ref`, nothing is checked out); otherwise this branch's commits and uncommitted
    /// changes against `ref`.
    func compareBranch(_ ref: String, reverse: Bool) {
        guard let root = project.root, GitClient.isPlausibleBranchName(ref) else { return }
        let branch = host?.gitBranch ?? ""
        let current = branch.isEmpty ? "this checkout" : branch
        let title = reverse ? "\(ref) vs \(current): what \(ref) adds"
                            : "\(current) vs \(ref) (commits + uncommitted)"
        openXRayTab(scope: TabKind.pullRequestScope)
        // No AI run until asked: Analyze and Review are buttons in the view.
        architecture.review.showComparison(id: (reverse ? "rev:" : "cmp:") + ref, title: title, root: root, db: project.database)
        architecture.review.refreshPRSources(root: root)
    }

    /// X-Ray from the file tree. A folder gets its own X-Ray tab — its own structure,
    /// found and named inside it as if it were the project. A file opens with Explain
    /// (its sections, importance, freshness and filters).
    func openXRay(for url: URL) {
        guard let root = project.root?.standardizedFileURL else { return }
        let target = url.standardizedFileURL
        let isFolder = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isFolder else {
            host?.explainFile(target)
            return
        }
        openXRayTab(scope: target.path == root.path ? "" : project.relativePath(of: target))
    }

    /// "I need to understand …": the X-Ray's ⚡ search for the question — what takes part is
    /// marked in every view, the answer and its places are on the right, and a file opened from
    /// there shows the places inside it.
    func understandInXRay(_ question: String, attachments: [URL] = []) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = project.root, !text.isEmpty else { return }
        setTemporaryFilter(text)
        openArchitecture()
        if let filter = temporaryFilter {
            architecture.filters.understand(filter: filter, root: root, db: project.database, attachments: attachments)
            architecture.filters.activate(filterId: filter.id)
        }
    }

    // MARK: - Requests from an X-Ray page

    /// Requests from an X-Ray tab's web view, for the X-Ray of the active tab.
    func handleArchitectureAction(_ action: String, payload: [String: Any]) {
        guard let command = XRayCommand.parse(action, payload: payload) else { return }
        perform(command)
    }

    /// Carries out `command` on the X-Ray of the active tab (the project's when the active tab is not an X-Ray).
    func perform(_ command: XRayCommand) {
        // The X-Ray the active tab shows; nil when the active tab is not an X-Ray at all.
        var activeScope: String?
        if case .architecture(let s) = host?.activeTabKind { activeScope = s }
        let scope = activeScope ?? ""
        guard command.isAllowed(inScope: activeScope), let (root, db) = xrayContext(scope) else { return }
        let architecture = xrayStore(for: scope)
        switch command {
        case .operation(let operation):
            perform(operation, deploymentNodes: { architecture.snapshot?.view("deployment")?.nodes ?? [] })
        case .openFile(let request):
            openFile(request, root: root, architecture: architecture)
        case .rescan:
            architecture.scan(root: root, db: db)
        case .analyze:
            architecture.analyze(root: root, db: db)
        case .describeBook(let path):
            // Book view: "Describe this chapter" (path) or "Describe remaining chapters" (no path).
            architecture.describeBook(path: path, root: root, db: db)
        case .recursiveInsight(let relative):
            // Book panel: the insight of a part (folder) or chapter (document) of this X-Ray.
            guard let target = XRayCommand.insightTarget(relative, root: root) else { return }
            host?.startRecursiveInsight(at: target, title: nil)
        case .askBook(let question):
            setTemporaryFilter(question)
            if let filter = temporaryFilter {
                architecture.filters.understand(filter: filter, root: root, db: db)
                architecture.filters.activate(filterId: filter.id)
            }
        case .cancelAnalysis:
            architecture.cancelAnalysis()
        case .temporaryFilter(let criterion):
            setTemporaryFilter(criterion)
        case .openPRXRay(let source):
            openPRXRay(source: source)
        case .analyzePR(let again):
            architecture.review.analyzePR(root: root, db: db, fresh: again)
        case .historyCommits(let day):
            // Comparison by date: the commits of the calendar day chosen in the PR X-Ray ("YYYY-MM-DD").
            architecture.review.listHistory(day: day, root: root)
        case .compareWithCommit(let sha):
            // The comparison with a date opens in the comparison view, like a branch comparison, from the project's X-Ray
            // as well as from the PR X-Ray (BUG-110): it needs no pull request.
            if scope.isEmpty { openXRayTab(scope: TabKind.pullRequestScope) }
            architecture.review.compareWithCommit(sha: sha, root: root, db: db)
        case .prFileDiff(let path):
            architecture.review.showFileDiff(path: path)
        case .explainPRFile(let path):
            architecture.review.explainPRFile(path: path, root: root, db: db)
        case .askPR(let question, let path):
            architecture.review.askPR(question: question, path: path, root: root, db: db)
        case .filterSearch(let filter):
            architecture.filters.searchFilter(filterId: filter, root: root, db: db)
        case .showPR(let source):
            architecture.review.showPR(source, root: root)
        case .reviewPR(let again):
            if again {
                architecture.review.reviewAgain(root: root, db: db)
            } else {
                architecture.review.reviewPR(root: root, db: db)
            }
        case .prTasksToTerminal:
            // Typed at the assistant's prompt, not sent: check the list and press Enter.
            if let text = architecture.review.prTasksText() { _ = host?.sendToAssistant(text, submit: false) }
        case .copyPRTasks:
            if let text = architecture.review.prTasksText() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case .refreshPRSources:
            architecture.review.refreshPRSources(root: root)
        case .prAction(let op, let body, let method):
            // op: approve | requestChanges | comment | merge | close; method: merge | squash | rebase.
            guard GitHubClient.mergeMethods.contains(method) else { return }
            architecture.review.prAction(op, body: body, method: method, root: root)
        case .prFindingFix(let finding):
            fixInPullRequest(prompt: architecture.review.findingFixPrompt(path: finding.path, index: finding.index), architecture: architecture)
        case .prFixAll:
            fixInPullRequest(prompt: architecture.review.prTasksText(), architecture: architecture)
        case .prFindingExplain(let finding):
            architecture.review.explainFinding(path: finding.path, index: finding.index, db: db)
        case .prFindingComment(let finding):
            architecture.review.commentFinding(path: finding.path, index: finding.index, root: root)
        case .prFindingIssue(let finding):
            architecture.review.issueFromFinding(path: finding.path, index: finding.index, root: root)
        case .prFindingDismiss(let finding):
            architecture.review.dismissFinding(path: finding.path, index: finding.index)
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .setComponent(let path, let component):
            architecture.setComponent(path: path, component: component, db: db)
        case .rateImportance(let view, let parent, let filter):
            architecture.filters.rateImportance(viewId: view, parentId: parent, filterId: filter, root: root, db: db)
        case .createFilter(let name, let criterion):
            createFilter(name: name, criterion: criterion)
        case .deleteFilter(let id):
            deleteFilter(id: id)
        case .outlineFile(let path):
            architecture.outlineFile(path: path, root: root, db: db)
        case .saveSearchAnswer(let filterId):
            saveSearchAnswer(filterId: filterId, root: root, architecture: architecture)
        case .retryUnderstanding(let filter):
            architecture.filters.retryUnderstanding(filterId: filter, root: root, db: db)
        case .openUnderstandingSource(let filter, let sourceId):
            openUnderstandingSource(filterId: filter, sourceId: sourceId, root: root, architecture: architecture)
        case .explainEdge(let view, let source, let target, let kind, let label, let again):
            architecture.explainEdge(view: view, source: source, target: target, kind: kind, label: label,
                                     root: root, db: db, fresh: again)
        case .refreshCode:
            // The Code view's Refresh (DEC-002): the automatic pipeline now, forced.
            architecture.refreshCode(root: root, db: db)
        case .traceCode(let traceScope, let question):
            architecture.traceCode(scope: traceScope, question: question, root: root, db: db)
        case .describe(let view, let id):
            architecture.describe(viewId: view, nodeId: id, root: root, db: db)
        }
    }

    /// The project's operations strip: Run, Open, Edit, discovery and its proposals.
    private func perform(_ operation: XRayCommand.Operation, deploymentNodes: () -> [ArchNode]) {
        switch operation {
        case .run(let id): host?.operations()?.run(id: id)
        case .open(let id): host?.operations()?.openPanel(id: id)
        case .edit(let id): host?.operations()?.edit(id: id)
        case .add: host?.operations()?.edit(id: nil)
        case .adopt(let id): host?.projectOperations?.adoptDiscovered(id: id)
        case .discover:
            let nodes = deploymentNodes()
                .filter { $0.kind != "root" && $0.kind != "moduleRef" }
                .map { ProjectOperation.Node(id: $0.id, name: $0.name) }
            host?.projectOperations?.discover(nodes: nodes)
        case .cancelDiscovery: host?.projectOperations?.cancelDiscovery()
        case .dismissReport: host?.projectOperations?.dismissDiscoveryReport()
        case .acceptProposal(let index): host?.projectOperations?.acceptProposal(index: index)
        case .rejectProposal(let index): host?.projectOperations?.rejectProposal(index: index)
        case .addUnknown(let index): host?.operations()?.addUnknown(index: index)
        }
    }

    /// A file opened from the page, inside the X-Ray's folder or, for a folder X-Ray's answer, inside the open project.
    private func openFile(_ request: XRayCommand.OpenFile, root: URL, architecture: ArchitectureStore) {
        let path = request.path
        guard let url = XRayCommand.file(at: path, root: root, projectRoot: project.root ?? root) else { return }
        // From the PR X-Ray: the viewer opens on the change ("Pull request" lens), showing
        // a fetched pull request's own version of the file (which may not exist here).
        // From the ⚡ search's answer: the viewer opens on the search's places in the file.
        if request.fromSearch { architecture.filters.markSearchFocus(path: path) }
        if request.fromPR {
            architecture.review.markPRFocus(path: path)
            if let cached = architecture.review.prFileURL(path: path) {
                host?.openFile(cached, line: request.line, endLine: request.endLine)
                return
            }
            tasks.store(Task { @MainActor [weak self] in
                guard let self else { return }
                if let prFile = await self.architecture.review.resolvePRFileURL(path: path) {
                    guard !Task.isCancelled else { return }
                    self.host?.openFile(prFile, line: request.line, endLine: request.endLine)
                    return
                }
                guard !Task.isCancelled, FileManager.default.fileExists(atPath: url.path) else { return }
                self.show(url, line: request.line, endLine: request.endLine, find: request.find)
            }, for: "openPRFile")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        show(url, line: request.line, endLine: request.endLine, find: request.find)
    }

    /// Open `url` in the viewer, or show it in Finder when it cannot be opened; Markdown scrolls to a heading or to where the
    /// document mentions something.
    private func show(_ url: URL, line: Int?, endLine: Int?, find: String?) {
        guard FileType.isOpenable(url) else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        host?.openFile(url, line: line, endLine: endLine)
        if let text = find, !text.isEmpty, FileType.from(url: url) == .markdown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.host?.scrollToText(String(text.prefix(80)))
            }
        }
    }

    /// Send a fix request to the pull request's branch; the error, if any, is shown in an alert.
    private func fixInPullRequest(prompt: String?, architecture: ArchitectureStore) {
        guard let prompt else { return }
        let number = architecture.review.shownPRNumber
        tasks.store(Task { [weak self] in
            if let error = await self?.host?.fixInPullRequest(number, prompt: prompt) {
                let alert = NSAlert()
                alert.messageText = "Cannot fix in the pull request"
                alert.informativeText = error
                alert.runModal()
            }
        }, for: "fixInPullRequest")
    }

    /// Save an answer of the ⚡ search as a document of the project, and open it.
    private func saveSearchAnswer(filterId: String, root: URL, architecture: ArchitectureStore) {
        let author = host?.defaultAuthor ?? ""
        if architecture.filters.understandingAnswers[filterId] != nil {
            tasks.store(Task { [weak self] in
                if let file = await architecture.filters.saveUnderstanding(filterId: filterId, root: root, author: author) {
                    guard !Task.isCancelled else { return }
                    self?.host?.refreshFileTree()
                    self?.host?.openFile(file, line: nil, endLine: nil)
                }
            }, for: "saveUnderstanding")
            return
        }
        if let file = architecture.filters.saveSearchAnswer(filterId: filterId, root: root, author: author) {
            host?.refreshFileTree()
            host?.openFile(file, line: nil, endLine: nil)
        }
    }

    /// A source of an "I need to understand" answer: a document of the project, a pull request or a commit.
    private func openUnderstandingSource(filterId: String, sourceId: String, root: URL, architecture: ArchitectureStore) {
        guard let source = architecture.filters.understandingSource(filterId: filterId, sourceId: sourceId) else { return }
        if source.kind == .document {
            // Inside the X-Ray's folder, or (from a folder X-Ray) anywhere in the open project.
            if let path = UnderstandingAnswer.relativePath(source.path, root: root) {
                host?.openFile(root.appendingPathComponent(path), line: source.start, endLine: source.end)
            } else if let projectURL = project.root, let path = UnderstandingAnswer.relativePath(source.path, root: projectURL) {
                host?.openFile(projectURL.appendingPathComponent(path), line: source.start, endLine: source.end)
            }
        } else if source.kind == .pr || source.kind == .commit {
            if !source.url.isEmpty, UnderstandingAnswer.isGitHubURL(source.url, kind: source.kind, target: source.target),
               let url = URL(string: source.url) {
                NSWorkspace.shared.open(url)
            } else if source.kind == .commit {
                let hash = source.target
                guard hash.count == 40, hash.allSatisfy(\.isHexDigit) else { return }
                tasks.store(Task { [weak self] in
                    let result = await GitHubClient.execute(["show", "--format=fuller", "--stat", "--patch", hash, "--"], in: root, git: true)
                    guard result.status == 0, !Task.isCancelled else { return }
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("MarkView-commit-\(hash).md")
                    // Indent rather than fence: commit content may itself contain fences.
                    let text = "# Commit \(hash)\n\n" + result.stdout.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")
                    do { try AtomicFile.write(text, to: file); self?.host?.openFile(file, line: nil, endLine: nil) }
                    catch { AppLog.workspace.error("Could not open the commit document") }
                }, for: "commitDocument")
            }
        }
    }
}
