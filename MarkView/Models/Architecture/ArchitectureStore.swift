import Foundation
import CryptoKit
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// State behind the Architecture tab: the persisted snapshot (Modules, Deployment,
/// Docs views and documentation coverage), progress of scans and AI passes, and the
/// pull-request overlay.
@MainActor
final class ArchitectureStore: ObservableObject {
    /// Language for rating reasons; nil keeps the model's default (document language).
    /// Labels on the X-Ray diagram (names of subsystems, components, folders, deployment
    /// nodes) follow the language of the files they name — English for code and English
    /// material, Russian for Russian notes; every text — purposes, summaries, the system
    /// description, reasons — is in the AI language chosen in the toolbar.
    static var graphLanguage: String { "labels:source|text:" + ActionOutputLanguage.current }
    static var reasonLanguage: String? {
        ActionOutputLanguage.current == ActionOutputLanguage.documentLanguage ? nil : ActionOutputLanguage.current
    }
    static var graphLanguageLine: String {
        let text = ActionOutputLanguage.current == ActionOutputLanguage.documentLanguage
            ? "the language the project's documents and code comments mostly use"
            : ActionOutputLanguage.current
        return "Names and titles (the short labels drawn on the diagram) are in the language of the files they name: "
            + "use the \"name in\" language given for each item; name a subsystem in the language most of its items "
            + "use; English where none is given. Write every purpose, summary, description and reason in "
            + "\(text). Keep code identifiers, file paths and the fixed enum values of the JSON schema exactly as specified."
    }

    /// The Pull request X-Ray: its changes, the loaded change, its review and chat.
    private(set) lazy var review = ChangeReviewStore(host: self)
    /// The importance rating, the person's filters, the search and "I need to understand" answers.
    private(set) lazy var filters = XRayFilterStore(host: self)

    @Published private(set) var snapshot: ArchitectureSnapshot?
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    /// Bumped on every change the web view must re-render.
    @Published private(set) var revision = 0
    /// Live progress of the AI analysis. Sent to the web view on its own (throttled),
    /// so the large snapshot payload is not re-sent for every file the assistant reads.
    @Published private(set) var progress: AnalysisProgress?
    /// The work this store starts (`AR-19`), one key per kind: "open" (the stored snapshot, then a scan), "scan", "analysis" (every AI
    /// pass that holds the run flag), "refresh" (the wait of the automatic refresh), "outline" (the local file outlines), and per item
    /// "outline:<path>", "edge:<key>" with its "edge-refresh:<key>", "describe:<node>". A new start of a key replaces the work of the
    /// old one, `cancelAnalysis` ends the "analysis" key, and `reset` (a project switch, the window's close) ends them all, so nothing
    /// is committed after it.
    private let tasks = TaskBag()
    /// The lease on `busy`, `progress` and the run's own state: `beginRun` gives it out, `endRun` of a run that no longer holds it does
    /// nothing. A run cancelled by `reset` finishes after the flags were cleared, and the run that replaced it may own them by then.
    private var runToken = 0

    /// What the automatic code analysis of the project is doing (REQ-002 of
    /// automatic-code-architecture); the Code view shows it as one status line.
    enum AutomaticState: Equatable {
        case idle
        case scanning
        case analyzing(step: String)
        case done(Date)
        /// No CLI agent, or it is signed out (DEC-004).
        case unavailable(reason: String)
        /// The `xray.autoAnalyze` switch is off (DEC-001).
        case off
        /// The project exceeds the size cap (DEC-003); only the manual Refresh analyzes it.
        case tooLarge(files: Int)
        /// Nothing to analyze (for example no source files).
        case skipped(reason: String)
    }
    /// A change re-renders the web view: the status line is part of the payload.
    @Published private(set) var automaticState: AutomaticState = .idle {
        didSet { if oldValue != automaticState { revision += 1 } }
    }
    /// Timestamps behind the automatic refresh; `AutoAnalysisScheduler` decides, this store acts.
    private var scheduler = AutoAnalysisScheduler()
    /// Where the automatic analysis runs, set by `startAutomaticCodeAnalysis`; nil until then,
    /// so file changes of a project it never started for are ignored.
    private var automaticContext: (root: URL, db: SemanticDatabase?)?
    /// Reports changes below the project root (the file tree only sees its top level);
    /// started with `automaticContext`, stopped by `reset`.
    private var changeWatcher: ProjectChangeWatcher?
    /// A folder's own X-Ray is kept here (JSON) instead of the project database, and its
    /// AI answers are cached in `cacheDirectory` — both inside the project's `.dde`, so
    /// nothing is written into the folder itself.
    var persistenceFile: URL?
    var cacheDirectory: URL?
    /// Root folder of this X-Ray (the project or one of its folders), for the web view.
    private(set) var rootPath: String?
    /// The project a folder X-Ray belongs to; its assistant choice answers (BUG-021).
    var projectRoot: URL?
    /// The project whose assistant, model and X-Ray model this X-Ray uses.
    var project: URL? { projectRoot ?? rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    /// Answer characters per parallel AI call, summed into `progress.answerChars`.
    private var answerByCall: [Int: Int] = [:]

    struct AnalysisProgress: Codable {
        var step: Int
        var steps: Int
        var title: String
        /// What this step works on, e.g. "80 folders".
        var scope: String?
        var startedAt: Date
        var stepStartedAt: Date
        var filesRead = 0
        var searches = 0
        var answerChars = 0
        /// The assistant's latest action ("Reading src/app.ts").
        var current: String?
        /// Countable work of the current step: `done` of `total` `unit` (e.g. 3 of 8 parts).
        var done = 0
        var total = 0
        var unit: String?
        /// Who does the work, e.g. "Claude Code · sonnet".
        var assistant: String?
    }

    private var busy = false
    /// Signature of the deployment config files in the latest scan.
    private var pendingDeploymentSignature: String?
    /// Run the AI analysis once the scan started by `open` finishes, if never analysed.
    /// Node ids with an on-demand description in flight.
    private var describing: Set<String> = []
    /// What each file is made of (`XRayContent`), by project-relative path; drawn under
    /// the file boxes of the Logical view.
    private var outlines: [String: XRayContent.Outline] = [:]
    /// Files the assistant is outlining right now.
    private var outlining: Set<String> = []
    /// A new workspace, or the window's close: everything this store and its parts started stops and nothing of it is committed
    /// after this. A scan or analysis of the old workspace must neither commit nor clear the flags of the next run (R11): its work is
    /// cancelled and the run lease moves past its cleanup.
    func reset() {
        tasks.cancelAll()
        runToken += 1
        busy = false
        progress = nil
        review.reset()
        answerByCall = [:]
        scheduler = AutoAnalysisScheduler()
        automaticContext = nil
        changeWatcher?.stop()
        changeWatcher = nil
        automaticState = .idle
        filters.reset()
        rootPath = nil
        snapshot = nil
        outlines = [:]
        outlining = []
        describing = []
        edgeNotes = [:]
        status = nil
        error = nil
        revision += 1
    }

    // MARK: - Load and scan

    /// Show the stored architecture right away, then rescan in the background so
    /// the view catches up with code changed since. The scan is cheap (no AI);
    /// AI descriptions are kept and only changed modules are re-described later.
    func open(root: URL, db: SemanticDatabase?) {
        rootPath = root.standardizedFileURL.path
        tasks.store(Task {
            // The scan keeps the AI descriptions of the stored snapshot, so it starts once that is loaded.
            await loadStoredSnapshot(db: db, root: root)
            guard !Task.isCancelled, rootPath == root.standardizedFileURL.path else { return }
            scan(root: root, db: db)
            review.refreshPRSources(root: root)
        }, for: "open")
    }

    /// Window restoration displays the previous view without starting new AI work.
    func restoreCached(root: URL, db: SemanticDatabase?) {
        rootPath = root.standardizedFileURL.path
        tasks.store(Task {
            await loadStoredSnapshot(db: db, root: root)
            guard !Task.isCancelled, rootPath == root.standardizedFileURL.path else { return }
            // Local cached/declaration outlines restore drill-down without starting AI.
            outlineContents(root: root)
        }, for: "open")
    }

    /// The saved architecture, when nothing is loaded yet. The database is read on its own actor, so a slow read
    /// never holds the main thread; a snapshot that arrived meanwhile (or another project) wins.
    private func loadStoredSnapshot(db: SemanticDatabase?, root: URL) async {
        guard snapshot == nil else { return }
        let stored = await db?.loadArchitecture()
        guard !Task.isCancelled, snapshot == nil, rootPath == root.standardizedFileURL.path, let found = stored ?? loadPersisted() else { return }
        snapshot = found
        revision += 1
    }

    /// Take the run flag for a new scan or analysis; `endRun` with the returned token releases it.
    func beginRun() -> Int {
        busy = true
        error = nil
        runToken += 1
        return runToken
    }

    /// Release the run flag and progress, unless `reset` or a later run already owns them.
    func endRun(_ token: Int) {
        guard token == runToken else { return }
        busy = false
        progress = nil
        answerByCall = [:]
        setStatus(nil)
        // A file change that arrived during the run waits for its end (`.waitForRun`).
        armAutomaticRefresh()
    }

    /// Deterministic scan (no AI). Keeps AI descriptions and the Deployment view
    /// from the previous snapshot for nodes that still exist.
    func scan(root: URL, db: SemanticDatabase?) {
        guard !busy else { return }
        let token = beginRun()
        tasks.store(Task {
            _ = await performScan(root: root, db: db)
            // Explicit, not deferred: the outlines below run after the flag is released.
            endRun(token)
            // Contents: stored outlines at once, then new or changed files.
            if token == runToken { outlineContents(root: root) }
        }, for: "scan")
    }

    /// The scan itself, shared by `scan` and the automatic pipeline. Returns the scanner's
    /// result once it is committed, or nil when the run was cancelled or the store moved
    /// to another root meanwhile (nothing is committed then).
    private func performScan(root: URL, db: SemanticDatabase?) async -> ArchitectureScanner.Result? {
        setStatus("Scanning project…")
        let previous = snapshot
        let started = Date()
        progress = AnalysisProgress(step: 1, steps: 1, title: "Scanning the project", scope: nil,
                                    startedAt: started, stepStartedAt: started)
        var configured = ArchitectureScanner(root: root)
        configured.onProgress = { [weak self] phase, done, total in
            Task { @MainActor in
                guard let self, self.progress?.steps == 1 else { return }
                self.progress?.current = phase
                self.progress?.done = done
                self.progress?.total = total
                self.progress?.unit = total > 0 ? "files" : nil
            }
        }
        let scanner = configured
        let result = await Task.detached(priority: .userInitiated) { scanner.run() }.value
        // Cancelled by `reset` or moved to another workspace: commit nothing.
        guard !Task.isCancelled, rootPath == root.standardizedFileURL.path else { return nil }
        if progress?.steps == 1 { progress = nil }
        var modules = result.modules
        if let old = previous?.view("modules") {
            let byId = Dictionary(old.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for i in modules.nodes.indices {
                guard let before = byId[modules.nodes[i].id] else { continue }
                modules.nodes[i].summary = before.summary
                modules.nodes[i].role = before.role
                modules.nodes[i].summarySignature = before.summarySignature
                if before.kind != "file", before.name != modules.nodes[i].name, before.summary != nil {
                    modules.nodes[i].name = before.name
                }
            }
        }
        var views = [modules]
        if let deployment = previous?.view("deployment") { views.append(deployment) }
        views.append(Self.carryBookAnnotations(from: previous?.view("docs"), into: result.docs))
        var next = ArchitectureSnapshot(views: views, coverage: result.coverage, metrics: result.metrics,
                                        coverageReport: result.coverageReport,
                                        deploymentSignature: previous?.deploymentSignature,
                                        systemName: previous?.systemName, systemPurpose: previous?.systemPurpose,
                                        components: previous?.components ?? [],
                                        assignments: previous?.assignments ?? [:],
                                        overrides: previous?.overrides ?? [:],
                                        logicalSignature: previous?.logicalSignature,
                                        language: previous?.language,
                                        logicalDraft: previous?.logicalDraft ?? false,
                                        ratings: (previous?.ratings ?? [:]).mapValues {
                                            Self.keepBookRatings(XRayFilterStore.keepCurrentRatings($0, modules: modules), docs: result.docs)
                                        },
                                        deploymentHints: result.deploymentHints, scannedAt: Date(),
                                        enrichedAt: previous?.enrichedAt, gitHead: result.gitHead,
                                        codeSequences: previous?.codeSequences, codeModel: previous?.codeModel)
        let model = previous?.codeModel
        let sourceFileCount = automaticSourceFileCount(result.modules)
        next.codeCoverage = await Task.detached(priority: .userInitiated) {
            CodeArchitecture.coverage(modules: result.modules, model: model, skipped: result.skipped, capabilities: .current,
                                      sourceFileCount: sourceFileCount)
        }.value
        guard !Task.isCancelled, rootPath == root.standardizedFileURL.path else { return nil }
        pendingDeploymentSignature = result.deploymentSignature
        next = LogicalView.apply(next)
        commit(next, db: db)
        setStatus(nil)
        // Local structure is available without an assistant. AI enrichment starts
        // only from the visible Analyze action or the automatic pipeline.
        return result
    }

    /// The save in flight: snapshots reach the database in the order they were committed.
    private var databaseSave: Task<Void, Never>?

    func commit(_ next: ArchitectureSnapshot, db: SemanticDatabase?) {
        snapshot = next
        if let db {
            let previous = databaseSave
            databaseSave = Task {
                await previous?.value
                do { try await db.saveArchitecture(next) } catch {
                    self.error = "Could not save the architecture: \(error.localizedDescription)"
                }
            }
        }
        if db == nil, let file = persistenceFile { persist(next, to: file) }
        revision += 1
    }

    private static let snapshotEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Write a folder X-Ray to its JSON file (off the main thread; one-off filter ratings left out).
    private func persist(_ snapshot: ArchitectureSnapshot, to file: URL) {
        var stored = snapshot
        stored.ratings = stored.ratings.filter { !ImportanceRater.isTemporary($0.key) }
        guard let data = try? Self.snapshotEncoder.encode(stored) else { return }
        // task: writes the bytes already encoded; it ends on its own and must reach the disk even when the window closes meanwhile
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? AtomicFile.write(data, to: file)
        }
    }

    private func loadPersisted() -> ArchitectureSnapshot? {
        guard let file = persistenceFile, let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return StoredJSON.decode(ArchitectureSnapshot.self, from: data, using: decoder, owner: "X-Ray snapshot")
    }

    /// Where AI answers for this X-Ray are cached.
    func answerCache(_ root: URL) -> URL {
        cacheDirectory ?? ProjectPaths.xrayCacheFolder(root)
    }

    func setStatus(_ text: String?) {
        status = text
        revision += 1
    }

    // MARK: - AI analysis

    /// Build the X-Ray. The structure comes from how the project is connected (imports,
    /// note links, co-change; `XRayCluster`) and is shown within seconds; the assistant
    /// then only names the clusters — chunks in parallel, deployment alongside — and
    /// groups them into subsystems. No AI step reads files, and every answer is cached
    /// by its input, so re-analysing redoes only what changed.
    func analyze(root: URL, db: SemanticDatabase?) {
        guard !busy, let current = snapshot, let modules = current.view("modules") else { return }
        let token = beginRun()
        let started = Date()
        tasks.store(Task {
            defer { endRun(token) }
            var next = current
            do {
                beginStep(1, "Finding the structure", started: started)
                let (plan, clusters) = await Task.detached(priority: .userInitiated) { () -> (XRayDigest.Plan, [XRayCluster.Cluster]) in
                    let plan = XRayDigest.plan(root: root, modules: modules)
                    return (plan, XRayCluster.clusters(plan: plan, modules: modules, root: root))
                }.value
                try Task.checkCancellation()
                // The clusters under provisional names, on screen right away.
                if next.components.isEmpty || next.logicalDraft {
                    next = LogicalView.applyClusters(clusters, names: [:], grouping: nil, to: next)
                    commit(next, db: db)
                }

                beginStep(2, "Naming components", started: started)
                setProgressScope("\(clusters.count) components from \(plan.units.count) folders")
                let deploymentBase = next
                async let deployment = mapDeployment(in: deploymentBase, plan: plan, root: root, db: db)
                next = try await nameClusters(clusters, plan: plan, base: next, root: root, db: db)
                commit(next, db: db)

                beginStep(3, "Mapping deployment", started: started)
                var deploymentError: String?
                do {
                    if let view = try await deployment {
                        next.views.removeAll { $0.id == "deployment" }
                        next.views.insert(view, at: next.views.firstIndex { $0.id == "docs" } ?? next.views.count)
                        next.deploymentSignature = pendingDeploymentSignature ?? next.deploymentSignature
                    }
                } catch let empty as EmptyDeploymentMap {
                    // Keep the previous map and its signature, so the next Analyze maps again.
                    deploymentError = empty.localizedDescription
                }
                next.enrichedAt = Date()
                next.language = Self.graphLanguage
                commit(next, db: db)
                if let deploymentError { self.error = deploymentError }

                beginStep(4, "Annotating the book", started: started)
                try await annotateBook(root: root, db: db, only: nil)

                beginStep(5, "Indexing file contents", started: started)
                // The outlines of the scan's own build are superseded by this one, which shows its progress.
                tasks.cancel(key: "outline")
                await buildOutlines(root: root)
            } catch is CancellationError {
                // Keep the structure found so far (shown live, not yet saved).
                // Not after `reset`: what the store shows then is another workspace's.
                if token == runToken, let found = snapshot, found.components.map(\.id) != next.components.map(\.id) { commit(found, db: db) }
            } catch {
                self.error = "Analysis failed: \(error.localizedDescription)"
            }
            setStatus(nil)
        }, for: "analysis")
    }

    /// Stop a running analysis; the assistant's process is terminated.
    func cancelAnalysis() {
        tasks.cancel(key: "analysis")
    }

    private func beginStep(_ step: Int, _ title: String, started: Date, steps: Int = 5) {
        setStatus(title + "…")
        let tool = AIAssistantPreferences.backend(project: project)
        progress = AnalysisProgress(step: step, steps: steps, title: title, scope: nil,
                                    startedAt: started, stepStartedAt: Date(),
                                    assistant: AIAssistantPreferences.summary(tool: tool, model: AIAssistantPreferences.xrayModel(for: tool, project: project) ?? ""))
    }

    private func setProgressScope(_ scope: String) {
        progress?.scope = scope
    }

    /// Forwards the assistant's actions to `progress` (called from the CLI's reader queue).
    private func activityHandler(root: URL, call: Int = 0) -> @Sendable (CLICompletion.Activity) -> Void {
        let prefix = root.standardizedFileURL.path + "/"
        return { [weak self] activity in
            Task { @MainActor in
                guard let self, self.progress != nil else { return }
                switch activity {
                case .read(let path):
                    self.progress?.filesRead += 1
                    self.progress?.current = "Reading " + (path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)
                case .search(let pattern):
                    self.progress?.searches += 1
                    self.progress?.current = "Searching \"\(pattern.prefix(60))\""
                case .run(let command):
                    self.progress?.filesRead += 1
                    self.progress?.current = "Running " + String(command.prefix(80))
                case .answerDelta, .webSearch, .webFetch:
                    break
                case .thinking:
                    self.progress?.current = "Thinking"
                case .writing(let chars):
                    // Parallel calls each report their own total.
                    self.answerByCall[call] = chars
                    self.progress?.answerChars = self.answerByCall.values.reduce(0, +)
                    self.progress?.current = "Writing the result"
                }
            }
        }
    }

    /// `progress` as a JSON object literal, or "null".
    func progressJSON() -> String {
        guard let progress else { return "null" }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(progress)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// The assistant mapped no deployment nodes, even when asked twice.
    struct EmptyDeploymentMap: LocalizedError {
        var errorDescription: String? {
            "The assistant returned an empty deployment map; the previous map was kept. Click Analyze to try again."
        }
    }

    /// The Deployment view, or nil when the build/deploy config files did not change
    /// since the last mapping. The config files are inlined; the assistant reads nothing.
    /// Throws `EmptyDeploymentMap` rather than returning a view with no nodes.
    private func mapDeployment(in snapshot: ArchitectureSnapshot, plan: XRayDigest.Plan, root: URL,
                               db: SemanticDatabase?) async throws -> ArchView? {
        guard let modules = snapshot.view("modules") else { return nil }
        // A stored map with only its root (an empty answer before BUG-020) counts as missing.
        if snapshot.view("deployment")?.nodes.contains(where: { $0.kind != "root" }) == true,
           let signature = pendingDeploymentSignature ?? snapshot.deploymentSignature,
           signature == snapshot.deploymentSignature {
            return nil
        }
        let top = plan.units.sorted { ($0.loc, $1.path) > ($1.loc, $0.path) }.prefix(60)
            .map { "- \($0.nodeId) | \($0.path.isEmpty ? "(root)" : $0.path)\($0.package.map { " | " + $0 } ?? "")" }
            .joined(separator: "\n")
        let configs = await Task.detached { XRayDigest.configExcerpts(root: root, paths: snapshot.deploymentHints) }.value
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "nodes": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string", "description": "Short slug, unique."],
                            "name": ["type": "string"],
                            "kind": ["type": "string", "enum": ["service", "app", "job", "datastore", "queue", "client", "infra", "external"]],
                            "tech": ["type": "string", "description": "Runtime or product, e.g. \"Node 20 on Cloud Run\", \"PostgreSQL\", \"macOS app\"."],
                            "summary": ["type": "string"],
                            "parent": ["type": "string", "description": "id of the containing node (cluster, host, app bundle) or empty."],
                            "runs": ["type": "array", "items": ["type": "string"], "description": "Module ids from the list that run inside this node."],
                        ],
                        "required": ["id", "name", "kind", "tech", "summary", "parent", "runs"],
                    ],
                ],
                "edges": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "source": ["type": "string"],
                            "target": ["type": "string"],
                            "label": ["type": "string", "description": "Protocol or purpose, e.g. \"HTTPS\", \"SQL\", \"spawns\"."],
                        ],
                        "required": ["source", "target", "label"],
                    ],
                ],
            ],
            "required": ["nodes", "edges"],
        ]
        var request = CLICompletion.Request(
            project: project,
            prompt: """
            \(plan.overview)

            Build, deploy and runtime config files:
            \(configs.isEmpty ? "(none found)" : configs)

            Modules (id | path | package):
            \(top)
            """,
            systemPrompt: """
            You map how a software project is deployed and run: processes, services, apps, jobs, datastores, \
            queues, clients and external services, which modules run where and how they talk to each other. \
            Work only from the config files and module list given. Describe what actually exists — a desktop \
            app, a CLI, a web service, a serverless function set — without inventing infrastructure the files \
            do not show. Keep summaries to one short sentence.
            """ + "\n\n" + Self.graphLanguageLine,
            jsonSchema: schema)
        request.timeout = 300
        let nodeIds = { (object: [String: Any]) in
            Set((object["nodes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        }
        let object = try await xrayCall(request, root: root, db: db, call: 100, accept: { !nodeIds($0).isEmpty })
        let ids = nodeIds(object)
        guard !ids.isEmpty else { throw EmptyDeploymentMap() }
        let rawNodes = object["nodes"] as? [[String: Any]] ?? []
        let rawEdges = object["edges"] as? [[String: Any]] ?? []
        let moduleById = Dictionary(modules.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var nodes = [ArchNode(id: "p:", parent: nil, kind: "root", name: root.lastPathComponent)]
        for raw in rawNodes {
            guard let id = raw["id"] as? String else { continue }
            let parent = (raw["parent"] as? String).flatMap { ids.contains($0) && $0 != id ? "p:" + $0 : nil } ?? "p:"
            nodes.append(ArchNode(id: "p:" + id, parent: parent, kind: raw["kind"] as? String ?? "service",
                                  name: raw["name"] as? String ?? id, summary: raw["summary"] as? String,
                                  tech: raw["tech"] as? String))
            // Modules running inside this node become its children, so drilling in shows them.
            for moduleId in raw["runs"] as? [String] ?? [] {
                guard let module = moduleById[moduleId] else { continue }
                nodes.append(ArchNode(id: "p:" + id + "|" + moduleId, parent: "p:" + id, kind: "moduleRef",
                                      name: module.name, path: module.path, loc: module.loc, files: module.files,
                                      summary: module.summary, role: module.role))
            }
        }
        let edges = rawEdges.compactMap { raw -> ArchEdge? in
            guard let source = raw["source"] as? String, let target = raw["target"] as? String,
                  ids.contains(source), ids.contains(target), source != target else { return nil }
            return ArchEdge(source: "p:" + source, target: "p:" + target, kind: "calls", label: raw["label"] as? String)
        }
        return ArchView(id: "deployment", nodes: nodes, edges: edges)
    }

    // MARK: - Logical view

    private static let layers = ["presentation", "application", "domain", "data", "infrastructure",
                                 "integration", "platform", "tooling", "tests", "docs"]

    private static let systemSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": ["type": "string"],
            "purpose": ["type": "string", "description": "2-3 sentences: what the system does, for whom, and its main parts."],
        ],
        "required": ["name", "purpose"],
    ]

    /// One assistant call through the X-Ray settings (fast model, low effort, no tools),
    /// answered from `.dde/cache/xray` when the same input was analysed before.
    /// An answer `accept` rejects is neither cached nor taken from the cache, and is asked
    /// once more; the last answer is returned either way, for the caller to judge.
    func xrayCall(_ request: CLICompletion.Request, root: URL, db: SemanticDatabase?,
                          call: Int, fresh: Bool = false, trackProgress: Bool = true,
                          accept: (([String: Any]) -> Bool)? = nil) async throws -> [String: Any] {
        try request.validateSchema()
        var prepared = request
        prepared.model = request.xrayModel
        prepared.effort = "low"
        let cache = answerCache(root)
        let file = Self.answerFile(for: prepared, in: cache)
        let usable = { (object: [String: Any]) in !object.isEmpty && (accept?(object) ?? true) }
        if !fresh, let data = try? Data(contentsOf: file),
           let cached = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], usable(cached) {
            return cached
        }

        let opName = prepared.label.isEmpty ? "xray" : prepared.label
        let progressHandler = trackProgress ? activityHandler(root: root, call: call) : nil
        var lastCandidate: [String: Any] = [:]
        let operation = AIOperation<CLICompletion.Request, AIRawJSONObject>(
            name: opName,
            maxRepairAttempts: accept == nil ? 0 : 1,
            allowTextSalvage: prepared.jsonSchema == nil,
            buildRequest: { $0 },
            validate: { _, decoded in
                lastCandidate = decoded.dictionary
                guard usable(decoded.dictionary) else {
                    throw AIOperationError.validationFailed(
                        operation: opName,
                        reason: "Response did not contain required fields"
                    )
                }
            },
            onResult: { [db] result in await MainActor.run { result.record(in: db) } }
        )

        do {
            let (decoded, _) = try await operation.execute(prepared, onActivity: progressHandler)
            let object = decoded.dictionary
            if let data = try? JSONSerialization.data(withJSONObject: object) {
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try? AtomicFile.write(data, to: file)
            }
            return object
        } catch is AIOperationError {
            return lastCandidate
        }
    }

    /// Where the answer to `request` is cached: one key for every X-Ray call, from the
    /// CLI, model, system prompt, prompt and schema. `context` joins the key when a call
    /// depends on more than its prompt (the code analysis and traces read the source,
    /// so they carry the Modules signature); empty, the key of older answers is unchanged.
    nonisolated private static func answerFile(for request: CLICompletion.Request, context: String = "", in cache: URL) -> URL {
        var parts = [request.tool.rawValue, request.model ?? "", request.systemPrompt ?? "", request.prompt,
                     (try? JSONSerialization.data(withJSONObject: request.jsonSchema ?? [:], options: .sortedKeys))
                         .map { String(decoding: $0, as: UTF8.self) } ?? ""]
        if !context.isEmpty { parts.append(context) }
        let key = parts.joined(separator: "\u{1}")
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        return cache.appendingPathComponent(hash + ".json")
    }

    /// A validated answer of the code analysis or a trace, cached as the JSON of its
    /// decoded value under the key of the request that produced it (off the main thread).
    nonisolated private static func cachedValue<T: Decodable & Sendable>(_ type: T.Type, at file: URL) async -> T? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return StoredJSON.decode(type, from: data, owner: "X-Ray answer cache")
        }.value
    }

    nonisolated private static func cache<T: Encodable>(_ value: T, at file: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        // task: writes the bytes already encoded; it ends on its own and must reach the disk even when the window closes meanwhile
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? AtomicFile.write(data, to: file)
        }
    }

    // MARK: Naming the clusters

    /// Clusters per naming call: a short answer each, and the calls run side by side.
    private static let clustersPerCall = 35

    private static let groupingSchema: [String: Any] = [
        "type": "array",
        "items": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "Short lowercase slug."],
                "name": ["type": "string"],
                "purpose": ["type": "string", "description": "One sentence."],
                "layer": ["type": "string", "enum": layers],
                "components": ["type": "array", "items": ["type": "string"], "description": "Cluster ids in this subsystem."],
                "importance": ["type": "string", "enum": ImportanceRater.importance.levels],
            ],
            "required": ["id", "name", "purpose", "layer", "components", "importance"],
        ],
    ]

    static func clusterNamingSchema(single: Bool) -> [String: Any] {
        let clusterSchema: [String: Any] = [
            "type": "array",
            "items": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Cluster id from the list."],
                    "name": ["type": "string", "description": "Logical name, 1-4 words, e.g. \"Order routing\"."],
                    "purpose": ["type": "string", "description": "At most 10 words: its responsibility."],
                    "layer": ["type": "string", "enum": Self.layers],
                    "mergeInto": ["type": "string", "description": "Id of another listed cluster it clearly belongs with, else empty."],
                    "importance": ["type": "string", "enum": ImportanceRater.importance.levels,
                                   "description": "critical: core the product cannot work without, or money/data/security; low: tooling, tests, samples."],
                ],
                "required": ["id", "name", "purpose", "layer", "mergeInto", "importance"],
            ],
        ]
        var properties: [String: Any] = ["clusters": clusterSchema]
        var required = ["clusters"]
        if single {
            properties["system"] = Self.systemSchema
            properties["subsystems"] = Self.groupingSchema
            required += ["system", "subsystems"]
        }
        return ["type": "object", "properties": properties, "required": required]
    }

    private func nameClusterChunk(prompt: String, system: String, single: Bool, root: URL,
                                  db: SemanticDatabase?, index: Int) async throws -> AIRawJSONObject {
        var request = CLICompletion.Request(project: project, prompt: prompt, systemPrompt: system,
                                            jsonSchema: Self.clusterNamingSchema(single: single))
        request.timeout = 240
        return try AIRawJSONObject(await xrayCall(request, root: root, db: db, call: index))
    }

    /// Name every cluster (in parallel chunks), then group them into subsystems. The
    /// structure on screen is updated as each answer lands.
    private func nameClusters(_ clusters: [XRayCluster.Cluster], plan: XRayDigest.Plan, base: ArchitectureSnapshot,
                              root: URL, db: SemanticDatabase?) async throws -> ArchitectureSnapshot {
        let single = clusters.count <= Self.clustersPerCall
        let chunks = stride(from: 0, to: clusters.count, by: Self.clustersPerCall)
            .map { Array(clusters[$0..<min($0 + Self.clustersPerCall, clusters.count)]) }
        progress?.total = chunks.count + (single ? 0 : 1)
        progress?.unit = "calls"
        let subsystemLanguage = LogicalView.projectNameLanguage(plan)
        let task = single
            ? "Name each cluster, then group the clusters into 3-8 SUBSYSTEMS by responsibility (every cluster in exactly one), and name the whole system and say in 2-3 sentences what it does. Subsystem and system names in \(subsystemLanguage)."
            : "Name each cluster. They are part of a larger codebase; subsystems are formed later."
        let system = """
        You are a software architect. The project's folders were already clustered by how they are \
        connected (imports, links, files changed together); each cluster is one logical component. \(task) \
        Clusters with the same "group" are closely related. Use mergeInto only for a cluster that is clearly \
        a fragment of another listed one. Be concise. Work only from the listing.
        """ + "\n\n" + Self.graphLanguageLine

        var names: [String: [String: Any]] = [:]
        var grouping: [String: Any]?
        var latest = base
        try await withThrowingTaskGroup(of: AIRawJSONObject.self) { group in
            for (index, chunk) in chunks.enumerated() {
                let prompt = plan.overview + "\n\nClusters:\n" + chunk.map { LogicalView.clusterLine($0, plan: plan) }.joined(separator: "\n")
                group.addTask {
                    try await self.nameClusterChunk(prompt: prompt, system: system, single: single, root: root, db: db, index: index)
                }
            }
            for try await answered in group {
                let answer = answered.dictionary
                for item in answer["clusters"] as? [[String: Any]] ?? [] {
                    if let id = item["id"] as? String { names[id] = item }
                }
                if single { grouping = answer }
                progress?.done += 1
                progress?.current = "Named \(names.count) of \(clusters.count) components"
                latest = LogicalView.applyClusters(clusters, names: names, grouping: grouping, to: base)
                snapshot = latest       // live; saved at the end
                revision += 1
            }
        }
        guard !single else { return latest }

        // Subsystems over all named clusters: one short call.
        progress?.current = "Grouping into subsystems"
        let lines = clusters.map { cluster -> String in
            let item = names[cluster.id]
            return "- \(cluster.id) (group \(cluster.group); name in \(LogicalView.nameLanguage(cluster, plan: plan))): \(item?["name"] as? String ?? cluster.id) — \(item?["purpose"] as? String ?? "")"
        }
        var request = CLICompletion.Request(
            project: project,
            prompt: plan.overview + "\n\nComponents:\n" + lines.joined(separator: "\n"),
            systemPrompt: """
            You are a software architect. Group these components into 3-8 SUBSYSTEMS by responsibility (every \
            component id in exactly one), then name the whole system and say in 2-3 sentences what it does. \
            Components with the same "group" are closely related. Subsystem and system names in \(LogicalView.projectNameLanguage(plan)). \
            Be concise.
            """ + "\n\n" + Self.graphLanguageLine,
            jsonSchema: ["type": "object",
                         "properties": ["system": Self.systemSchema, "subsystems": Self.groupingSchema],
                         "required": ["system", "subsystems"]])
        request.timeout = 180
        grouping = try await xrayCall(request, root: root, db: db, call: chunks.count)
        progress?.done += 1
        return LogicalView.applyClusters(clusters, names: names, grouping: grouping, to: base)
    }

    /// Move a folder or file to another component (user override), or back to the
    /// AI's choice when `component` is empty.
    func setComponent(path: String, component: String, db: SemanticDatabase?) {
        guard var next = snapshot else { return }
        if component.isEmpty { next.overrides[path] = nil } else { next.overrides[path] = component }
        next = LogicalView.apply(next)
        commit(next, db: db)
    }

    private func withCodeArchitecture(_ snapshot: ArchitectureSnapshot) -> ArchitectureSnapshot {
        var next = snapshot
        next.views.removeAll { $0.id == "code" }
        next.views.append(CodeArchitecture.view(snapshot))
        return next
    }

    /// Read the code itself to infer responsibilities, rather than treating the
    /// document/commit clusters as architectural layers.
    func analyzeCode(root: URL, db: SemanticDatabase?) {
        guard !busy, Self.codeFiles(in: snapshot) != nil else { return }
        let token = beginRun()
        tasks.store(Task {
            defer { endRun(token) }
            _ = await performCodeAnalysis(root: root, db: db)
        }, for: "analysis")
    }

    /// Source files of the Modules view, for the code analysis; nil without a scan or code.
    private static func codeFiles(in snapshot: ArchitectureSnapshot?) -> (modules: ArchView, files: [String])? {
        guard let modules = snapshot?.view("modules") else { return nil }
        let files = modules.nodes.filter { $0.kind == "file" && $0.language != "markdown" }.compactMap(\.path).sorted()
        return files.isEmpty ? nil : (modules, files)
    }

    enum CodeAnalysisOutcome: Equatable {
        /// The model was committed; `fromCache` when no CLI call was needed.
        case analyzed(fromCache: Bool)
        case failed
        case cancelled
    }

    /// The code analysis itself, shared by the manual action and the automatic pipeline.
    /// Runs inside the caller's run (flag, progress and task are the caller's).
    private func performCodeAnalysis(root: URL, db: SemanticDatabase?) async -> CodeAnalysisOutcome {
        guard let code = Self.codeFiles(in: snapshot) else { return .failed }
        let (modules, files) = code
        beginStep(1, "Reading the code architecture", started: Date(), steps: 1)
        let signature = modules.nodes.first { $0.id == "m:" }?.signature
        var fromCache = true
        do {
            let evidence = await Task.detached(priority: .userInitiated) { CodeArchitecture.sourceEvidence(root: root, modules: modules) }.value
            try Task.checkCancellation()
            let prompt = CodeArchitecture.prompt(root: root, files: files, evidence: evidence)
            let project = project
            let tool = AIAssistantPreferences.backend(project: project)
            let xrayModel = AIAssistantPreferences.xrayModel(for: tool, project: project)
            let systemPrompt = "You explain architecture grounded in source code. Read files, do not modify them. Return only the schema JSON.\n" + Self.graphLanguageLine
            func request(_ attempt: String) -> CLICompletion.Request {
                var request = CLICompletion.Request(project: project, prompt: attempt, systemPrompt: systemPrompt,
                                                    jsonSchema: CodeArchitecture.schema, readableFolder: root)
                request.timeout = 900; request.effort = "medium"; request.label = "code-architecture"
                request.model = xrayModel
                return request
            }
            // The same prompt over the same source was answered before: no CLI call.
            let cacheRequest = request(prompt)
            try cacheRequest.validateSchema()
            let answerFile = Self.answerFile(for: cacheRequest, context: signature ?? "", in: answerCache(root))
            var model: CodeArchitectureModel?
            if let cached = await Self.cachedValue(CodeArchitectureModel.self, at: answerFile),
               (try? await Task.detached { try CodeArchitecture.validateModel(cached, modules: modules, root: root) }.value) != nil {
                model = cached
            }
            // The most recent answer that decoded, kept for the grounding fallback below.
            var lastParsed: CodeArchitectureModel?
            if model == nil {
                try Task.checkCancellation()
                fromCache = false
                // Asked twice at most: the second time with the problems of the first answer and the answer itself.
                let operation = AIOperation<String, CodeArchitectureModel>(
                    name: "code-architecture",
                    maxRepairAttempts: 1,
                    buildRequest: request,
                    parse: { _, result, _ in try CodeArchitecture.decode(result) },
                    validate: { _, parsed, _ in
                        lastParsed = parsed
                        try await Task.detached { try CodeArchitecture.validateModel(parsed, modules: modules, root: root) }.value
                    },
                    repair: { [weak self] context in
                        self?.progress?.current = "Refining component ownership and source evidence"
                        return request(CodeArchitecture.repairPrompt(base: prompt, answer: context.previousAnswer, error: context.error))
                    },
                    onResult: { result in await MainActor.run { result.record(in: db) } })
                do {
                    let (parsed, _) = try await operation.execute(prompt, onActivity: activityHandler(root: root))
                    Self.cache(parsed, at: answerFile)
                    model = parsed
                } catch let error as DiagramAI.Failure where lastParsed != nil {
                    // Last resort for an answer that is sound apart from its citations: keep the
                    // assistant's structure and read a real definition line out of the code each
                    // component already owns, then validate again. A whole analysis is not thrown
                    // away over a line number the model could not get right twice (BUG-046).
                    let previous = lastParsed!
                    let grounded = await Task.detached { () -> CodeArchitectureModel? in
                        let repaired = CodeArchitecture.groundEvidence(previous, modules: modules, root: root)
                        return (try? CodeArchitecture.validateModel(repaired, modules: modules, root: root)) == nil ? nil : repaired
                    }.value
                    guard let grounded else { throw error }
                    Self.cache(grounded, at: answerFile)
                    model = grounded
                }
            }
            try Task.checkCancellation()
            guard var model, rootPath == root.standardizedFileURL.path, var next = snapshot else { return .cancelled }
            // Scenarios are filtered, not repaired: a dropped one becomes a coverage reason.
            model = CodeArchitecture.withAcceptedScenarios(model, modules: modules)
            model.signature = signature
            model.analyzedAt = Date()
            next.codeModel = model
            let skipped = next.codeCoverage?.skipped ?? []
            let analyzed = model
            let sourceFileCount = automaticSourceFileCount(modules)
            next.codeCoverage = await Task.detached(priority: .userInitiated) {
                CodeArchitecture.coverage(modules: modules, model: analyzed, skipped: skipped, capabilities: .current,
                                          sourceFileCount: sourceFileCount)
            }.value
            guard !Task.isCancelled, rootPath == root.standardizedFileURL.path else { return .cancelled }
            commit(next, db: db)
            return .analyzed(fromCache: fromCache)
        } catch is CancellationError {
            // Keep the previous architecture when stopped.
            return .cancelled
        } catch {
            // A CLI run ended by the cancellation may report its own error: not the user's concern.
            guard !Task.isCancelled else { return .cancelled }
            self.error = "Could not analyze the code: \(error.localizedDescription)"
            return .failed
        }
    }

    /// The source file count behind the size cap of the automatic analysis (DEC-003), for
    /// the coverage reasons; nil for a folder X-Ray, which is never analyzed automatically.
    private func automaticSourceFileCount(_ modules: ArchView) -> Int? {
        projectRoot == nil ? modules.nodes.filter { $0.kind == "file" && $0.language != "markdown" }.count : nil
    }

    /// Trace one scenario with the project's existing read-only assistant. A failed
    /// or cancelled attempt keeps the last successful diagram for this scope.
    func traceCode(scope: String, question: String, root: URL, db: SemanticDatabase?) {
        guard !busy, let current = snapshot else { return }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 4000 else { return }
        let view = CodeArchitecture.view(withContents(current))
        guard let selected = view.nodes.first(where: { $0.id == scope }) else { return }
        let byID = Dictionary(view.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let paths = view.nodes.filter { node in
            guard node.kind == "file" else { return false }
            var cursor: String? = node.id
            var seen = Set<String>()
            while let id = cursor, seen.insert(id).inserted {
                if id == scope { return true }
                cursor = byID[id]?.parent
            }
            return node.path == selected.path && selected.path != nil
        }.compactMap(\.path).sorted()
        guard !paths.isEmpty, let modules = current.view("modules") else { return }
        let token = beginRun()
        let started = Date()
        beginStep(1, "Tracing " + selected.name, started: started, steps: 1)
        setProgressScope(question)
        tasks.store(Task {
            defer { endRun(token) }
            do {
                let diagram = try await traceSequence(name: selected.name, question: question, paths: paths,
                                                      modules: modules, root: root, db: db)
                try Task.checkCancellation()
                guard rootPath == root.standardizedFileURL.path, var next = snapshot else { return }
                var sequences = next.codeSequences ?? []
                sequences.removeAll { !$0.auto && $0.scope == scope && $0.diagram.question == diagram.question }
                sequences.append(CodeSequence(scope: scope, diagram: diagram, modules: modules, auto: false))
                next.codeSequences = Self.boundedSequences(sequences)
                commit(next, db: db)
            } catch is CancellationError {
                // Previously saved traces stay available.
            } catch {
                self.error = "Could not trace the scenario: \(error.localizedDescription)"
            }
        }, for: "analysis")
    }

    /// Manual traces kept per project; automatic ones are bounded by `CodeArchitecture.maxScenarios`.
    private static let maxManualSequences = 30

    /// Automatic sequences first, then the last `maxManualSequences` manual traces, so
    /// a new manual trace is always the last entry.
    private static func boundedSequences(_ sequences: [CodeSequence]) -> [CodeSequence] {
        sequences.filter(\.auto) + sequences.filter { !$0.auto }.suffix(maxManualSequences)
    }

    /// The trace itself, shared by the manual action and the automatic run: the
    /// cached diagram of this question, candidate files and source state (no CLI
    /// call), or a fresh one from `DiagramAI`. Validated against the project either way.
    private func traceSequence(name: String, question: String, paths: [String], modules: ArchView,
                               root: URL, db: SemanticDatabase?) async throws -> DiagramSpec {
        let prompt = DiagramAI.prompt(kind: .sequence, instruction: """
        Trace this scenario in source code: \(question)
        Start in this scope: \(name).
        Candidate source files (follow calls outside this set when needed):
        \(paths.prefix(150).joined(separator: "\n"))
        Use 2-12 participants and at most 24 messages. Return edges in execution order,
        labelled "1. ...", "2. ...", etc. Repeated calls between participants are allowed.
        Every internal participant's source and every message's evidence MUST be a real
        project-relative source file with a valid :line suffix. Read the actual code;
        do not derive execution order from imports. Describe one possible static path,
        not an observed runtime trace. State conditions, uncertainty and omitted branches
        in takeaway/omitted. Never invent an interaction to complete a scenario.
        """, sources: [], root: root)
        let tool = AIAssistantPreferences.backend(project: project)
        let model = AIAssistantPreferences.xrayModel(for: tool, project: project)
        // The request `DiagramAI.generate` sends, mirrored for the cache key.
        var mirror = CLICompletion.Request(project: project ?? root, prompt: prompt, systemPrompt: DiagramAI.system,
                                           jsonSchema: DiagramAI.schema, readableFolder: root)
        try mirror.validateSchema()
        mirror.model = model
        let signature = modules.nodes.first { $0.id == "m:" }?.signature ?? ""
        let answerFile = Self.answerFile(for: mirror, context: signature, in: answerCache(root))
        if let cached = await Self.cachedValue(DiagramSpec.self, at: answerFile),
           (try? await Task.detached(priority: .utility) { try CodeArchitecture.validateSequence(cached, root: root) }.value) != nil {
            return cached
        }
        let diagram = try await DiagramAI.generate(prompt: prompt, root: root, label: "code-sequence",
            project: project, model: model, onStage: { [weak self] stage in
            Task { @MainActor in
                guard let self, self.rootPath == root.standardizedFileURL.path else { return }
                self.progress?.current = "Tracing \(name): \(stage)"
            }
        }, record: { result in Task { @MainActor in result.record(in: db) } })
        try await Task.detached(priority: .utility) { try CodeArchitecture.validateSequence(diagram, root: root) }.value
        Self.cache(diagram, at: answerFile)
        return diagram
    }

    /// The accepted scenarios and the source files they may start from; nil without any.
    private static func autoScenarios(in snapshot: ArchitectureSnapshot?)
        -> (modules: ArchView, scenarios: [CodeArchitectureModel.Scenario], files: [String])? {
        guard let current = snapshot, let modules = current.view("modules"),
              let scenarios = current.codeModel?.scenarios, !scenarios.isEmpty else { return nil }
        let files = modules.nodes.filter { $0.kind == "file" && $0.language != "markdown" }.compactMap(\.path)
        return (modules, scenarios, files)
    }

    /// Trace the scenarios the code analysis chose (`codeModel.scenarios`) one after
    /// another through the same path as a manual trace, then replace the automatic
    /// sequences with the result; manual traces are kept (DEC-002). A cancelled run
    /// changes nothing. A run in which every scenario failed keeps the previous automatic
    /// sequences and, like a successful one, records the source signature it traced
    /// (`tracedSignature`) with the failures (`traceNotes`, repeated by the coverage
    /// report), so the traces are not retried at every open but after a source change
    /// or Refresh. Runs inside the caller's run (flag, progress and task are the caller's).
    private func performAutoScenarios(root: URL, db: SemanticDatabase?) async {
        guard let auto = Self.autoScenarios(in: snapshot) else { return }
        let (modules, scenarios, files) = auto
        let started = Date()
        var traced: [CodeSequence] = []
        var failures: [(title: String, reason: String)] = []
        for (index, scenario) in scenarios.enumerated() {
            if Task.isCancelled { break }
            beginStep(index + 1, "Tracing " + scenario.title, started: started, steps: scenarios.count)
            setProgressScope(scenario.question)
            let paths = files.filter { $0 == scenario.scope || $0.hasPrefix(scenario.scope + "/") }.sorted()
            guard !paths.isEmpty else {
                failures.append((scenario.title, "no source files under \(scenario.scope)"))
                continue
            }
            do {
                let diagram = try await traceSequence(name: scenario.scope, question: scenario.question, paths: paths,
                                                      modules: modules, root: root, db: db)
                // A file scope has a Code-view node of its own; a directory is traced at the root.
                let scope = paths == [scenario.scope] ? "code:f:" + scenario.scope : "code:"
                traced.append(CodeSequence(scope: scope, diagram: diagram, modules: modules, auto: true))
            } catch is CancellationError {
                break
            } catch {
                failures.append((scenario.title, error.localizedDescription))
            }
        }
        guard !Task.isCancelled, rootPath == root.standardizedFileURL.path, var next = snapshot, var model = next.codeModel else { return }
        if !traced.isEmpty {
            next.codeSequences = CodeArchitecture.replacingAutoSequences(in: next.codeSequences ?? [], with: traced)
        }
        model.tracedSignature = modules.nodes.first { $0.id == "m:" }?.signature
        model.traceNotes = failures.isEmpty ? nil : failures.map { "Could not trace the scenario \"\($0.title)\": \($0.reason)" }
        next.codeModel = model
        let skipped = next.codeCoverage?.skipped ?? []
        let sourceFileCount = automaticSourceFileCount(modules)
        next.codeCoverage = await Task.detached(priority: .userInitiated) {
            CodeArchitecture.coverage(modules: modules, model: model, skipped: skipped, capabilities: .current,
                                      sourceFileCount: sourceFileCount)
        }.value
        guard !Task.isCancelled, rootPath == root.standardizedFileURL.path else { return }
        commit(next, db: db)
    }

    // MARK: - Automatic code analysis (REQ-002 of automatic-code-architecture)

    /// Analyze the project's code in the background, without the X-Ray tab: a local scan,
    /// then — when the source changed since the saved model — the code analysis and the
    /// automatic scenario traces, one run at a time. Project scope only: folder X-Rays stay
    /// manual. A start while a scan or analysis runs (the X-Ray tab restored first) is
    /// taken up when that run ends; `reset` (project close or switch) cancels the run, and
    /// a cancelled run commits nothing. With the `xray.autoAnalyze` switch off nothing runs
    /// and the state is `.off` (DEC-001); the size cap (DEC-003) and a missing or signed-out
    /// agent (DEC-004) end the run after the local scan, in `automaticState`. Either way the
    /// project is watched for changes from here on (`noteProjectChanged`), so a later switch
    /// or Refresh works without reopening. `force` is the Code view's Refresh (DEC-002): it
    /// runs now, with the switch off, above the size cap and inside the 15 min interval, and
    /// reads the model again even when the source did not change (cached answers make that free).
    func startAutomaticCodeAnalysis(root: URL, db: SemanticDatabase?, force: Bool = false) {
        guard projectRoot == nil else { return }
        automaticContext = (root, db)
        watchProjectChanges(root)
        guard AIAssistantPreferences.autoAnalyze || force else {
            automaticState = .off
            return
        }
        guard !busy else {
            // `endRun` of the active run arms the scheduler, whose decision is then to run.
            scheduler.requestRun()
            return
        }
        if rootPath == nil { rootPath = root.standardizedFileURL.path }
        guard rootPath == root.standardizedFileURL.path else { return }
        scheduler.lastChange = nil
        let token = beginRun()
        tasks.store(Task {
            defer { endRun(token) }
            await runAutomaticPipeline(root: root, db: db, force: force, token: token)
        }, for: "analysis")
    }

    /// Changes below the project root reach `noteProjectChanged` through an FSEvents
    /// stream (the file tree only reports its top level); one watcher per root.
    private func watchProjectChanges(_ root: URL) {
        if let watcher = changeWatcher {
            if watcher.root.standardizedFileURL == root.standardizedFileURL { return }
            watcher.stop()
        }
        let watcher = ProjectChangeWatcher(root: root) { [weak self] in self?.noteProjectChanged() }
        watcher.start()
        changeWatcher = watcher
    }

    /// The Code view's Refresh: the automatic pipeline, forced, for the project; a folder
    /// X-Ray (outside the pipeline) re-runs its manual code analysis.
    func refreshCode(root: URL, db: SemanticDatabase?) {
        guard !busy else { return }
        if projectRoot == nil {
            startAutomaticCodeAnalysis(root: root, db: db, force: true)
        } else {
            analyzeCode(root: root, db: db)
        }
    }

    /// The stages, chained explicitly inside one task so that cancellation reaches each.
    /// `token` is this run's: after `reset` every state write is skipped, so a cancelled
    /// run cannot overwrite the next workspace's state.
    private func runAutomaticPipeline(root: URL, db: SemanticDatabase?, force: Bool, token: Int) async {
        func show(_ state: AutomaticState) {
            guard token == runToken, !Task.isCancelled else { return }
            automaticState = state
        }
        show(.scanning)
        // The saved architecture, read on the database's actor so the open does not block the UI.
        if snapshot == nil {
            let stored = await db?.loadArchitecture()
            guard token == runToken, !Task.isCancelled else { return }
            if snapshot == nil, let stored = stored ?? loadPersisted() {
                snapshot = stored
                revision += 1
            }
        }
        guard let result = await performScan(root: root, db: db) else {
            show(.idle)
            return
        }
        guard token == runToken, !Task.isCancelled else { return }
        outlineContents(root: root)
        scheduler.sourceFileCount = result.sourceFileCount
        if !force, AutoAnalysisScheduler.exceedsSizeCap(result.sourceFileCount) {
            show(.tooLarge(files: result.sourceFileCount))
            return
        }
        guard let code = Self.codeFiles(in: snapshot) else {
            show(.skipped(reason: "No source files to analyze"))
            return
        }
        let signature = code.modules.nodes.first { $0.id == "m:" }?.signature
        let model = snapshot?.codeModel
        let modelIsCurrent = model != nil && signature != nil && model?.signature == signature
        // Traces are current when the model chose none, when automatic sequences exist, or
        // when the last automatic run traced this very source (even if every trace failed).
        let tracesMissing = !(model?.scenarios ?? []).isEmpty
            && snapshot?.codeSequences?.contains(where: \.auto) != true
            && model?.tracedSignature != signature
        if modelIsCurrent, !tracesMissing, !force {
            show(.done(model?.analyzedAt ?? Date()))
            return
        }

        // DEC-004: no agent or signed out — local layers only, one quiet status line.
        show(.analyzing(step: "Checking the assistant"))
        let tool = AIAssistantPreferences.backend(project: project)
        let probe = await CLIToolLocator.probe(tool)
        guard token == runToken, !Task.isCancelled else { return }
        if let problem = probe.error {
            show(.unavailable(reason: "\(tool.displayName) is not available: \(problem)"))
            return
        }
        if probe.loggedIn == false {
            show(.unavailable(reason: "\(tool.displayName) is signed out"))
            return
        }

        scheduler.lastAIRun = Date()
        if !modelIsCurrent || force {
            show(.analyzing(step: "Reading the code architecture"))
            switch await performCodeAnalysis(root: root, db: db) {
            case .analyzed: break
            case .cancelled, .failed: show(.idle); return
            }
        }
        guard token == runToken, !Task.isCancelled else { return }
        show(.analyzing(step: "Tracing scenarios"))
        await performAutoScenarios(root: root, db: db)
        show(.done(Date()))
    }

    /// The project's files changed (file-tree reload): refresh after the quiet period,
    /// locally or with the assistant as `AutoAnalysisScheduler` decides (DEC-003).
    /// Ignored for a project the automatic analysis never started for.
    func noteProjectChanged() {
        guard automaticContext != nil else { return }
        scheduler.lastChange = Date()
        armAutomaticRefresh()
    }

    /// Act on the scheduler's decision now, or sleep until it can decide.
    private func armAutomaticRefresh() {
        tasks.cancel(key: "refresh")
        guard let context = automaticContext else { return }
        scheduler.enabled = AIAssistantPreferences.autoAnalyze
        scheduler.runActive = busy
        switch scheduler.decision(at: Date()) {
        case .nothing, .waitForRun:
            // The switch, the size cap or no change: nothing; a run's end arms again.
            return
        case .wait(let until):
            sleepUntil(until)
        case .rescan(let aiAllowedAt):
            // Local only; the change stays recorded so the AI run follows when allowed.
            scheduler.lastRescan = Date()
            scan(root: context.root, db: context.db)
            sleepUntil(aiAllowedAt)
        case .analyze:
            startAutomaticCodeAnalysis(root: context.root, db: context.db)
        }
    }

    private func sleepUntil(_ date: Date) {
        let seconds = max(0, date.timeIntervalSinceNow)
        tasks.store(Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.armAutomaticRefresh()
        }, for: "refresh")
    }

    // MARK: - Contents

    /// The snapshot with each file's contents under its Logical-view box.
    private func withContents(_ snapshot: ArchitectureSnapshot) -> ArchitectureSnapshot {
        guard !outlines.isEmpty, let index = snapshot.views.firstIndex(where: { $0.id == "logical" })
            ?? snapshot.views.firstIndex(where: { $0.id == "modules" }) else { return snapshot }
        var next = snapshot
        var added: [ArchNode] = []
        // What the assistant read first, then declarations; within a budget so a large
        // project stays quick to draw.
        let files = snapshot.views[index].nodes.filter { $0.kind == "file" && $0.path.flatMap { outlines[$0] } != nil }
            .sorted { a, b in
                let aiA = outlines[a.path!]?.source == "ai", aiB = outlines[b.path!]?.source == "ai"
                return aiA != aiB ? aiA : a.path! < b.path!
            }
        for node in files {
            let path = node.path!
            let nodes = XRayContent.nodes(for: outlines[path]!, path: path, fileId: node.id)
            guard added.count + nodes.count <= XRayContent.maxDrawnNodes else { break }
            added += nodes
        }
        next.views[index].nodes += added
        return next
    }

    /// Files of the Logical view with their language and size.
    private var contentFiles: [(path: String, language: String?)] {
        (snapshot?.view("logical")?.nodes ?? snapshot?.view("modules")?.nodes ?? []).compactMap { node in
            guard node.kind == "file", let path = node.path else { return nil }
            return (path, node.language)
        }
    }

    /// Load stored outlines, then build local outlines for new or changed files.
    func outlineContents(root: URL) {
        tasks.store(Task { await buildOutlines(root: root) }, for: "outline")
    }

    /// Use a fast local pass for every file without a reusable outline. Deeper AI
    /// outlines are requested from an individual file's details panel.
    private func buildOutlines(root: URL) async {
        let files = contentFiles
        guard !files.isEmpty else { return }
        let language = ActionOutputLanguage.current
        let stored = await Task.detached(priority: .utility) { XRayContent.loadFresh(root: root, paths: files.map(\.path)) }.value
        guard !Task.isCancelled else { return }
        outlines = stored.filter { $0.value.source != "ai" || $0.value.language == language }
        revision += 1

        let missing = files.filter { outlines[$0.path] == nil }
        if progress?.step == 5 {
            progress?.current = "Building local file outlines"
            progress?.total = min(missing.count, 5000)
            progress?.unit = "files"
        }
        let found = await Task.detached(priority: .utility) { () -> [String: XRayContent.Outline] in
            var result: [String: XRayContent.Outline] = [:]
            for file in missing.prefix(5000) {
                guard !Task.isCancelled else { break }
                let url = root.appendingPathComponent(file.path)
                guard let signature = XRayContent.signature(of: url),
                      let text = try? String(contentsOf: url, encoding: .utf8),
                      let outline = XRayContent.localOutline(text: text, language: file.language, signature: signature) else { continue }
                XRayContent.save(outline, root: root, path: file.path)
                result[file.path] = outline
            }
            return result
        }.value
        guard !Task.isCancelled else { return }
        outlines.merge(found) { old, new in old.source == "ai" ? old : new }
        if progress?.step == 5 { progress?.done = min(missing.count, 5000) }
        revision += 1
    }

    /// Deepen one file's local outline with the configured X-Ray assistant.
    func outlineFile(path: String, root: URL, db: SemanticDatabase?) {
        guard !outlining.contains(path) else { return }
        let language = contentFiles.first { $0.path == path }?.language
        if error?.hasPrefix("Could not outline ") == true { error = nil }
        outlining.insert(path)
        revision += 1
        tasks.store(Task { await outlineWithAssistant(path, language: language, root: root, db: db) }, for: "outline:" + path)
    }

    private func outlineWithAssistant(_ path: String, language: String?, root: URL, db: SemanticDatabase?) async {
        // A task cancelled by `reset` finds `outlining` cleared and leaves it alone: it may hold another workspace's file by now.
        defer { if !Task.isCancelled { outlining.remove(path); revision += 1 } }
        let url = root.appendingPathComponent(path)
        guard let signature = XRayContent.signature(of: url),
              let text = await Task.detached(priority: .utility, operation: { try? String(contentsOf: url, encoding: .utf8) }).value
        else {
            if !Task.isCancelled { self.error = "Could not read \((path as NSString).lastPathComponent)." }
            return
        }
        guard !Task.isCancelled else { return }
        let outputLanguage = ActionOutputLanguage.current
        let languageLine = XRayContent.languageLine(summaries: outputLanguage == ActionOutputLanguage.documentLanguage
                                                    ? "the language of the file" : outputLanguage)
        var request = CLICompletion.Request(
            project: project,
            prompt: XRayContent.numbered(text, name: path),
            systemPrompt: XRayContent.isDocument(language)
                ? XRayContent.documentSystemPrompt(languageLine: languageLine)
                : language == "html"
                    ? XRayContent.htmlSystemPrompt(languageLine: languageLine)
                    : XRayContent.codeSystemPrompt(languageLine: languageLine),
            jsonSchema: XRayContent.documentSchema)
        request.timeout = 60
        do {
            let object = try await xrayCall(request, root: root, db: db, call: 99, trackProgress: false)
            let outline = XRayContent.assistantOutline(from: object, text: text, signature: signature, language: outputLanguage)
            guard !Task.isCancelled, !outline.collections.isEmpty else { return }
            outlines[path] = outline
            XRayContent.save(outline, root: root, path: path)
        } catch is CancellationError {
            return
        } catch {
            self.error = XRayContent.outlineFailureMessage(path: path, error: error)
        }
    }

    // MARK: - Why a link exists (click on an arrow)

    /// The AI's explanation of one link, streamed.
    struct EdgeNote: Codable {
        var text: String
        var pending: Bool
        /// Code lines behind the link (file → file imports or calls), shown as evidence.
        var evidence: [String]
    }
    private(set) var edgeNotes: [String: EdgeNote] = [:]

    /// Files a node of a view stands for: itself, the files below it, a component's files,
    /// the modules a deployment node runs.
    private func memberFiles(of node: ArchNode, in view: ArchView) -> [String] {
        let children = Dictionary(grouping: view.nodes.filter { $0.parent != nil }, by: { $0.parent! })
        var out: [String] = []
        func walk(_ id: String) {
            for child in children[id] ?? [] {
                if child.kind == "file", let path = child.path { out.append(path) }
                walk(child.id)
            }
        }
        if node.kind == "file", let path = node.path { return [path] }
        walk(node.id)
        if out.isEmpty, let path = node.path, !path.isEmpty {
            // A folder or a deployment node's module: the modules view's files under that path.
            out = (snapshot?.view("modules")?.nodes ?? []).filter { $0.kind == "file" && ($0.path ?? "").hasPrefix(path + "/") }.compactMap(\.path)
        }
        return out
    }

    /// Explain an arrow: why `source` depends on / calls `target`. The code lines behind the link
    /// are found first (imports and references of the target's files in the source's files);
    /// the AI reads them and the project and explains the link. Kept for the session.
    func explainEdge(view viewId: String, source: String, target: String, kind: String, label: String?,
                     root: URL, db: SemanticDatabase?, fresh: Bool = false) {
        let key = "\(viewId)|\(source)|\(target)"
        if !fresh, let note = edgeNotes[key], note.pending || !note.text.isEmpty { return }
        guard let snapshot, let view = snapshot.view(viewId) ?? (viewId == "pr" ? snapshot.view("logical") : nil),
              let a = view.nodes.first(where: { $0.id == source }), let b = view.nodes.first(where: { $0.id == target }) else { return }
        edgeNotes[key] = EdgeNote(text: "", pending: true, evidence: [])
        revision += 1
        let aFiles = memberFiles(of: a, in: view), bFiles = memberFiles(of: b, in: view)
        let describe = { (node: ArchNode) -> String in
            var line = "\(node.name) (\(node.kind))"
            if let path = node.path, !path.isEmpty { line += " at \(path)" }
            if let summary = node.summary { line += " — \(summary)" }
            return line
        }
        tasks.store(Task {
            let evidence = await Task.detached { Self.linkEvidence(from: aFiles, to: bFiles, root: root) }.value
            guard !Task.isCancelled else { return }
            edgeNotes[key]?.evidence = evidence
            revision += 1
            var request = CLICompletion.Request(
                project: project,
                prompt: """
                Link in the X-Ray (\(viewId) view): \(describe(a))  →  \(describe(b))
                Kind: \(kind)\(label.map { " (\($0))" } ?? "")
                Files on the source side: \(aFiles.prefix(25).joined(separator: ", "))\(aFiles.count > 25 ? " …" : "")
                Files on the target side: \(bFiles.prefix(25).joined(separator: ", "))\(bFiles.count > 25 ? " …" : "")

                Code lines where the source side refers to the target side:
                \(evidence.isEmpty ? "(none found by name — search the project)" : evidence.joined(separator: "\n"))
                """,
                systemPrompt: """
                You explain one arrow of an architecture map to an engineer. Say why the source depends on or \
                calls the target: what it uses from it, for which feature or flow, and through which code \
                (`path:line`, function names). Then say whether the link is expected for this architecture or \
                a smell (wrong direction, layer violation, hidden coupling), and what would break if the target \
                changed. Read the files named (read-only) to be concrete. Short Markdown: 3–8 sentences or \
                bullets, no headings.
                """ + "\n\n" + ActionOutputLanguage.explanationLine(),
                readableFolder: root)
            request.model = request.xrayModel
            request.effort = "low"
            request.timeout = 300
            let streamed = StreamedText()
            do {
                let (answer, result) = try await AIOperation<CLICompletion.Request, String>.text(name: "xray-link").execute(request, onDelta: { text in
                    Task { @MainActor in
                        streamed.value += text
                        self.edgeNotes[key]?.text = streamed.value
                        self.tasks.coalesce(key: "edge-refresh:" + key) { self.revision += 1 }
                    }
                })
                result.record(in: db)
                guard !Task.isCancelled else { return }
                edgeNotes[key]?.text = answer.isEmpty ? streamed.value : answer
            } catch is CancellationError {
                // `reset` or a fresh question for this link ended it: the note is not this task's any more.
                return
            } catch {
                edgeNotes[key]?.text = "Failed: \(error.localizedDescription)"
            }
            edgeNotes[key]?.pending = false
            revision += 1
        }, for: "edge:" + key)
    }

    /// Lines in the source files that name one of the target files (by module name), at most 20.
    nonisolated private static func linkEvidence(from sources: [String], to targets: [String], root: URL) -> [String] {
        let names = Set(targets.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }.filter { $0.count > 2 })
        guard !names.isEmpty else { return [] }
        var out: [String] = []
        for path in sources.prefix(200) {
            guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count < 240, names.contains(where: { trimmed.contains($0) }) else { continue }
                out.append("\(path):\(index + 1): \(trimmed)")
                if out.count >= 20 { return out }
            }
        }
        return out
    }
    // MARK: - Descriptions on demand

    /// Describe one folder, file or component when the user selects it.
    func describe(viewId: String, nodeId: String, root: URL, db: SemanticDatabase?) {
        guard let current = snapshot, let view = current.view(viewId),
              let node = view.nodes.first(where: { $0.id == nodeId }),
              node.summary == nil || node.summarySignature != node.signature,
              ["dir", "package", "file"].contains(node.kind), let path = node.path,
              !describing.contains(nodeId) else { return }
        describing.insert(nodeId)
        revision += 1
        tasks.store(Task {
            // A task cancelled by `reset` finds `describing` cleared and leaves it alone.
            defer { if !Task.isCancelled { describing.remove(nodeId); revision += 1 } }
            let children = view.nodes.filter { $0.parent == nodeId }.prefix(30).map(\.name).joined(separator: ", ")
            var request = CLICompletion.Request(
                project: project,
                prompt: node.kind == "file"
                    ? "Describe the file \(path)."
                    : "Describe the folder \(path). It contains: \(children).",
                systemPrompt: """
                You explain code to an engineer new to this project. In 2-3 sentences say what this \
                \(node.kind == "file" ? "file" : "folder") is responsible for, what it provides to the rest of the \
                system and anything notable. Read it in the working directory; do not modify anything. Plain text only.
                """ + "\n\n" + Self.graphLanguageLine,
                readableFolder: root)
            request.timeout = 300
            do {
                let (answer, result) = try await AIOperation<CLICompletion.Request, String>.text(name: "xray-describe").execute(request)
                result.record(in: db)
                let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled, var next = snapshot, !text.isEmpty else { return }
                // Store on the Modules node (the source of truth) and re-derive the Logical view.
                let path = node.path
                if let m = next.views.firstIndex(where: { $0.id == "modules" }),
                   let i = next.views[m].nodes.firstIndex(where: { $0.path == path && $0.kind == node.kind }) {
                    next.views[m].nodes[i].summary = text
                    next.views[m].nodes[i].summarySignature = next.views[m].nodes[i].signature
                }
                next = LogicalView.apply(next)
                commit(next, db: db)
            } catch is CancellationError {
            } catch {
                self.error = "Could not describe \(node.name): \(error.localizedDescription)"
            }
        }, for: "describe:" + nodeId)
    }

    // MARK: - Web view payload

    /// `AutomaticState` as the page reads it: a `kind` plus the case's detail.
    struct AutomaticStatePayload: Encodable {
        /// idle | scanning | analyzing | done | unavailable | off | tooLarge | skipped
        let kind: String
        let step: String?
        let reason: String?
        let date: Date?
        let files: Int?

        init(_ state: AutomaticState) {
            switch state {
            case .idle: self.init(kind: "idle")
            case .scanning: self.init(kind: "scanning")
            case .analyzing(let step): self.init(kind: "analyzing", step: step)
            case .done(let date): self.init(kind: "done", date: date)
            case .unavailable(let reason): self.init(kind: "unavailable", reason: reason)
            case .off: self.init(kind: "off")
            case .tooLarge(let files): self.init(kind: "tooLarge", files: files)
            case .skipped(let reason): self.init(kind: "skipped", reason: reason)
            }
        }

        private init(kind: String, step: String? = nil, reason: String? = nil, date: Date? = nil, files: Int? = nil) {
            self.kind = kind; self.step = step; self.reason = reason; self.date = date; self.files = files
        }
    }

    /// A scenario of the Code view's list: automatic or manual, and stale when a cited
    /// file changed since the trace.
    struct CodeSequenceInfo: Encodable {
        let title: String
        let scope: String
        let auto: Bool
        let stale: Bool
        let createdAt: Date
    }

    /// Everything the Architecture tab renders, as a JSON object literal.
    func payloadJSON(mode: String? = nil) -> String {
        struct Payload: Encodable {
            let mode: String?
            let snapshot: ArchitectureSnapshot?
            let status: String?
            let error: String?
            let prSources: [PRSource]
            let pr: PROverlay?
            /// The commits of the day chosen in the PR X-Ray's date picker.
            let history: HistoryPicker?
            let busy: Bool
            let describing: [String]
            let filters: [ImportanceRater.Filter]
            let root: String?
            let outlining: [String]
            /// "filterId|token": switch the overlay to this filter once per token.
            let activateFilter: String?
            /// The AI's summary of each ⚡ search, by filter id.
            let searchSummaries: [String: String]
            /// The ⚡ search's full answer and its steps, by filter id.
            let searchAnswers: [String: XRayFilterStore.SearchAnswer]
            let understandingAnswers: [String: XRayFilterStore.UnderstandingState]
            /// The AI's explanations of links (arrows), by "view|source|target".
            let edgeNotes: [String: EdgeNote]
            let codeSequenceDiagrams: [String]
            /// The automatic code analysis, for the Code view's status line.
            let automaticState: AutomaticStatePayload
            /// The automatic pipeline applies to this X-Ray (the project's, not a folder's):
            /// Refresh runs it, with the automatic scenarios.
            let automaticAnalysis: Bool
            /// One entry per `snapshot.codeSequences`, in the same order: what the scenario
            /// list shows (the snapshot's own sequences carry the diagram and citations).
            let codeSequenceInfo: [CodeSequenceInfo]
        }
        let modules = snapshot?.view("modules")
        let payload = Payload(mode: mode, snapshot: snapshot.map { withCodeArchitecture(withContents(filters.withUnderstandingEvidence($0))) }, status: status, error: error,
                              prSources: review.prSources, pr: review.prOverlay.map(review.withChangeNotes), history: review.historyPicker, busy: busy, describing: Array(describing),
                              filters: Array(filters.allFilters.dropFirst()),
                              root: rootPath, outlining: Array(outlining), activateFilter: filters.activateFilter,
                              searchSummaries: filters.searchSummaries, searchAnswers: filters.searchAnswers,
                              understandingAnswers: filters.understandingAnswers, edgeNotes: edgeNotes,
                              codeSequenceDiagrams: (snapshot?.codeSequences ?? []).map { DiagramAI.sequenceMermaid($0.diagram) },
                              automaticState: AutomaticStatePayload(automaticState),
                              automaticAnalysis: projectRoot == nil,
                              codeSequenceInfo: (snapshot?.codeSequences ?? []).map { sequence in
                                  CodeSequenceInfo(title: sequence.diagram.title, scope: sequence.scope, auto: sequence.auto,
                                                   stale: modules.map { sequence.isStale(modules: $0) } ?? false, createdAt: sequence.createdAt)
                              })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: - Book

    /// A Book section with the lines it spans.
    typealias BookSection = (id: String, path: String, line: Int, end: Int)

    nonisolated static func bookSections(in snapshot: ArchitectureSnapshot?) -> [BookSection] {
        (snapshot?.view("docs")?.nodes ?? []).compactMap { node in
            guard node.kind == "section", let path = node.path, let line = node.line else { return nil }
            return (node.id, path, line, node.endLine ?? Int.max)
        }
    }

    /// Annotated Book sections whose title or summary mention the question's words: where the
    /// ⚡ search should read first, as `- path:start-end "title" — summary` lines (at most 15).
    nonisolated static func bookHints(for criterion: String, in snapshot: ArchitectureSnapshot) -> [String] {
        let words = Set(criterion.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        guard !words.isEmpty, let book = snapshot.view("docs") else { return [] }
        return book.nodes.compactMap { node -> (Int, String)? in
            guard node.kind == "section", let path = node.path, let line = node.line,
                  let summary = node.summary, !summary.isEmpty else { return nil }
            let text = (node.name + " " + summary).lowercased()
            let score = words.filter { text.contains($0) }.count
            guard score > 0 else { return nil }
            return (score, "- \(path):\(line)-\(node.endLine ?? line) \"\(node.name)\" — \(summary.prefix(140))")
        }.sorted { $0.0 > $1.0 }.prefix(15).map(\.1)
    }

    /// Ratings keyed by Book node ids survive only while the node exists (a renamed heading, or
    /// a section id of the form the Docs view used before the Book, lapses).
    nonisolated static func keepBookRatings(_ ratings: [String: ImportanceRater.Rating], docs: ArchView)
        -> [String: ImportanceRater.Rating] {
        let ids = Set(docs.nodes.map(\.id))
        return ratings.filter { key, _ in !key.hasPrefix("d:") || ids.contains(key) }
    }

    /// The AI's work on the previous Book carried into a rescanned one, so a reopened or rescanned
    /// book keeps what was written: part and book summaries by id; for an unchanged chapter (same
    /// content signature) its summary, section summaries, items and related links. A changed
    /// chapter keeps the fresh scan's provisional texts (its first paragraphs) and, with a different
    /// `summarySignature`, is annotated again by the next Analyze.
    nonisolated static func carryBookAnnotations(from previous: ArchView?, into docs: ArchView) -> ArchView {
        guard let previous else { return docs }
        var next = docs
        let before = Dictionary(previous.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = Set(next.nodes.map(\.id))
        var unchanged: Set<String> = []     // chapter paths
        for i in next.nodes.indices where next.nodes[i].kind == "doc" {
            guard let old = before[next.nodes[i].id], old.signature == next.nodes[i].signature else { continue }
            next.nodes[i].summary = old.summary ?? next.nodes[i].summary
            next.nodes[i].summarySignature = old.summarySignature
            if let path = next.nodes[i].path { unchanged.insert(path) }
        }
        for i in next.nodes.indices {
            guard let old = before[next.nodes[i].id], let summary = old.summary, !summary.isEmpty else { continue }
            switch next.nodes[i].kind {
            case "root", "dir":
                next.nodes[i].summary = summary
            case "section":
                if let path = next.nodes[i].path, unchanged.contains(path) { next.nodes[i].summary = summary }
            default:
                continue
            }
        }
        // Items of unchanged chapters, when the section they hang under still exists.
        var carried: [ArchNode] = []
        for node in previous.nodes where ["collection", "group", "entity"].contains(node.kind) {
            guard let path = node.path, unchanged.contains(path) else { continue }
            carried.append(node)
        }
        let carriedIds = Set(carried.map(\.id))
        let known = ids.union(carriedIds)
        next.nodes += carried.filter { $0.parent.map { known.contains($0) } ?? false }
        let present = Set(next.nodes.map(\.id))
        let chapterOf = Dictionary(next.nodes.compactMap { node in node.path.map { (node.id, $0) } }, uniquingKeysWith: { a, _ in a })
        for edge in previous.edges where edge.kind == "related" {
            guard present.contains(edge.source), present.contains(edge.target),
                  let path = chapterOf[edge.source], unchanged.contains(path) else { continue }
            next.edges.append(edge)
        }
        return next
    }

    /// Chapters annotated in one Analyze; the rest wait for "Describe remaining chapters".
    private static let maxBookCalls = 150
    private static let bookConcurrency = 4

    private func annotateBookJob(_ job: BookAnnotator.Job, book: BookAnnotator.Book, index: Int, root: URL,
                                 db: SemanticDatabase?) async throws -> (Int, AIRawJSONObject?, [String]) {
        let lines = await Task.detached(priority: .userInitiated) { () -> [String] in
            ((try? String(contentsOf: root.appendingPathComponent(job.chapter.path), encoding: .utf8)) ?? "")
                .editorLines.map(String.init)
        }.value
        guard !lines.isEmpty else { return (index, nil, []) }
        let built = BookAnnotator.request(job: job, book: book, lines: lines)
        var request = CLICompletion.Request(project: project, prompt: built.prompt, systemPrompt: built.system, jsonSchema: built.schema)
        request.timeout = job.chapter.isLarge ? 240 : 120
        request.label = "xray-book:" + job.chapter.path
        do {
            let answer = try await xrayCall(request, root: root, db: db, call: 100 + index,
                                            accept: { BookAnnotator.isUsable($0, job: job) })
            return (index, try BookAnnotator.isUsable(answer, job: job) ? AIRawJSONObject(answer) : nil, lines)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.error = "Could not annotate \((job.chapter.path as NSString).lastPathComponent): \(error.localizedDescription)"
            return (index, nil, lines)
        }
    }

    /// Step 4 of Analyze (and "Describe this chapter"): the AI writes what every chapter and
    /// section says, finds related sections and, for large chapters, lists the items they are
    /// made of. One call per chapter (windows for very long ones), answers applied as they land.
    /// `only` limits the work to one chapter path; nil annotates every chapter whose text or
    /// language changed since it was last annotated.
    private func annotateBook(root: URL, db: SemanticDatabase?, only: String?) async throws {
        guard let current = snapshot, let view = current.view("docs") else { return }
        let language = ActionOutputLanguage.current
        let book = BookAnnotator.Book(view: view, language: language)
        var pending = book.chapters.filter { chapter in
            only.map { chapter.path == $0 } ?? !chapter.isCurrent
        }
        guard !pending.isEmpty else { return }
        // Front matter first, then the most linked-to, then the largest.
        var inDegree: [String: Int] = [:]
        for edge in view.edges where edge.kind == "links" { inDegree[String(edge.target.prefix { $0 != "#" }), default: 0] += edge.weight }
        pending.sort { a, b in
            if a.isFrontMatter != b.isFrontMatter { return a.isFrontMatter }
            let ia = inDegree[a.id] ?? 0, ib = inDegree[b.id] ?? 0
            if ia != ib { return ia > ib }
            return a.lines > b.lines
        }
        var jobs: [BookAnnotator.Job] = []
        for chapter in pending {
            for window in BookAnnotator.windows(for: chapter) {
                guard jobs.count < Self.maxBookCalls else { break }
                jobs.append(BookAnnotator.Job(chapter: chapter, window: window))
            }
        }
        let chapterIds = Set(jobs.map(\.chapter.id))
        progress?.total = chapterIds.count
        progress?.done = 0
        progress?.unit = "chapters"
        progress?.scope = only == nil ? "\(book.chapters.count) chapters" : nil
        describing.formUnion(chapterIds)
        revision += 1
        defer { describing.subtract(chapterIds) }

        var remaining = Dictionary(grouping: jobs, by: { $0.chapter.id }).mapValues(\.count)
        var landed = 0
        var work = view
        var ratings = current.ratings[ImportanceRater.importance.id] ?? [:]
        func publish(save: Bool) {
            guard var next = snapshot, let index = next.views.firstIndex(where: { $0.id == "docs" }) else { return }
            next.views[index] = work
            next.ratings[ImportanceRater.importance.id] = ratings
            if save { commit(next, db: db) } else { snapshot = next; revision += 1 }
        }

        try await withThrowingTaskGroup(of: (Int, AIRawJSONObject?, [String]).self) { group in
            var nextJob = 0
            func start(_ i: Int) {
                let job = jobs[i]
                group.addTask {
                    try await self.annotateBookJob(job, book: book, index: i, root: root, db: db)
                }
            }
            while nextJob < min(Self.bookConcurrency, jobs.count) { start(nextJob); nextJob += 1 }
            for try await (i, answered, lines) in group {
                let answer = answered?.dictionary
                try Task.checkCancellation()
                if nextJob < jobs.count { start(nextJob); nextJob += 1 }
                let job = jobs[i]
                if let answer {
                    let result = BookAnnotator.apply(answer, job: job, to: work, lines: lines)
                    work = result.view
                    for (key, level) in result.importance where ratings[key] == nil || ratings[key]?.provisional == true {
                        ratings[key] = .init(level: level, reason: "", signature: nil, provisional: nil)
                    }
                } else if job.window.index == 0 {
                    self.error = self.error ?? "Could not annotate \((job.chapter.path as NSString).lastPathComponent): the assistant gave no usable answer."
                }
                remaining[job.chapter.id, default: 1] -= 1
                if remaining[job.chapter.id] == 0 {
                    describing.remove(job.chapter.id)
                    landed += 1
                    progress?.done = landed
                    progress?.current = "Annotated \(landed) of \(chapterIds.count) chapters"
                }
                publish(save: landed % 5 == 0)
            }
        }

        // The parts and the book itself, from the chapter summaries.
        if only == nil || jobs.count > 0 {
            progress?.current = "Describing the parts"
            let parts = BookAnnotator.partsRequests(view: work, language: language)
            for (index, built) in parts.enumerated() {
                try Task.checkCancellation()
                var request = CLICompletion.Request(project: project, prompt: built.prompt, systemPrompt: built.system, jsonSchema: built.schema)
                request.timeout = 180
                request.label = "xray-book:parts"
                if let answer = try? await xrayCall(request, root: root, db: db, call: 90 + index) {
                    work = BookAnnotator.applyParts(answer, to: work)
                }
            }
        }
        publish(save: true)
    }

    /// "Describe this chapter" / "Describe remaining chapters" from the Book view's panel.
    func describeBook(path: String?, root: URL, db: SemanticDatabase?) {
        guard !busy, snapshot?.view("docs") != nil else { return }
        let token = beginRun()
        let started = Date()
        tasks.store(Task {
            defer { endRun(token) }
            beginStep(1, "Annotating the book", started: started, steps: 1)
            do {
                try await annotateBook(root: root, db: db, only: path)
            } catch is CancellationError {
            } catch {
                self.error = "Annotating the book failed: \(error.localizedDescription)"
            }
            setStatus(nil)
        }, for: "analysis")
    }
}

extension ArchitectureStore: ArchitectureHost {
    var isBusy: Bool { busy }

    func outline(for path: String) -> XRayContent.Outline? { outlines[path] }

    func bump() { revision += 1 }

    func show(_ next: ArchitectureSnapshot) { snapshot = next }

    func setError(_ message: String?) { error = message }

    func assistantCall(_ request: CLICompletion.Request, root: URL, db: SemanticDatabase?, call: Int,
                       fresh: Bool) async throws -> [String: Any] {
        try await xrayCall(request, root: root, db: db, call: call, fresh: fresh)
    }
}
