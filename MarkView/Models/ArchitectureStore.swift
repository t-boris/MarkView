import Foundation
import CryptoKit

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

    @Published private(set) var snapshot: ArchitectureSnapshot?
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var prSources: [PRSource] = []
    @Published private(set) var prOverlay: PROverlay?
    /// Bumped on every change the web view must re-render.
    @Published private(set) var revision = 0
    /// Live progress of the AI analysis. Sent to the web view on its own (throttled),
    /// so the large snapshot payload is not re-sent for every file the assistant reads.
    @Published private(set) var progress: AnalysisProgress?
    private var analysisTask: Task<Void, Never>?
    /// A folder's own X-Ray is kept here (JSON) instead of the project database, and its
    /// AI answers are cached in `cacheDirectory` — both inside the project's `.dde`, so
    /// nothing is written into the folder itself.
    var persistenceFile: URL?
    var cacheDirectory: URL?
    /// Root folder of this X-Ray (the project or one of its folders), for the web view.
    private(set) var rootPath: String?
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
    private var analyzeAfterScan = false
    /// Node ids with an on-demand description in flight.
    private var describing: Set<String> = []
    /// What each file is made of (`XRayContent`), by project-relative path; drawn under
    /// the file boxes of the Logical view.
    private var outlines: [String: XRayContent.Outline] = [:]
    /// Files the assistant is outlining right now.
    private var outlining: Set<String> = []
    private var outlineTask: Task<Void, Never>?
    /// Containers whose children are being rated for importance.
    private var rating: Set<String> = []

    struct PRSource: Codable, Hashable {
        /// working | branch | gh:<number>
        let id: String
        let title: String
    }

    struct PRFileChange: Codable {
        var path: String
        var additions: Int
        var deletions: Int
        /// New-file line ranges touched by the change: [[start, end]].
        var ranges: [[Int]]
        /// Filled by the AI review: ok | concern | bug.
        var verdict: String?
        var risk: String?
        var summary: String?
        var findings: [PRFinding]?
        /// What changed inside the file, drawn under it in the PR X-Ray (sent to the page;
        /// filled from the X-Ray contents, then from the AI's explanation).
        var changes: [PRChangeNote]?
        /// The AI's one-paragraph reading of this file's change.
        var changeSummary: String?
        var explaining: Bool?
    }

    /// One change inside a changed file.
    struct PRChangeNote: Codable {
        /// The file's logical part it falls in (X-Ray contents), when known.
        var part: String?
        var title: String
        /// New-file lines it covers (a removal: the line where the text was).
        var start: Int
        var end: Int
        /// added | changed | removed | moved (AI)
        var kind: String?
        /// What the change does and why (AI).
        var why: String?
    }

    struct PRFinding: Codable {
        var line: Int
        /// info | warning | bug
        var severity: String
        var message: String
    }

    /// A link between project files the change adds or removes.
    struct PRDependency: Codable {
        var source: String
        var target: String
        /// added | removed
        var change: String
    }

    /// The AI's architectural reading of a change.
    struct PRAnalysis: Codable {
        struct Impact: Codable { var component: String; var risk: String; var note: String }
        struct Check: Codable { var path: String; var line: Int; var note: String }
        var summary: String
        /// approve | attention | risky
        var verdict: String
        var impact: [Impact]
        var risks: [String]
        var checks: [Check]
    }

    struct PROverlay: Codable {
        var source: PRSource
        var files: [PRFileChange]
        var reviewed: Bool
        var reviewSummary: String?
        var dependencies: [PRDependency] = []
        var analysis: PRAnalysis?
        var analyzing: Bool?
        /// The diff of the file selected in the PR X-Ray.
        var fileDiff: PRFileDiff?
        /// Questions asked about this change and the AI's answers (newest last).
        var chat: [PRChat] = []
        /// The code changed after the review and analysis shown (reloaded automatically).
        var reviewOutdated: Bool?
    }

    struct PRFileDiff: Codable {
        var path: String
        var text: String
    }

    struct PRChat: Codable {
        var question: String
        /// The file the question is about, or nil for the whole change.
        var path: String?
        var answer: String
        var pending: Bool
    }

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
    private var prReloadedAt = Date.distantPast

    func reset() {
        rootPath = nil
        snapshot = nil
        outlineTask?.cancel()
        outlineTask = nil
        outlines = [:]
        outlining = []
        status = nil
        error = nil
        prSources = []
        prOverlay = nil
        revision += 1
    }

    // MARK: - Load and scan

    /// Show the stored architecture right away, then rescan in the background so
    /// the view catches up with code changed since. The scan is cheap (no AI);
    /// AI descriptions are kept and only changed modules are re-described later.
    func open(root: URL, db: SemanticDatabase?) {
        rootPath = root.standardizedFileURL.path
        if snapshot == nil, let stored = db?.loadArchitecture() ?? loadPersisted() {
            snapshot = stored
            revision += 1
        }
        analyzeAfterScan = true
        scan(root: root, db: db)
        refreshPRSources(root: root)
    }

    /// Deterministic scan (no AI). Keeps AI descriptions and the Deployment view
    /// from the previous snapshot for nodes that still exist.
    func scan(root: URL, db: SemanticDatabase?) {
        guard !busy else { return }
        busy = true
        error = nil
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
        Task {
            let result = await Task.detached(priority: .userInitiated) { scanner.run() }.value
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
            views.append(result.docs)
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
                                            ratings: (previous?.ratings ?? [:]).mapValues { Self.keepCurrentRatings($0, modules: modules) },
                                            deploymentHints: result.deploymentHints, scannedAt: Date(),
                                            enrichedAt: previous?.enrichedAt, gitHead: result.gitHead)
            pendingDeploymentSignature = result.deploymentSignature
            next = Self.applyLogical(next)
            commit(next, db: db)
            setStatus(nil)
            // Release before chaining: analyze() refuses to start while busy.
            busy = false
            // Opening the Architecture for the first time runs the AI analysis.
            if analyzeAfterScan && (next.enrichedAt == nil || Self.needsRegrouping(next) || next.language != Self.graphLanguage) {
                analyzeAfterScan = false
                analyze(root: root, db: db)
            } else {
                // Contents: stored outlines at once, then new or changed files.
                outlineContents(root: root, db: db)
            }
        }
    }

    /// The grouping no longer covers the project: new folders or file kinds (e.g. notes
    /// counted since a scanner update) left many files unassigned. Re-analysing is cheap —
    /// unchanged branches come from the answer cache.
    nonisolated static func needsRegrouping(_ snapshot: ArchitectureSnapshot) -> Bool {
        guard !snapshot.logicalDraft, let logical = snapshot.view("logical") else { return false }
        let files = logical.nodes.filter { $0.kind == "file" }
        let unassigned = files.filter { $0.parent == "l:c:_other" }.count
        return unassigned > 50 || (files.count > 0 && Double(unassigned) / Double(files.count) > 0.1)
    }

    private func commit(_ next: ArchitectureSnapshot, db: SemanticDatabase?) {
        snapshot = next
        do { try db?.saveArchitecture(next) } catch {
            self.error = "Could not save the architecture: \(error.localizedDescription)"
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
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    private func loadPersisted() -> ArchitectureSnapshot? {
        guard let file = persistenceFile, let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ArchitectureSnapshot.self, from: data)
    }

    /// Where AI answers for this X-Ray are cached.
    private func answerCache(_ root: URL) -> URL {
        cacheDirectory ?? root.appendingPathComponent(".dde/cache/xray", isDirectory: true)
    }

    private func setStatus(_ text: String?) {
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
        busy = true
        error = nil
        let started = Date()
        analysisTask = Task {
            defer { busy = false; progress = nil; analysisTask = nil; answerByCall = [:] }
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
                    next = Self.applyClusters(clusters, names: [:], grouping: nil, to: next)
                    commit(next, db: db)
                }

                beginStep(2, "Naming components", started: started)
                setProgressScope("\(clusters.count) components from \(plan.units.count) folders")
                async let deployment = mapDeployment(in: next, plan: plan, root: root, db: db)
                next = try await nameClusters(clusters, plan: plan, base: next, root: root, db: db)
                commit(next, db: db)

                beginStep(3, "Mapping deployment", started: started)
                if let view = try await deployment {
                    next.views.removeAll { $0.id == "deployment" }
                    next.views.insert(view, at: next.views.firstIndex { $0.id == "docs" } ?? next.views.count)
                    next.deploymentSignature = pendingDeploymentSignature ?? next.deploymentSignature
                }
                next.enrichedAt = Date()
                next.language = Self.graphLanguage
                commit(next, db: db)

                beginStep(4, "Reading contents", started: started)
                await buildOutlines(root: root, db: db)
            } catch is CancellationError {
                // Keep the structure found so far (shown live, not yet saved).
                if let found = snapshot, found.components.map(\.id) != next.components.map(\.id) { commit(found, db: db) }
            } catch {
                self.error = "Analysis failed: \(error.localizedDescription)"
            }
            setStatus(nil)
        }
    }

    /// Stop a running analysis; the assistant's process is terminated.
    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    private func beginStep(_ step: Int, _ title: String, started: Date) {
        setStatus(title + "…")
        let tool = AIAssistantPreferences.backend
        progress = AnalysisProgress(step: step, steps: 4, title: title, scope: nil,
                                    startedAt: started, stepStartedAt: Date(),
                                    assistant: AIAssistantPreferences.summary(tool: tool, model: AIAssistantPreferences.xrayModel(for: tool) ?? ""))
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
                case .answerDelta:
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

    /// The Deployment view, or nil when the build/deploy config files did not change
    /// since the last mapping. The config files are inlined; the assistant reads nothing.
    private func mapDeployment(in snapshot: ArchitectureSnapshot, plan: XRayDigest.Plan, root: URL,
                               db: SemanticDatabase?) async throws -> ArchView? {
        guard let modules = snapshot.view("modules") else { return nil }
        if snapshot.view("deployment") != nil, let signature = pendingDeploymentSignature ?? snapshot.deploymentSignature,
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
        let object = try await xrayCall(request, root: root, db: db, call: 100)
        let rawNodes = object["nodes"] as? [[String: Any]] ?? []
        let rawEdges = object["edges"] as? [[String: Any]] ?? []
        let moduleById = Dictionary(modules.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = Set(rawNodes.compactMap { $0["id"] as? String })

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

    static let tagVocabulary = ["entry", "ui", "api", "domain", "data", "integration", "infra",
                                "config", "build", "tests", "docs", "generated", "scripts", "examples"]

    private static let layers = ["presentation", "application", "domain", "data", "infrastructure",
                                 "integration", "platform", "tooling", "tests", "docs"]
    private static let roles = ["ui", "api", "domain", "data", "infra", "integration", "tooling", "tests",
                                "docs", "config", "shared", "app"]

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
    private func xrayCall(_ request: CLICompletion.Request, root: URL, db: SemanticDatabase?,
                          call: Int, fresh: Bool = false) async throws -> [String: Any] {
        var request = request
        request.model = AIAssistantPreferences.xrayModel(for: request.tool)
        request.effort = "low"
        let key = [request.tool.rawValue, request.model ?? "", request.systemPrompt ?? "", request.prompt,
                   (try? JSONSerialization.data(withJSONObject: request.jsonSchema ?? [:], options: .sortedKeys))
                       .map { String(decoding: $0, as: UTF8.self) } ?? ""].joined(separator: "\u{1}")
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        let cache = answerCache(root)
        let file = cache.appendingPathComponent(hash + ".json")
        if !fresh, let data = try? Data(contentsOf: file),
           let cached = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return cached
        }
        let result = try await CLICompletion.run(request, onActivity: activityHandler(root: root, call: call))
        result.record(in: db)
        let object = result.structured as? [String: Any] ?? [:]
        if !object.isEmpty, let data = try? JSONSerialization.data(withJSONObject: object) {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return object
    }

    // MARK: Naming the clusters

    /// Clusters per naming call: a short answer each, and the calls run side by side.
    private static let clustersPerCall = 35

    /// Language a cluster's name should be in: the majority language of its documents
    /// (measured locally, never guessed by the model); code counts as English.
    private static func nameLanguage(_ cluster: XRayCluster.Cluster, plan: XRayDigest.Plan) -> String {
        let units = cluster.units.compactMap { plan.unitByPath[$0] }
        return XRayDigest.language(cyrillic: units.reduce(0) { $0 + $1.cyrillic }, latin: units.reduce(0) { $0 + $1.latin })
    }

    /// The majority language of all the plan's documents: the language subsystem names use.
    private static func projectNameLanguage(_ plan: XRayDigest.Plan) -> String {
        XRayDigest.language(cyrillic: plan.units.reduce(0) { $0 + $1.cyrillic }, latin: plan.units.reduce(0) { $0 + $1.latin })
    }

    /// One prompt line per cluster: size, a few folders, packages, declared names.
    private static func clusterLine(_ cluster: XRayCluster.Cluster, plan: XRayDigest.Plan) -> String {
        let byPath = plan.unitByPath
        let units = cluster.units.compactMap { byPath[$0] }
        var line = "- \(cluster.id) (group \(cluster.group); name in \(nameLanguage(cluster, plan: plan))): \(units.count) folders, \(units.reduce(0) { $0 + $1.files }) files — "
            + cluster.units.prefix(4).map { $0.isEmpty ? "(root)" : $0 + "/" }.joined(separator: ", ")
        let packages = units.compactMap(\.package).prefix(2)
        if !packages.isEmpty { line += " | packages: " + packages.joined(separator: "; ") }
        let names = units.flatMap(\.declarations).prefix(8)
        if !names.isEmpty { line += " | defines: " + names.joined(separator: ", ") }
        if let readme = units.compactMap(\.readme).first { line += " | readme: " + readme }
        return line
    }

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

    /// Name every cluster (in parallel chunks), then group them into subsystems. The
    /// structure on screen is updated as each answer lands.
    private func nameClusters(_ clusters: [XRayCluster.Cluster], plan: XRayDigest.Plan, base: ArchitectureSnapshot,
                              root: URL, db: SemanticDatabase?) async throws -> ArchitectureSnapshot {
        let single = clusters.count <= Self.clustersPerCall
        let chunks = stride(from: 0, to: clusters.count, by: Self.clustersPerCall)
            .map { Array(clusters[$0..<min($0 + Self.clustersPerCall, clusters.count)]) }
        progress?.total = chunks.count + (single ? 0 : 1)
        progress?.unit = "calls"
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
        let schema: [String: Any] = ["type": "object", "properties": properties, "required": required]
        let subsystemLanguage = Self.projectNameLanguage(plan)
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
        try await withThrowingTaskGroup(of: [String: Any].self) { group in
            for (index, chunk) in chunks.enumerated() {
                let prompt = plan.overview + "\n\nClusters:\n" + chunk.map { Self.clusterLine($0, plan: plan) }.joined(separator: "\n")
                group.addTask { @MainActor in
                    var request = CLICompletion.Request(prompt: prompt, systemPrompt: system, jsonSchema: schema)
                    request.timeout = 240
                    return try await self.xrayCall(request, root: root, db: db, call: index)
                }
            }
            for try await answer in group {
                for item in answer["clusters"] as? [[String: Any]] ?? [] {
                    if let id = item["id"] as? String { names[id] = item }
                }
                if single { grouping = answer }
                progress?.done += 1
                progress?.current = "Named \(names.count) of \(clusters.count) components"
                latest = Self.applyClusters(clusters, names: names, grouping: grouping, to: base)
                snapshot = latest       // live; saved at the end
                revision += 1
            }
        }
        guard !single else { return latest }

        // Subsystems over all named clusters: one short call.
        progress?.current = "Grouping into subsystems"
        let lines = clusters.map { cluster -> String in
            let item = names[cluster.id]
            return "- \(cluster.id) (group \(cluster.group); name in \(Self.nameLanguage(cluster, plan: plan))): \(item?["name"] as? String ?? cluster.id) — \(item?["purpose"] as? String ?? "")"
        }
        var request = CLICompletion.Request(
            prompt: plan.overview + "\n\nComponents:\n" + lines.joined(separator: "\n"),
            systemPrompt: """
            You are a software architect. Group these components into 3-8 SUBSYSTEMS by responsibility (every \
            component id in exactly one), then name the whole system and say in 2-3 sentences what it does. \
            Components with the same "group" are closely related. Subsystem and system names in \(Self.projectNameLanguage(plan)). \
            Be concise.
            """ + "\n\n" + Self.graphLanguageLine,
            jsonSchema: ["type": "object",
                         "properties": ["system": Self.systemSchema, "subsystems": Self.groupingSchema],
                         "required": ["system", "subsystems"]])
        request.timeout = 180
        grouping = try await xrayCall(request, root: root, db: db, call: chunks.count)
        progress?.done += 1
        return Self.applyClusters(clusters, names: names, grouping: grouping, to: base)
    }

    /// Components and folder assignments from the clusters: named (or provisional from
    /// their folders), merged where the AI said so, under the AI's subsystems (or the
    /// clustering's own groups until those arrive).
    nonisolated static func applyClusters(_ clusters: [XRayCluster.Cluster], names: [String: [String: Any]],
                                          grouping: [String: Any]?, to base: ArchitectureSnapshot) -> ArchitectureSnapshot {
        var next = base
        let ids = Set(clusters.map(\.id))
        // Merges, followed to their end (a → b → c) and never into itself.
        func target(_ id: String) -> String {
            var current = id, seen = Set<String>()
            while seen.insert(current).inserted, let into = names[current]?["mergeInto"] as? String, ids.contains(into) { current = into }
            return current
        }
        func folderName(_ path: String) -> String { path.isEmpty ? "Project root" : (path as NSString).lastPathComponent }
        func commonPrefix(_ paths: [String]) -> String {
            guard var prefix = paths.first?.split(separator: "/").map(String.init) else { return "" }
            for path in paths.dropFirst() {
                let parts = path.split(separator: "/").map(String.init)
                prefix = Array(zip(prefix, parts).prefix { $0 == $1 }.map(\.0))
            }
            return prefix.joined(separator: "/")
        }

        var components: [LogicalComponent] = []
        var parentOf: [String: String] = [:]
        if let subsystems = grouping?["subsystems"] as? [[String: Any]], !subsystems.isEmpty {
            for (index, raw) in subsystems.enumerated() {
                let id = "s-" + ((raw["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(index))
                components.append(LogicalComponent(id: id, name: raw["name"] as? String ?? id, purpose: raw["purpose"] as? String ?? "",
                                                   parent: "", layer: raw["layer"] as? String ?? "application"))
                for member in raw["components"] as? [String] ?? [] where ids.contains(member) && parentOf[member] == nil {
                    parentOf[member] = id
                }
            }
            if let system = grouping?["system"] as? [String: Any] {
                next.systemName = system["name"] as? String
                next.systemPurpose = system["purpose"] as? String
            }
        } else {
            // Provisional subsystems: the clustering's coarse groups, named by their main top folder.
            for group in Set(clusters.map(\.group)).sorted() {
                let tops = clusters.filter { $0.group == group }.flatMap(\.units).map { String($0.split(separator: "/").first ?? "") }
                let main = Dictionary(grouping: tops, by: { $0 }).max { $0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key > $1.key) }?.key ?? ""
                components.append(LogicalComponent(id: "s-" + group, name: main.isEmpty ? "Project root" : main, purpose: "",
                                                   parent: "", layer: "application"))
            }
            for cluster in clusters { parentOf[cluster.id] = "s-" + cluster.group }
        }
        var assignments: [String: LogicalAssignment] = [:]
        for cluster in clusters {
            let owner = target(cluster.id)
            for unit in cluster.units { assignments[unit] = LogicalAssignment(component: "c-" + owner, tags: []) }
            guard owner == cluster.id else { continue }
            let item = names[cluster.id]
            let prefix = commonPrefix(cluster.units)
            components.append(LogicalComponent(
                id: "c-" + cluster.id,
                name: (item?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folderName(prefix.isEmpty ? cluster.units[0] : prefix),
                purpose: item?["purpose"] as? String ?? "",
                parent: parentOf[cluster.id] ?? components.first { $0.parent.isEmpty }?.id ?? "",
                layer: item?["layer"] as? String ?? "application"))
        }
        next.components = components
        next.assignments = assignments
        next.logicalDraft = names.isEmpty
        // Importance of components and subsystems comes with their names: the Importance
        // filter is ready with the structure, without calls of its own.
        let levels = ImportanceRater.importance.levels
        var importance = next.ratings[ImportanceRater.importance.id] ?? [:]
        for cluster in clusters {
            guard let level = names[cluster.id]?["importance"] as? String, levels.contains(level) else { continue }
            importance["c:c-" + cluster.id] = .init(level: level, reason: names[cluster.id]?["purpose"] as? String ?? "")
        }
        for (index, raw) in (grouping?["subsystems"] as? [[String: Any]] ?? []).enumerated() {
            guard let level = raw["importance"] as? String, levels.contains(level) else { continue }
            let id = "s-" + ((raw["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(index))
            importance["c:" + id] = .init(level: level, reason: raw["purpose"] as? String ?? "")
        }
        next.ratings[ImportanceRater.importance.id] = importance
        next.logicalSignature = next.view("modules")?.nodes.first { $0.id == "m:" }?.signature
        return applyLogical(next)
    }

    /// Rebuild the Logical view and the component/tags of Modules-view nodes from
    /// the AI assignments and the user's overrides. Deterministic; no AI.
    private static let tagFolders: [String: Set<String>] = [
        "tests": ["test", "tests", "__tests__", "spec", "specs", "testing", "e2e", "uitests", "unittests", "fixtures", "__mocks__", "mocks"],
        "docs": ["docs", "doc", "documentation"],
        "config": ["config", "configs", ".github", ".vscode", ".idea", "settings"],
        "build": ["build", "dist", "out", ".build", "target", "deploy", "docker", "ci"],
        "generated": ["generated", "__generated__", "gen", "vendor", "third_party", "thirdparty"],
        "scripts": ["scripts", "script", "tools", "tooling", "bin"],
        "examples": ["examples", "example", "samples", "sample", "demo", "demos"],
    ]

    /// Kind tags of a folder or file from its path alone — deterministic, so hiding works
    /// the same with or without an AI analysis. A test file next to code counts as a test.
    nonisolated static func pathTags(_ path: String, isFile: Bool, language: String?) -> [String] {
        let lower = path.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        let folders = Set(isFile ? Array(parts.dropLast()) : parts)
        let name = isFile ? (parts.last ?? "") : ""
        var tags: [String] = []
        for (tag, names) in tagFolders.sorted(by: { $0.key < $1.key }) where !folders.isDisjoint(with: names) { tags.append(tag) }
        if isFile {
            if ArchitectureScanner.isTestPath(path), !tags.contains("tests") { tags.append("tests") }
            if language == "markdown", !tags.contains("docs") { tags.append("docs") }
            if name.contains(".generated.") || name.hasSuffix(".g.dart") || name.hasSuffix(".pb.go") || name.hasSuffix(".min.js"),
               !tags.contains("generated") { tags.append("generated") }
            let isConfig = name.hasPrefix(".") || name.contains(".config.") || name.hasSuffix("config.json") || name.hasSuffix("rc")
                || ["package.json", "tsconfig.json", "project.yml", "podfile", "gemfile", "cargo.toml", "go.mod", "pyproject.toml"].contains(name)
            if isConfig, !tags.contains("config") { tags.append("config") }
            if ["dockerfile", "makefile", "procfile", "jenkinsfile"].contains(name) || name.hasSuffix(".gradle"),
               !tags.contains("build") { tags.append("build") }
        }
        return tags
    }

    /// Above this many files, a component in the Logical view lists its folders instead.
    nonisolated static let folderGroupingThreshold = 30

    nonisolated static func applyLogical(_ snapshot: ArchitectureSnapshot) -> ArchitectureSnapshot {
        var next = snapshot
        next.views.removeAll { $0.id == "logical" }
        guard !snapshot.components.isEmpty, let moduleIndex = next.views.firstIndex(where: { $0.id == "modules" }) else {
            return next
        }
        let componentIds = Set(snapshot.components.map(\.id))

        /// Nearest assignment for `path`, walking up its folders (user overrides first).
        func resolve(_ path: String) -> (component: String?, tags: [String]) {
            var candidate = path
            var component: String?
            var tags: [String]?
            while true {
                if component == nil, let chosen = snapshot.overrides[candidate], componentIds.contains(chosen) { component = chosen }
                if let assignment = snapshot.assignments[candidate] {
                    if component == nil { component = assignment.component }
                    if tags == nil, !assignment.tags.isEmpty { tags = assignment.tags }
                }
                if (component != nil && tags != nil) || candidate.isEmpty { break }
                candidate = (candidate as NSString).deletingLastPathComponent
            }
            return (component, tags ?? [])
        }

        var modules = next.views[moduleIndex]
        for i in modules.nodes.indices where ["dir", "package", "file"].contains(modules.nodes[i].kind) {
            let node = modules.nodes[i]
            let resolved = resolve(node.path ?? "")
            modules.nodes[i].component = resolved.component
            // Tags from the path and file kind (what "Hide tests" and "Code only" use), plus any from the AI.
            var tags = pathTags(node.path ?? "", isFile: node.kind == "file", language: node.language)
            for tag in resolved.tags where !tags.contains(tag) { tags.append(tag) }
            modules.nodes[i].tags = tags.isEmpty ? nil : tags
        }
        next.views[moduleIndex] = modules

        var nodes = [ArchNode(id: "l:", parent: nil, kind: "root", name: snapshot.systemName ?? "System",
                              summary: snapshot.systemPurpose)]
        for component in snapshot.components {
            let parent = componentIds.contains(component.parent) && component.parent != component.id ? "l:c:" + component.parent : "l:"
            nodes.append(ArchNode(id: "l:c:" + component.id, parent: parent, kind: "component", name: component.name,
                                  summary: component.purpose, role: component.layer))
        }
        var needsOther = false
        var filesByComponent: [String: [ArchNode]] = [:]
        for file in modules.nodes where file.kind == "file" {
            var copy = file
            copy.id = "l:f:" + (file.path ?? "")
            if let component = file.component { copy.parent = "l:c:" + component } else { copy.parent = "l:c:_other"; needsOther = true }
            filesByComponent[copy.parent ?? "", default: []].append(copy)
        }
        // A component with many files shows their folders first (double-click opens one),
        // instead of hundreds of file boxes at once.
        for (component, files) in filesByComponent.sorted(by: { $0.key < $1.key }) {
            let folders = Dictionary(grouping: files) { ((($0.path ?? "") as NSString).deletingLastPathComponent) }
            guard files.count > folderGroupingThreshold, folders.count > 1 else { nodes += files; continue }
            for (folder, members) in folders.sorted(by: { $0.key < $1.key }) {
                let id = "l:d:" + component.dropFirst(4) + "|" + folder
                let parts = folder.split(separator: "/")
                nodes.append(ArchNode(id: id, parent: component, kind: "dir",
                                      name: folder.isEmpty ? "(project root)" : parts.suffix(2).joined(separator: "/"), path: folder))
                nodes += members.map { var file = $0; file.parent = id; return file }
            }
        }
        if needsOther {
            nodes.append(ArchNode(id: "l:c:_other", parent: "l:", kind: "component", name: "Unassigned",
                                  summary: "Files the analysis did not place in a component."))
        }
        for node in modules.nodes where node.kind == "externalGroup" || node.kind == "external" { nodes.append(node) }

        // Sizes of components (files and lines below them).
        var totals: [String: (Int, Int)] = [:]
        let parentOf = Dictionary(nodes.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        for node in nodes where node.kind == "file" {
            var parent = node.parent
            while let p = parent {
                totals[p, default: (0, 0)].0 += 1
                totals[p, default: (0, 0)].1 += node.loc
                parent = parentOf[p] ?? nil
            }
        }
        for i in nodes.indices where nodes[i].kind == "component" || nodes[i].kind == "root" || nodes[i].kind == "dir" {
            nodes[i].files = totals[nodes[i].id]?.0 ?? 0
            nodes[i].loc = totals[nodes[i].id]?.1 ?? 0
        }

        let edges = modules.edges.map { edge -> ArchEdge in
            var e = edge
            if e.source.hasPrefix("m:") { e.source = "l:f:" + e.source.dropFirst(2) }
            if e.target.hasPrefix("m:") { e.target = "l:f:" + e.target.dropFirst(2) }
            return e
        }
        next.views.insert(ArchView(id: "logical", nodes: nodes, edges: edges), at: 0)
        return next
    }

    /// Move a folder or file to another component (user override), or back to the
    /// AI's choice when `component` is empty.
    func setComponent(path: String, component: String, db: SemanticDatabase?) {
        guard var next = snapshot else { return }
        if component.isEmpty { next.overrides[path] = nil } else { next.overrides[path] = component }
        next = Self.applyLogical(next)
        commit(next, db: db)
    }

    // MARK: - Contents

    /// The snapshot with each file's contents under its Logical-view box.
    private func withContents(_ snapshot: ArchitectureSnapshot) -> ArchitectureSnapshot {
        guard !outlines.isEmpty, let index = snapshot.views.firstIndex(where: { $0.id == "logical" }) else { return snapshot }
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
    private var contentFiles: [(path: String, language: String?, lines: Int)] {
        (snapshot?.view("logical")?.nodes ?? []).compactMap { node in
            guard node.kind == "file", let path = node.path else { return nil }
            return (path, node.language, node.loc)
        }
    }

    /// Load stored outlines, then outline new or changed files (background; the
    /// assistant only for up to `XRayContent.filesPerAnalysis` files).
    func outlineContents(root: URL, db: SemanticDatabase?) {
        outlineTask?.cancel()
        outlineTask = Task { await buildOutlines(root: root, db: db) }
    }

    /// Outline the files that have no current outline: short code locally, documents and
    /// long code with the assistant (longest first, a few calls side by side).
    private func buildOutlines(root: URL, db: SemanticDatabase?) async {
        let files = contentFiles
        guard !files.isEmpty else { return }
        let language = ActionOutputLanguage.current
        let stored = await Task.detached(priority: .utility) { XRayContent.loadFresh(root: root, paths: files.map(\.path)) }.value
        outlines = stored.filter { $0.value.source != "ai" || $0.value.language == language }
        revision += 1

        let missing = files.filter { outlines[$0.path] == nil }
        let local = missing.filter { !XRayContent.needsAssistant(language: $0.language, lines: $0.lines) }
        let assisted = missing.filter { XRayContent.needsAssistant(language: $0.language, lines: $0.lines) }
            .sorted { $0.lines > $1.lines }
            .prefix(XRayContent.filesPerAnalysis)

        // Declarations of short code: local, fast.
        let found = await Task.detached(priority: .utility) { () -> [String: XRayContent.Outline] in
            var result: [String: XRayContent.Outline] = [:]
            for file in local.prefix(5000) {
                let url = root.appendingPathComponent(file.path)
                guard let signature = XRayContent.signature(of: url),
                      let text = try? String(contentsOf: url, encoding: .utf8),
                      let outline = XRayContent.codeOutline(text: text, language: file.language, signature: signature) else { continue }
                XRayContent.save(outline, root: root, path: file.path)
                result[file.path] = outline
            }
            return result
        }.value
        outlines.merge(found) { _, new in new }
        revision += 1

        guard !assisted.isEmpty, !Task.isCancelled else { return }
        setProgressScope("\(assisted.count) files")
        var queue = Array(assisted)
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            var call = 100
            while !queue.isEmpty || running > 0 {
                while running < XRayContent.parallelCalls, !queue.isEmpty, !Task.isCancelled {
                    let file = queue.removeFirst()
                    running += 1
                    call += 1
                    let index = call
                    group.addTask { await self.outlineWithAssistant(file.path, language: file.language, root: root, db: db, call: index) }
                }
                guard running > 0 else { break }
                await group.next()
                running -= 1
            }
        }
    }

    /// Outline one file with the assistant (details panel, or during the analysis).
    func outlineFile(path: String, root: URL, db: SemanticDatabase?) {
        guard !outlining.contains(path) else { return }
        let language = contentFiles.first { $0.path == path }?.language
        Task { await outlineWithAssistant(path, language: language, root: root, db: db, call: 99) }
    }

    private func outlineWithAssistant(_ path: String, language: String?, root: URL, db: SemanticDatabase?, call: Int) async {
        let url = root.appendingPathComponent(path)
        guard let signature = XRayContent.signature(of: url),
              let text = await Task.detached(priority: .utility, operation: { try? String(contentsOf: url, encoding: .utf8) }).value
        else { return }
        outlining.insert(path)
        revision += 1
        defer { outlining.remove(path); revision += 1 }
        let outputLanguage = ActionOutputLanguage.current
        let languageLine = XRayContent.languageLine(summaries: outputLanguage == ActionOutputLanguage.documentLanguage
                                                    ? "the language of the file" : outputLanguage)
        var request = CLICompletion.Request(
            prompt: XRayContent.numbered(text, name: path),
            systemPrompt: XRayContent.isDocument(language)
                ? XRayContent.documentSystemPrompt(languageLine: languageLine)
                : XRayContent.codeSystemPrompt(languageLine: languageLine),
            jsonSchema: XRayContent.documentSchema)
        request.timeout = 300
        do {
            let object = try await xrayCall(request, root: root, db: db, call: call)
            let outline = XRayContent.assistantOutline(from: object, text: text, signature: signature, language: outputLanguage)
            guard !outline.collections.isEmpty else { return }
            outlines[path] = outline
            XRayContent.save(outline, root: root, path: path)
        } catch is CancellationError {
            return
        } catch {
            self.error = "Could not read \((path as NSString).lastPathComponent): \(error.localizedDescription)"
        }
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
        guard let current = snapshot, let view = current.view(viewId),
              let filter = ImportanceRater.allFilters.first(where: { $0.id == filterId }),
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
                guard let path = node.path, let line = Int(node.id.split(separator: "#").last?.dropFirst() ?? "") else { continue }
                items.append(.init(key: node.id, label: node.name,
                                   detail: ImportanceRater.sectionText(text(of: path), fromLine: line)))
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
        setStatus(progress)
        Task {
            defer { rating.remove(key); if status == progress { setStatus(nil) } }
            let request = ImportanceRater.request(subject: isDocs ? .documentation : .code, filter: filter,
                                                  context: context, items: items,
                                                  language: Self.reasonLanguage)
            do {
                let result = try await CLICompletion.run(request)
                result.record(in: db)
                let ratings = ImportanceRater.parse(result.structured, keys: Set(items.map(\.key)), filter: filter)
                guard var next = snapshot else { return }
                for (k, var value) in ratings {
                    value.signature = signatures[k]
                    next.ratings[filterId, default: [:]][k] = value
                }
                commit(next, db: db)
            } catch {
                self.error = "\(filter.name) rating failed: \(error.localizedDescription)"
            }
        }
    }

    /// A user (or quick) filter over the whole project at once. A keyword search gives
    /// every file and document section a provisional level in seconds; the AI then
    /// confirms the strongest candidates, shown as each answer streams in.
    func searchFilter(filterId: String, root: URL, db: SemanticDatabase?) {
        guard let current = snapshot, filterId != ImportanceRater.importance.id,
              let filter = ImportanceRater.allFilters.first(where: { $0.id == filterId }),
              rating.insert("search|" + filterId).inserted else { return }
        // The ⚡ quick filter is a search: only what really matters is marked.
        if ImportanceRater.isTemporary(filterId) {
            aiSearch(filter: filter, snapshot: current, root: root, db: db)
            return
        }
        let files = current.view("modules")?.nodes.filter { $0.kind == "file" }.compactMap(\.path) ?? []
        let sections = (current.view("docs")?.nodes ?? []).filter { $0.kind == "section" && $0.path != nil }
            .map { (id: $0.id, name: $0.name, path: $0.path!) }
        let label = "Finding “\(filter.criterion)”…"
        setStatus(label)
        let cache = answerCache(root)
        let context = "System: \(current.systemName ?? root.lastPathComponent)" + (current.systemPurpose.map { " — " + $0 } ?? "")
        Task {
            defer { rating.remove("search|" + filterId); if status?.hasPrefix("Finding") == true || status?.hasPrefix("Checking") == true { setStatus(nil) } }
            do {
                let terms = try await FilterSearch.terms(for: filter, cache: cache)
                let found = await Task.detached(priority: .userInitiated) { () -> ([String: FilterSearch.Match], [String: FilterSearch.Match]) in
                    let byFile = FilterSearch.scoreFiles(files, root: root, terms: terms)
                    var bySection: [String: FilterSearch.Match] = [:]
                    var texts: [String: String] = [:]
                    for section in sections {
                        let text = texts[section.path] ?? ((try? String(contentsOf: root.appendingPathComponent(section.path), encoding: .utf8)) ?? "")
                        texts[section.path] = text
                        guard let line = Int(section.id.split(separator: "#").last?.dropFirst() ?? "") else { continue }
                        bySection[section.id] = FilterSearch.score(name: section.name, text: ImportanceRater.sectionText(text, fromLine: line, limit: 6000), terms: terms)
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
                guard var next = snapshot else { return }
                next.ratings[filterId] = table
                commit(next, db: db)

                // The AI confirms the strongest candidates (evidence: the lines around the hit).
                let top = found.0.filter { $0.value.score > 0 }.sorted { ($0.value.score, $1.key) > ($1.value.score, $0.key) }.prefix(40)
                guard !top.isEmpty else { return }
                setStatus("Checking \(top.count) candidates…")
                let items = await Task.detached { () -> [ImportanceRater.Item] in
                    top.map { path, match in
                        let text = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
                        return ImportanceRater.Item(key: "p:" + path, label: (path as NSString).lastPathComponent,
                                                    detail: "File \(path)\nMentions: \(match.hits.prefix(6).joined(separator: ", "))\n"
                                                        + FilterSearch.excerpt(of: text, terms: terms))
                    }
                }.value
                let request = ImportanceRater.request(subject: .code, filter: filter, context: context, items: items,
                                                      language: Self.reasonLanguage)
                let keys = Set(items.map(\.key))
                let result = try await CLICompletion.run(request, onActivity: { [weak self] activity in
                    guard case .answerDelta(let text) = activity else { return }
                    Task { @MainActor in self?.receiveRatings(text, filterId: filterId, filter: filter, keys: keys) }
                })
                result.record(in: db)
                liveRatings[filterId] = nil
                guard var confirmed = snapshot else { return }
                for (k, value) in ImportanceRater.parse(result.structured, keys: keys, filter: filter) {
                    confirmed.ratings[filterId, default: [:]][k] = value
                }
                commit(confirmed, db: db)
            } catch is CancellationError {
            } catch {
                self.error = "\(filter.name) filter failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - ⚡ Search filter

    /// Code elements behind search queries ("Explain with AI — everything related"), by criterion.
    var searchSymbols: [String: XRaySearch.Symbol] = [:]
    /// Tells the X-Ray to switch to this filter (a search started outside the X-Ray).
    private(set) var activateFilter: String?
    private var activateToken = 0

    /// Show the filter `id` in the X-Ray (the next payload switches the overlay to it).
    func activate(filterId: String) {
        activateToken += 1
        activateFilter = "\(filterId)|\(activateToken)"
        revision += 1
    }

    /// The ⚡ search: keyword candidates first (dashed red outlines, in seconds), then the AI
    /// reads the project and returns the places that matter; their files turn red and every
    /// other file stays uncoloured. Places stream in as the AI writes them.
    private func aiSearch(filter: ImportanceRater.Filter, snapshot current: ArchitectureSnapshot, root: URL, db: SemanticDatabase?) {
        let filterId = filter.id
        let files = current.view("modules")?.nodes.filter { $0.kind == "file" }.compactMap(\.path) ?? []
        let sections = (current.view("docs")?.nodes ?? []).filter { $0.kind == "section" && $0.path != nil }
            .compactMap { node -> (id: String, path: String, line: Int)? in
                guard let line = Int(node.id.split(separator: "#").last?.dropFirst() ?? "") else { return nil }
                return (node.id, node.path!, line)
            }
        let symbol = searchSymbols[filter.criterion]
        setStatus(symbol != nil ? "Finding everything related to \(symbol!.name)…" : "Searching “\(filter.criterion)”…")
        let cache = answerCache(root)
        Task {
            defer { rating.remove("search|" + filterId); if status?.hasPrefix("Search") == true || status?.hasPrefix("Finding") == true || status?.hasPrefix("AI") == true { setStatus(nil) } }
            do {
                // 1. Candidates in seconds: keyword hits, or where the element is defined and used.
                let hints: [String]
                var table: [String: ImportanceRater.Rating] = [:]
                if let symbol {
                    hints = await Task.detached(priority: .userInitiated) { XRaySearch.symbolHints(symbol, root: root) }.value
                    table["p:" + symbol.path] = .init(level: "strong", reason: "Defines \(symbol.name)", provisional: true)
                } else {
                    let terms = try await FilterSearch.terms(for: filter, cache: cache)
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
                guard var next = snapshot else { return }
                next.ratings[filterId] = table
                commit(next, db: db)
                setStatus("AI is reading the project for “\(symbol?.name ?? filter.criterion)”…")

                // 2. The AI's places: their files (and document sections) are what matters.
                let request = XRaySearch.request(query: filter.criterion, symbol: symbol, hints: hints, root: root)
                let result = try await CLICompletion.run(request, onActivity: { activity in
                    Task { @MainActor in self.receiveSearch(activity, filterId: filterId, root: root, sections: sections) }
                })
                result.record(in: db)
                liveSearch[filterId] = nil
                let object = result.structured as? [String: Any]
                let places = await Task.detached { XRaySearch.places(from: object?["steps"], root: root) }.value
                guard var done = snapshot else { return }
                done.ratings[filterId] = Self.searchTable(places, sections: sections, confirmed: true)
                commit(done, db: db)
                if let summary = (object?["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    searchSummaries[filterId] = summary
                }
                revision += 1
            } catch is CancellationError {
            } catch {
                self.error = "Search failed: \(error.localizedDescription)"
            }
        }
    }

    /// What the AI said about the search as a whole, by filter id (shown in the details panel).
    private(set) var searchSummaries: [String: String] = [:]
    private var liveSearch: [String: String] = [:]
    private var liveSearchPending: Set<String> = []

    private func receiveSearch(_ activity: CLICompletion.Activity, filterId: String, root: URL,
                               sections: [(id: String, path: String, line: Int)]) {
        switch activity {
        case .read(let path):
            let base = root.standardizedFileURL.path + "/"
            setStatus("AI is reading " + (path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path))
        case .answerDelta(let text):
            liveSearch[filterId, default: ""] += text
            guard liveSearchPending.insert(filterId).inserted else { return }
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                liveSearchPending.remove(filterId)
                guard let answer = liveSearch[filterId] else { return }
                let places = await Task.detached {
                    XRaySearch.places(from: XRayDigest.completedObjects(in: answer, key: "steps"), root: root)
                }.value
                guard !places.isEmpty, var next = snapshot, liveSearch[filterId] != nil else { return }
                // Keyword candidates stay dashed until the answer is complete.
                var table = next.ratings[filterId] ?? [:]
                for (key, value) in Self.searchTable(places, sections: sections, confirmed: true) where value.level == "strong" {
                    table[key] = value
                }
                next.ratings[filterId] = table
                snapshot = next     // live; saved when the answer is complete
                revision += 1
            }
        default:
            break
        }
    }

    /// Ratings from the search's places: "strong" for every file with a place (and every
    /// document section a place falls in), "none" for nothing else — unrated means uncoloured.
    nonisolated private static func searchTable(_ places: [XRaySearch.Place], sections: [(id: String, path: String, line: Int)],
                                                confirmed: Bool) -> [String: ImportanceRater.Rating] {
        var table: [String: ImportanceRater.Rating] = [:]
        let byPath = Dictionary(grouping: places, by: \.path)
        for (path, found) in byPath {
            table["p:" + path] = .init(level: "strong", reason: XRaySearch.reason(for: found), provisional: !confirmed)
        }
        let sectionsByPath = Dictionary(grouping: sections, by: \.path)
        for (path, found) in byPath {
            let ordered = (sectionsByPath[path] ?? []).sorted { $0.line < $1.line }
            for (i, section) in ordered.enumerated() {
                let end = i + 1 < ordered.count ? ordered[i + 1].line - 1 : Int.max
                let inside = found.filter { $0.start <= end && $0.end >= section.line }
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
            guard let answer = liveRatings[filterId], var next = snapshot else { return }
            let rows = XRayDigest.completedObjects(in: answer, key: "ratings")
            let parsed = ImportanceRater.parse(["ratings": rows], keys: keys, filter: filter)
            guard !parsed.isEmpty else { return }
            for (k, value) in parsed { next.ratings[filterId, default: [:]][k] = value }
            snapshot = next     // live; saved when the answer is complete
            revision += 1
        }
    }

    /// Filters changed elsewhere (created in the code viewer); re-render.
    func filtersChanged() { revision += 1 }

    /// Drop this project's ratings for a deleted filter.
    func forgetRatings(filterId: String, db: SemanticDatabase?) {
        guard var next = snapshot, next.ratings[filterId] != nil else { revision += 1; return }
        next.ratings[filterId] = nil
        commit(next, db: db)
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
        Task {
            defer { describing.remove(nodeId); revision += 1 }
            let children = view.nodes.filter { $0.parent == nodeId }.prefix(30).map(\.name).joined(separator: ", ")
            var request = CLICompletion.Request(
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
                let result = try await CLICompletion.run(request)
                result.record(in: db)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard var next = snapshot, !text.isEmpty else { return }
                // Store on the Modules node (the source of truth) and re-derive the Logical view.
                let path = node.path
                if let m = next.views.firstIndex(where: { $0.id == "modules" }),
                   let i = next.views[m].nodes.firstIndex(where: { $0.path == path && $0.kind == node.kind }) {
                    next.views[m].nodes[i].summary = text
                    next.views[m].nodes[i].summarySignature = next.views[m].nodes[i].signature
                }
                next = Self.applyLogical(next)
                commit(next, db: db)
            } catch {
                self.error = "Could not describe \(node.name): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Pull request overlay

    /// Set when the PR X-Ray opens without a change chosen: show all local changes vs main.
    var selectDefaultSource = false

    func refreshPRSources(root: URL) {
        Task {
            let sources = await Task.detached { Self.listPRSources(root: root) }.value
            prSources = sources
            revision += 1
            if selectDefaultSource {
                selectDefaultSource = false
                if prOverlay == nil, let first = sources.first(where: { $0.id == "local" }) ?? sources.first {
                    showPR(first.id, root: root)
                }
            }
        }
    }

    nonisolated private static func listPRSources(root: URL) -> [PRSource] {
        guard ArchitectureScanner.runTool("/usr/bin/env", ["git", "-C", root.path, "rev-parse", "--is-inside-work-tree"]) != nil else {
            return []
        }
        // Two kinds of change: this checkout (what a pull request from here would contain:
        // commits since the base plus uncommitted and new files), or a pull request on
        // GitHub, fetched and read at its own head.
        var sources: [PRSource] = []
        if let base = baseBranch(root: root) {
            sources.append(PRSource(id: "local", title: "All changes vs \(base.replacingOccurrences(of: "origin/", with: "")) (commits + uncommitted)"))
        }
        // Every open pull request, then the 30 most recently merged or closed ones (two
        // queries: with one, old open ones fall outside the limit behind recent merges).
        var prs: [[String: Any]] = []
        for (state, limit) in [("open", "50"), ("closed", "30")] {
            if let json = runGH(["pr", "list", "--state", state, "--limit", limit, "--json", "number,title,state"], root: root),
               let data = json.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                prs += list
            }
        }
        do {
            for pr in prs {
                guard let number = pr["number"] as? Int else { continue }
                let state = (pr["state"] as? String ?? "").lowercased()
                sources.append(PRSource(id: "gh:\(number)",
                                        title: "#\(number) \(pr["title"] as? String ?? "")" + (state == "open" || state.isEmpty ? "" : " (\(state))")))
            }
        }
        return sources
    }

    /// Open pull requests of the repository at `root` (`gh`), newest first; empty without `gh`.
    nonisolated static func openPullRequests(root: URL) -> [(number: Int, title: String)] {
        guard let json = runGH(["pr", "list", "--state", "open", "--limit", "50", "--json", "number,title"], root: root),
              let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return list.compactMap { pr in
            (pr["number"] as? Int).map { ($0, pr["title"] as? String ?? "") }
        }
    }

    nonisolated private static func baseBranch(root: URL) -> String? {
        if let head = ArchitectureScanner.runTool("/usr/bin/env", ["git", "-C", root.path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty { return head }
        for candidate in ["main", "master", "origin/main", "origin/master"] {
            if ArchitectureScanner.runTool("/usr/bin/env", ["git", "-C", root.path, "rev-parse", "--verify", "--quiet", candidate]) != nil {
                return candidate
            }
        }
        return nil
    }

    /// `gh` with the same PATH the AI CLIs get (Homebrew and friends).
    nonisolated private static func runGH(_ arguments: [String], root: URL) -> String? {
        let path = CLIToolLocator.subprocessPath(toolPath: nil)
        let directory = path.split(separator: ":").map(String.init)
            .first { FileManager.default.isExecutableFile(atPath: $0 + "/gh") }
        guard let directory else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: directory + "/gh")
        process.arguments = arguments
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    nonisolated private static func diff(for source: PRSource, root: URL) -> String? {
        switch source.id {
        case "local":
            guard let base = baseBranch(root: root),
                  let mergeBase = ArchitectureScanner.runTool("/usr/bin/env", ["git", "-C", root.path, "merge-base", base, "HEAD"])?
                      .trimmingCharacters(in: .whitespacesAndNewlines), !mergeBase.isEmpty,
                  let tracked = ArchitectureScanner.runTool("/usr/bin/env", ["git", "-C", root.path, "diff", mergeBase, "--no-color", "-U3"])
            else { return nil }
            return tracked + untrackedDiff(root: root)
        default:
            guard source.id.hasPrefix("gh:") else { return nil }
            let number = String(source.id.dropFirst(3))
            if let checkout = fetchPR(number: number, root: root),
               let diff = ArchitectureScanner.runTool("/usr/bin/env", ["git", "-C", root.path, "diff", checkout.mergeBase, checkout.head, "--no-color", "-U3"]) {
                return diff
            }
            // Not fetchable (offline, no access): GitHub's diff; files are then the local ones.
            return runGH(["pr", "diff", number, "--color", "never"], root: root)
        }
    }

    /// A pull request fetched into the local repository: its head commit and where it
    /// branched from its base. Nothing is checked out; the working copy stays as it is.
    struct PRCheckout: Sendable {
        let number: String
        let head: String
        let mergeBase: String
    }

    /// Fetch pull request `number` (`pull/<n>/head`) and its base branch, unless already here.
    nonisolated static func fetchPR(number: String, root: URL) -> PRCheckout? {
        guard let json = runGH(["pr", "view", number, "--json", "headRefOid,baseRefName"], root: root),
              let info = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let head = info["headRefOid"] as? String, let baseName = info["baseRefName"] as? String else { return nil }
        func git(_ arguments: [String]) -> String? {
            // Never wait for a password prompt that cannot be answered.
            ArchitectureScanner.runTool("/usr/bin/env", ["GIT_TERMINAL_PROMPT=0", "git", "-C", root.path] + arguments)
        }
        if git(["cat-file", "-e", head + "^{commit}"]) == nil {
            _ = git(["fetch", "--no-tags", "--quiet", "origin", "pull/\(number)/head"])
            guard git(["cat-file", "-e", head + "^{commit}"]) != nil else { return nil }
        }
        _ = git(["fetch", "--no-tags", "--quiet", "origin", baseName])
        guard let mergeBase = git(["merge-base", "origin/" + baseName, head])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mergeBase.isEmpty else { return nil }
        return PRCheckout(number: number, head: head, mergeBase: mergeBase)
    }

    /// The pull request's version of `path`, written to MarkView's cache so the viewer
    /// shows the code under review (not the working copy). Nil for local changes.
    func prFileURL(path: String) -> URL? {
        guard let checkout = prCheckout, let root = prRoot,
              !path.split(separator: "/").contains("..") else { return nil }
        let base = Self.prCacheRoot(root: root, checkout: checkout)
        let file = base.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let text = ArchitectureScanner.runTool("/usr/bin/env", ["git", "-C", root.path, "show", "\(checkout.head):\(path)"]) else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
        return file
    }

    /// Project-relative path of a file shown from the fetched pull request, else nil.
    func prRelativePath(for url: URL) -> String? {
        guard let checkout = prCheckout, let root = prRoot else { return nil }
        let base = Self.prCacheRoot(root: root, checkout: checkout).standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

    nonisolated private static func prCacheRoot(root: URL, checkout: PRCheckout) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let repo = String(ContentHash.of(root.standardizedFileURL.path).prefix(12))
        return caches.appendingPathComponent("MarkView/pull-requests/\(repo)/PR-\(checkout.number)-\(checkout.head.prefix(10))", isDirectory: true)
    }

    /// New files git does not track yet, as additions (text files up to 512 KB, at most 200).
    nonisolated private static func untrackedDiff(root: URL) -> String {
        guard let list = ArchitectureScanner.runTool("/usr/bin/env", ["git", "-C", root.path, "ls-files", "--others", "--exclude-standard"])
        else { return "" }
        var out = ""
        for path in list.split(separator: "\n").prefix(200).map(String.init) {
            let url = root.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url), data.count <= 512 * 1024, !data.contains(0),
                  let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
            let lines = text.editorLines
            out += "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(lines.count) @@\n"
            out += lines.map { "+" + $0 }.joined(separator: "\n") + "\n"
        }
        return out
    }

    /// Added and removed lines of every file in a unified diff.
    nonisolated static func diffLines(_ diff: String) -> [String: (added: String, removed: String)] {
        var out: [String: (added: String, removed: String)] = [:]
        var current: String?
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                current = path == "/dev/null" ? nil : (path.hasPrefix("b/") ? String(path.dropFirst(2)) : path)
                if let current, out[current] == nil { out[current] = ("", "") }
            } else if line.hasPrefix("--- ") || line.hasPrefix("diff --git ") {
                continue
            } else if let path = current, line.hasPrefix("+") {
                out[path]!.added += line.dropFirst() + "\n"
            } else if let path = current, line.hasPrefix("-") {
                out[path]!.removed += line.dropFirst() + "\n"
            }
        }
        return out
    }

    /// Parse a unified diff into per-file line counts and touched new-file ranges.
    nonisolated static func parseDiff(_ diff: String) -> [PRFileChange] {
        var files: [PRFileChange] = []
        var current: PRFileChange?
        var newLine = 0
        var rangeStart: Int?
        func closeRange(_ end: Int) {
            if let start = rangeStart, current != nil { current!.ranges.append([start, max(start, end)]) }
            rangeStart = nil
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                closeRange(newLine - 1)
                if let file = current { files.append(file) }
                current = nil
            } else if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                if path != "/dev/null" {
                    current = PRFileChange(path: path.hasPrefix("b/") ? String(path.dropFirst(2)) : path,
                                           additions: 0, deletions: 0, ranges: [])
                }
            } else if line.hasPrefix("@@") {
                closeRange(newLine - 1)
                // @@ -a,b +c,d @@
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    newLine = Int(plus.dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
            } else if current != nil {
                if line.hasPrefix("+") {
                    current!.additions += 1
                    if rangeStart == nil { rangeStart = newLine }
                    newLine += 1
                } else if line.hasPrefix("-") {
                    current!.deletions += 1
                    if rangeStart == nil { rangeStart = newLine }
                } else {
                    closeRange(newLine - 1)
                    newLine += 1
                }
            }
        }
        closeRange(newLine - 1)
        if let file = current { files.append(file) }
        return files
    }

    /// Show which files a change touches (no AI).
    func showPR(_ sourceId: String, root: URL) {
        // Any pull request by number, also one not in the list (older, merged, closed).
        if sourceId.hasPrefix("gh:"), !prSources.contains(where: { $0.id == sourceId }), Int(sourceId.dropFirst(3)) != nil {
            prSources.append(PRSource(id: sourceId, title: "#" + sourceId.dropFirst(3)))
        }
        guard let source = prSources.first(where: { $0.id == sourceId }) else {
            prOverlay = nil
            revision += 1
            return
        }
        error = nil
        Task {
            guard await loadPR(source, root: root) else { return }
            if analyzeWhenLoaded { analyzeWhenLoaded = false; analyzePR(root: root, db: nil) }
        }
    }

    /// Read the change as it is now: diff, files, links. Questions asked so far are kept
    /// when it is the change already shown.
    @discardableResult
    private func loadPR(_ source: PRSource, root: URL, keepReview: Bool = false) async -> Bool {
        prRoot = root
        setStatus("Loading \(source.title)…")
        let (diff, checkout) = await Task.detached { () -> (String?, PRCheckout?) in
            let checkout = source.id.hasPrefix("gh:") ? Self.fetchPR(number: String(source.id.dropFirst(3)), root: root) : nil
            return (Self.diff(for: source, root: root), checkout)
        }.value
        guard let diff else {
            error = source.id.hasPrefix("gh:")
                ? "Could not load the pull request. Check that GitHub CLI (gh) is installed and signed in."
                : "Could not read the changes from git."
            setStatus(nil)
            return false
        }
        prCheckout = checkout
        let files = snapshot?.view("modules")?.nodes.filter { $0.kind == "file" }.compactMap(\.path) ?? []
        let dependencies = await Task.detached { () -> [PRDependency] in
            ArchitectureScanner.dependencyChanges(lines: Self.diffLines(diff), projectFiles: files)
                .map { PRDependency(source: $0.source, target: $0.target, change: $0.added ? "added" : "removed") }
        }.value
        let previous = prOverlay?.source.id == source.id ? prOverlay : nil
        let changed = diff != prDiffText
        prDiffText = diff
        prFileDiffs = Self.splitDiff(diff)
        var overlay = PROverlay(source: source, files: Self.parseDiff(diff), reviewed: false, dependencies: dependencies)
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
        prOverlay = overlay
        setStatus(nil)
        return true
    }

    /// The code changed, or the review should be redone: read the change again, then
    /// review it (and repeat the architectural analysis if there was one) without the
    /// cached answers.
    func reviewAgain(root: URL, db: SemanticDatabase?) {
        guard !busy, let source = prOverlay?.source else { return }
        let hadAnalysis = prOverlay?.analysis != nil
        Task {
            guard await loadPR(source, root: root) else { return }
            reviewPR(root: root, db: db, fresh: true)
            if hadAnalysis { analyzePR(root: root, db: db, fresh: true) }
        }
    }

    /// The review's findings and the analysis's checks as a task list — to paste into the
    /// AI terminal or the clipboard. Nil when there is nothing to do.
    func prTasksText() -> String? {
        guard let overlay = prOverlay else { return nil }
        var bugs: [String] = [], warnings: [String] = [], notes: [String] = []
        for file in overlay.files {
            for finding in file.findings ?? [] {
                let line = "- [ ] \(file.path)\(finding.line > 0 ? ":\(finding.line)" : "") — \(finding.message)"
                switch finding.severity {
                case "bug": bugs.append(line)
                case "warning": warnings.append(line)
                default: notes.append(line)
                }
            }
            if (file.findings ?? []).isEmpty, let verdict = file.verdict, verdict != "ok", let summary = file.summary {
                let line = "- [ ] \(file.path) — \(summary)"
                if verdict == "bug" { bugs.append(line) } else { warnings.append(line) }
            }
        }
        var checks: [String] = []
        if let analysis = overlay.analysis {
            checks = analysis.checks.map { "- [ ] \($0.path)\($0.line > 0 ? ":\($0.line)" : "") — \($0.note)" }
                + analysis.risks.map { "- [ ] Risk: \($0)" }
        }
        let sections = [("Bugs", bugs), ("Concerns", warnings), ("Notes", notes), ("To check", checks)].filter { !$0.1.isEmpty }
        guard !sections.isEmpty else { return nil }
        return "Tasks from the review of \(overlay.source.title). Check each one; fix it, or say why it is not a real problem.\n\n"
            + sections.map { "## \($0.0)\n" + $0.1.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// Each file's part of a unified diff, keyed by its new path.
    nonisolated static func splitDiff(_ diff: String) -> [String: String] {
        var out: [String: String] = [:]
        var current: String?
        var lines: [Substring] = []
        func flush() { if let current { out[current] = lines.joined(separator: "\n") }; lines = [] }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { flush(); current = nil; continue }
            if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                current = path == "/dev/null" ? current : (path.hasPrefix("b/") ? String(path.dropFirst(2)) : path)
                continue
            }
            if line.hasPrefix("--- ") {
                // A deleted file keeps its old path.
                let path = String(line.dropFirst(4))
                if path != "/dev/null" { current = path.hasPrefix("a/") ? String(path.dropFirst(2)) : path }
                continue
            }
            if line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity") { continue }
            lines.append(line)
        }
        flush()
        return out
    }

    /// Show one changed file's diff in the PR X-Ray.
    func showFileDiff(path: String) {
        guard prOverlay != nil else { return }
        prOverlay?.fileDiff = PRFileDiff(path: path, text: prFileDiffs[path] ?? "")
        revision += 1
    }

    // MARK: Changes inside a file

    /// The loaded change as the code viewer's "Pull request" lens shows it for one file:
    /// added lines, where lines were removed, and each change with its explanation and
    /// its own lines of the diff. Nil when the file is not part of the change.
    struct PRFileNotes: Encodable {
        struct Change: Encodable {
            var title: String
            var start: Int
            var end: Int
            var kind: String?
            var why: String?
            /// The change's lines of the diff ("+…", "-…").
            var diff: [String]
        }
        var title: String
        var summary: String?
        var explaining: Bool
        var explained: Bool
        var additions: Int
        var deletions: Int
        var changes: [Change]
        /// Added new-file line ranges.
        var added: [[Int]]
        /// [line, count]: where lines were removed.
        var removed: [[Int]]
        /// Opened from the PR X-Ray: show this lens.
        var focus: Bool
        /// The file differs from the change's version: lines were matched by content.
        var remapped: Bool
        /// Identifies the diff (a new one needs a new explanation).
        var diffKey: String
        var reviewOutdated: Bool
    }

    /// New-file line numbers of a diff → lines of the file as it is now, matched by
    /// content (longest common subsequence over the diff's new-side lines).
    struct LineMap {
        let inSync: Bool
        private let mapped: [Int: Int]
        private let known: [Int]   // sorted diff positions that were matched

        init(inSync: Bool, mapped: [Int: Int]) {
            self.inSync = inSync
            self.mapped = mapped
            self.known = mapped.keys.sorted()
        }

        /// The current line for a diff line: its match, else shifted like the nearest match.
        func line(_ position: Int) -> Int {
            if inSync { return position }
            if let exact = mapped[position] { return exact }
            guard !known.isEmpty else { return position }
            var low = 0, high = known.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if known[mid] <= position { low = mid } else { high = mid - 1 }
            }
            let anchor = known[low] <= position ? known[low] : known[0]
            return max(1, position + (mapped[anchor]! - anchor))
        }

        func exists(_ position: Int) -> Bool { inSync || mapped[position] != nil }
    }

    nonisolated static func lineMap(diff: String, current: String) -> LineMap {
        // The diff's new side: positions and texts of context and added lines.
        var side: [(position: Int, text: Substring)] = []
        var newLine = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    newLine = Int(plus.dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
            } else if line.hasPrefix("+") || line.hasPrefix(" ") {
                side.append((newLine, line.dropFirst()))
                newLine += 1
            }
        }
        let lines = current.editorLines
        func same(_ a: Substring, _ b: Substring) -> Bool {
            a.trimmingCharacters(in: .whitespaces) == b.trimmingCharacters(in: .whitespaces)
        }
        if side.allSatisfy({ $0.position >= 1 && $0.position <= lines.count && same(lines[$0.position - 1], $0.text) }) {
            return LineMap(inSync: true, mapped: [:])
        }
        let n = side.count, m = lines.count
        guard n > 0, m > 0, n * m <= 8_000_000 else { return LineMap(inSync: false, mapped: [:]) }
        let a = side.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let b = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        // LCS table (suffix lengths), then walk it forward.
        var table = [UInt16](repeating: 0, count: (n + 1) * (m + 1))
        let width = m + 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = a[i] == b[j]
                    ? table[(i + 1) * width + j + 1] &+ 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var mapped: [Int: Int] = [:]
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                mapped[side[i].position] = j + 1
                i += 1; j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return LineMap(inSync: false, mapped: mapped)
    }

    func markPRFocus(path: String) {
        prFocusPaths.insert(path)
    }

    func prFileNotes(path: String, content: String) -> PRFileNotes? {
        guard let overlay = prOverlay.map(withChangeNotes),
              let file = overlay.files.first(where: { $0.path == path }) else { return nil }
        let diff = prFileDiffs[path] ?? ""
        let map = Self.lineMap(diff: diff, current: content)
        // Local changes moved on (new commits, edits): read them again, at most every 10 s.
        if !map.inSync, overlay.source.id == "local", let root = prRoot,
           Date().timeIntervalSince(prReloadedAt) > 10 {
            prReloadedAt = Date()
            let source = overlay.source
            Task { await loadPR(source, root: root, keepReview: true) }
        }
        // Walk the diff once: added runs, removal points, and each line's new-file position.
        var added: [[Int]] = []
        var removed: [[Int]] = []
        var lines: [(position: Int, text: String)] = []
        var newLine = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    newLine = Int(plus.dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
            } else if line.hasPrefix("+") {
                if let last = added.last, last[1] == newLine - 1 { added[added.count - 1][1] = newLine } else { added.append([newLine, newLine]) }
                lines.append((newLine, String(line)))
                newLine += 1
            } else if line.hasPrefix("-") {
                let at = max(newLine, 1)
                if let last = removed.last, last[0] == at { removed[removed.count - 1][1] += 1 } else { removed.append([at, 1]) }
                lines.append((at, String(line)))
            } else if !line.hasPrefix("\\") {
                newLine += 1
            }
        }
        let changes = (file.changes ?? []).map { note -> PRFileNotes.Change in
            let own = lines.filter { $0.position >= note.start && $0.position <= note.end }.map(\.text)
            let start = map.line(note.start)
            return PRFileNotes.Change(title: note.title, start: start, end: max(start, map.line(note.end)),
                                      kind: note.kind, why: note.why, diff: Array(own.prefix(60)))
        }
        // Added lines still in the file, at their current lines; removal points shifted along.
        var current: [[Int]] = []
        for range in added {
            for position in range[0]...range[1] where map.exists(position) {
                let line = map.line(position)
                if let last = current.last, last[1] == line - 1 { current[current.count - 1][1] = line } else { current.append([line, line]) }
            }
        }
        return PRFileNotes(title: overlay.source.title, summary: file.changeSummary, explaining: file.explaining == true,
                           explained: file.changeSummary != nil, additions: file.additions, deletions: file.deletions,
                           changes: changes, added: current, removed: removed.map { [map.line($0[0]), $0[1]] },
                           focus: prFocusPaths.contains(path), remapped: !map.inSync,
                           diffKey: String(ContentHash.of(diff).prefix(12)), reviewOutdated: overlay.reviewOutdated == true)
    }

    private func explanationKey(_ source: PRSource, _ path: String) -> String {
        source.id + "|" + path + "|" + String(ContentHash.of(prFileDiffs[path] ?? "").prefix(16))
    }

    /// The overlay with what changed inside each file: the AI's explanation when there is
    /// one, else the touched lines placed in the file's X-Ray parts and items.
    private func withChangeNotes(_ overlay: PROverlay) -> PROverlay {
        var next = overlay
        for i in next.files.indices {
            let path = next.files[i].path
            let key = explanationKey(overlay.source, path)
            let spans = Self.itemSpans(outlines[path])
            if let explained = prExplanations[key] {
                next.files[i].changeSummary = explained.summary
                next.files[i].changes = explained.notes.map { note in
                    var note = note
                    if note.part?.isEmpty != false { note.part = Self.part(at: note.start, in: spans) }
                    return note
                }
            } else {
                next.files[i].changes = Self.changeNotes(hunks: Self.changedRanges(prFileDiffs[path] ?? ""), spans: spans)
            }
            next.files[i].explaining = prExplaining.contains(key) ? true : nil
        }
        return next
    }

    /// Items of a file's X-Ray contents with the lines they cover (to the next item).
    nonisolated private static func itemSpans(_ outline: XRayContent.Outline?)
        -> [(part: String, name: String, start: Int, end: Int)] {
        guard let outline else { return [] }
        var items: [(part: String, name: String, start: Int)] = []
        for collection in outline.collections {
            for group in collection.groups {
                for item in group.items { items.append((collection.name, item.name, item.line)) }
            }
        }
        items.sort { $0.start < $1.start }
        return items.enumerated().map { index, item in
            let end = index + 1 < items.count ? max(item.start, items[index + 1].start - 1) : Int.max
            return (item.part, item.name, item.start, end)
        }
    }

    nonisolated private static func part(at line: Int, in spans: [(part: String, name: String, start: Int, end: Int)]) -> String? {
        spans.last { $0.start <= line }?.part
    }

    /// Changed new-file line ranges of a file's diff: runs of added and removed lines
    /// (a removal alone marks the line where the text was).
    nonisolated static func changedRanges(_ diff: String) -> [[Int]] {
        var ranges: [[Int]] = []
        var newLine = 0
        var run: [Int]?
        func close() { if let r = run { ranges.append(r) }; run = nil }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                close()
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    newLine = Int(plus.dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
            } else if line.hasPrefix("+") {
                run = [min(run?[0] ?? newLine, newLine), newLine]
                newLine += 1
            } else if line.hasPrefix("-") {
                let at = max(newLine, 1)
                run = [min(run?[0] ?? at, at), max(run?[1] ?? at, at)]
            } else if line.hasPrefix("\\") {
                continue
            } else {
                close()
                newLine += 1
            }
        }
        close()
        return ranges
    }

    /// Changed ranges placed in the items they touch; outside any item, "Lines a–b".
    nonisolated private static func changeNotes(hunks: [[Int]],
                                                spans: [(part: String, name: String, start: Int, end: Int)]) -> [PRChangeNote] {
        var notes: [PRChangeNote] = []
        var index: [String: Int] = [:]
        for range in hunks {
            let (a, b) = (range[0], range[1])
            let touched = spans.filter { $0.start <= b && $0.end >= a }
            if touched.isEmpty {
                notes.append(PRChangeNote(part: nil, title: a == b ? "Line \(a)" : "Lines \(a)–\(b)", start: a, end: b))
                continue
            }
            for item in touched {
                let key = item.part + "\u{1}" + item.name
                let start = max(a, item.start), end = min(b, item.end)
                if let i = index[key] {
                    notes[i].start = min(notes[i].start, start)
                    notes[i].end = max(notes[i].end, end)
                } else {
                    index[key] = notes.count
                    notes.append(PRChangeNote(part: item.part, title: item.name, start: start, end: end))
                }
            }
            if notes.count >= 200 { break }
        }
        return notes
    }

    /// The AI's reading of one file's change — only what changed, split into its logical
    /// changes with what each does and why. The diff and the file's X-Ray parts are the
    /// whole input (no file reading); cached by the diff.
    func explainPRFile(path: String, root: URL, db: SemanticDatabase?) {
        guard let overlay = prOverlay, let diff = prFileDiffs[path], !diff.isEmpty else { return }
        let key = explanationKey(overlay.source, path)
        guard prExplanations[key] == nil, !prExplaining.contains(key) else { return }
        prExplaining.insert(key)
        revision += 1
        let spans = Self.itemSpans(outlines[path])
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
        prompt += "\nDiff (new-file line numbers on the left):\n" + Self.numberedDiff(diff)
        let outputLanguage = ActionOutputLanguage.current
        var request = CLICompletion.Request(
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
            defer { prExplaining.remove(key); revision += 1 }
            do {
                let object = try await xrayCall(request, root: root, db: db, call: 98)
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
                self.error = "Could not explain the changes in \((path as NSString).lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// A file's diff with new-file line numbers on the left (clipped), for the prompt.
    nonisolated private static func numberedDiff(_ diff: String, maxLines: Int = 1500) -> String {
        var out: [String] = []
        var newLine = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if out.count >= maxLines { out.append("… (diff clipped)"); break }
            if line.hasPrefix("@@") {
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    newLine = Int(plus.dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
                out.append(String(line))
            } else if line.hasPrefix("+") {
                out.append("\(newLine) + " + line.dropFirst()); newLine += 1
            } else if line.hasPrefix("-") {
                out.append("     - " + line.dropFirst())
            } else if !line.hasPrefix("\\") {
                out.append("\(newLine)   " + line.dropFirst()); newLine += 1
            }
        }
        return out.joined(separator: "\n")
    }

    /// Ask the AI about the loaded change — the whole of it, or one file — with the
    /// analysis and the diff as context. The answer streams into the chat.
    func askPR(question: String, path: String?, root: URL, db: SemanticDatabase?) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let overlay = prOverlay, !question.isEmpty else { return }
        let index = overlay.chat.count
        prOverlay?.chat.append(PRChat(question: question, path: path, answer: "", pending: true))
        revision += 1
        var context = "Change: \(overlay.source.title)\n"
        if let a = overlay.analysis {
            context += "Architectural review: \(a.summary)\nRisks:\n" + a.risks.map { "- " + $0 }.joined(separator: "\n") + "\n"
        }
        let earlier = overlay.chat.suffix(4).map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
        if !earlier.isEmpty { context += "\nEarlier questions:\n" + earlier + "\n" }
        let diff = path.flatMap { prFileDiffs[$0] }.map { "Diff of \(path!):\n" + $0 } ?? prDiffText
        let clipped = diff.count > 120_000 ? String(diff.prefix(120_000)) + "\n[diff truncated]" : diff
        var request = CLICompletion.Request(
            prompt: context + "\n```diff\n" + clipped + "\n```\n\nQuestion: " + question,
            systemPrompt: """
            You are a senior engineer and architect answering a reviewer's question about a pull request. Answer \
            directly and concretely from the diff: name files, functions and lines; say when the diff does not \
            show enough to be sure. Short paragraphs or a few bullets; plain text, no headings.
            """ + "\n\n" + ActionOutputLanguage.explanationLine())
        request.model = AIAssistantPreferences.xrayModel(for: request.tool)
        request.effort = "low"
        request.timeout = 300
        let source = overlay.source.id
        Task {
            var streamed = ""
            var pendingRefresh = false
            do {
                let result = try await CLICompletion.run(request, onDelta: { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.prOverlay?.source.id == source, index < (self.prOverlay?.chat.count ?? 0) else { return }
                        streamed += text
                        self.prOverlay?.chat[index].answer = streamed
                        guard !pendingRefresh else { return }
                        pendingRefresh = true
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        pendingRefresh = false
                        self.revision += 1
                    }
                })
                result.record(in: db)
                if prOverlay?.source.id == source, index < (prOverlay?.chat.count ?? 0) {
                    prOverlay?.chat[index].answer = result.text.isEmpty ? streamed : result.text
                }
            } catch is CancellationError {
            } catch {
                if prOverlay?.source.id == source, index < (prOverlay?.chat.count ?? 0) {
                    prOverlay?.chat[index].answer = "Failed: \(error.localizedDescription)"
                }
            }
            if prOverlay?.source.id == source, index < (prOverlay?.chat.count ?? 0) { prOverlay?.chat[index].pending = false }
            revision += 1
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
        revision += 1
        let source = overlay.source
        let current = snapshot
        Task {
            defer { prOverlay?.analyzing = nil; revision += 1; setStatus(nil) }
            setStatus("Analysing \(source.title)…")
            let diff = await Task.detached { Self.diff(for: source, root: root) }.value ?? ""
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
                """ + "\n\n" + Self.graphLanguageLine,
                jsonSchema: schema)
            request.timeout = 300
            do {
                let object = try await xrayCall(request, root: root, db: db, call: 0, fresh: fresh)
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
                self.error = "PR analysis failed: \(error.localizedDescription)"
            }
        }
    }

    /// Ask the assistant to review the loaded change file by file.
    func reviewPR(root: URL, db: SemanticDatabase?, fresh: Bool = false) {
        guard !busy, let overlay = prOverlay else { return }
        busy = true
        error = nil
        let source = overlay.source
        Task {
            defer { busy = false }
            setStatus("Reviewing \(source.title)…")
            let diff = await Task.detached { Self.diff(for: source, root: root) }.value ?? ""
            let key = SHA256.hash(data: Data(diff.utf8)).map { String(format: "%02x", $0) }.joined()
            if !fresh, let cached = db?.loadArchitectureReview(key: key),
               let data = cached.data(using: .utf8),
               let reviewed = try? JSONDecoder().decode(PROverlay.self, from: data) {
                prOverlay = reviewed
                setStatus(nil)
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
                prompt: "Change: \(source.title)\n\n```diff\n\(clipped)\n```",
                systemPrompt: """
                You are a senior engineer reviewing a code change. For every changed file judge whether the change \
                is correct and complete: verdict ok (no problems), concern (questionable design, missing handling, \
                risky), or bug (a defect that will misbehave). Report concrete findings with the line number in the \
                new file. Work only from the diff. Do not report style nits; keep messages short.
                """ + "\n\n" + Self.graphLanguageLine,
                jsonSchema: schema)
            request.model = AIAssistantPreferences.xrayModel(for: request.tool)
            request.effort = "low"
            request.timeout = 600
            do {
                let result = try await CLICompletion.run(request)
                result.record(in: db)
                let object = result.structured as? [String: Any] ?? [:]
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
                    db?.saveArchitectureReview(key: key, json: String(decoding: data, as: UTF8.self))
                }
            } catch is CancellationError {
            } catch {
                self.error = "Review failed: \(error.localizedDescription)"
            }
            setStatus(nil)
        }
    }

    // MARK: - Web view payload

    /// Everything the Architecture tab renders, as a JSON object literal.
    func payloadJSON(mode: String? = nil) -> String {
        struct Payload: Encodable {
            let mode: String?
            let snapshot: ArchitectureSnapshot?
            let status: String?
            let error: String?
            let prSources: [PRSource]
            let pr: PROverlay?
            let busy: Bool
            let describing: [String]
            let filters: [ImportanceRater.Filter]
            let root: String?
            let outlining: [String]
            /// "filterId|token": switch the overlay to this filter once per token.
            let activateFilter: String?
            /// The AI's summary of each ⚡ search, by filter id.
            let searchSummaries: [String: String]
        }
        let payload = Payload(mode: mode, snapshot: snapshot.map(withContents), status: status, error: error,
                              prSources: prSources, pr: prOverlay.map(withChangeNotes), busy: busy, describing: Array(describing),
                              filters: Array(ImportanceRater.allFilters.dropFirst()),
                              root: rootPath, outlining: Array(outlining), activateFilter: activateFilter,
                              searchSummaries: searchSummaries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
