import Foundation

/// Research maps (feature mind-map, DEC-004, DEC-008): New Research creates a map file, opens its
/// tab at once and runs one cancellable agent job that adds nodes to the open map as they are
/// written; Expand topic ("develop"), Continue and the three single-node actions (Expand description, Correct,
/// Research; REQ-006) are jobs of the same kind on an existing map.
extension ResearchJobs {
    // MARK: - New research

    /// Creates the map file at `relativePath` (a free name is chosen if it was taken meanwhile),
    /// opens it in a tab and starts the research.
    func start(question: String, relativePath: String, targets: [URL], attachments: [URL]) {
        guard let workspace, let root = workspace.rootNode?.url else { return }
        let file = Self.freeFile(root.appendingPathComponent(relativePath), root: root)
        let id = ResearchDocument.id(forPath: file.path)
        let map = ResearchMap.new(id: id, question: question, created: FeatureStore.today, targets: [], attachments: [])
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(map.markdown().utf8).write(to: file, options: .withoutOverwriting)
        } catch {
            message = "Could not create the research map: \(error.localizedDescription)"
            return
        }
        workspace.refreshFileTree()
        workspace.openFile(file)
        let label = "Research: " + Self.title(question)
        launchMapRun(file: file, root: root, kind: .map, title: label, mode: .research) { job, driver in
            let targetPaths = await Task.detached { ResearchScope.targetFiles(root: root, targets: targets) }.value
            job.update("Copying attachments")
            let copied = Self.copyAttachments(attachments, root: root, id: id)
            workspace.updateResearchMap(file) { map in
                map.targets = targetPaths
                map.attachments = copied
            }
            job.update("Listing the repository")
            let scope = await Task.detached { ResearchScope.files(root: root, always: targetPaths + copied) }.value
            let web = Self.web(root)
            let limits = ResearchMapRun.limits(for: .research)
            let prompt = ResearchMapPrompt.research(question: question, targets: targetPaths, attachments: copied,
                                                    scope: ResearchPrompt.scopeText(scope), limits: limits)
            return MapTask(prompt: prompt, web: web, noProjectFiles: scope.isEmpty)
        }
    }

    // MARK: - Develop a branch, continue

    /// Expand topic: the AI develops `node` of the map in `file`, in the direction the person gave (empty: its own
    /// choice). Returns a one-line reason when it cannot start.
    func developMap(file: URL, node: String, direction: String) -> String? {
        guard let workspace, let root = workspace.rootNode?.url else { return "No project is open." }
        if isRunning(on: file) { return "An AI job is already working on this map; develop the branch when it has finished." }
        guard case .success(let map)? = workspace.researchMapText(file).map({ ResearchMap.parse($0) }), let target = map.node(node) else {
            return "That node no longer exists."
        }
        launchMapRun(file: file, root: root, kind: .mapDevelop, title: "Expand topic: " + Self.title(target.title), mode: .develop(node: node)) { job, _ in
            job.update("Listing the repository")
            let scope = await Task.detached { ResearchScope.files(root: root, always: map.targets) }.value
            let limits = ResearchMapRun.limits(for: .develop(node: node))
            // The map as it is now, not as it was when the sheet opened.
            let current = workspace.researchMapText(file).flatMap { text -> ResearchMap? in
                if case .success(let m) = ResearchMap.parse(text) { return m }
                return nil
            } ?? map
            let prompt = ResearchMapPrompt.develop(map: current, node: current.node(node) ?? target, direction: direction,
                                                   scope: ResearchPrompt.scopeText(scope), limits: limits)
            return MapTask(prompt: prompt, web: Self.web(root), noProjectFiles: scope.isEmpty)
        }
        return nil
    }

    /// Expand description (REQ-006): the AI rewrites and extends the description of `node`; nothing else changes.
    func describeMap(file: URL, node: String) -> String? {
        runOnNode(file: file, node: node, kind: .mapDescribe, label: "Expand description", mode: .describe(node: node)) { map, target, scope in
            ResearchMapPrompt.describe(map: map, node: target, scope: scope)
        }
    }

    /// Correct (REQ-006): the AI rewrites `node` after what the person says is wrong with it.
    func correctMap(file: URL, node: String, note: String) -> String? {
        runOnNode(file: file, node: node, kind: .mapCorrect, label: "Correct", mode: .correct(node: node)) { map, target, scope in
            ResearchMapPrompt.correct(map: map, node: target, note: note, scope: scope)
        }
    }

    /// Research (REQ-006): the AI adds findings and web searches for `node` only.
    func investigateMap(file: URL, node: String) -> String? {
        runOnNode(file: file, node: node, kind: .mapInvestigate, label: "Research node", mode: .investigate(node: node)) { map, target, scope in
            ResearchMapPrompt.investigate(map: map, node: target, scope: scope)
        }
    }

    // MARK: - Draw

    /// Draw (REQ-012, DEC-013): the AI draws a diagram of `node` with the Graph Creator's generator and its checks, and adds it
    /// as a child of that node: a diagram node whose description holds the Mermaid block, the question and the takeaway, and
    /// whose evidence lists the files the diagram rests on. The node itself is unchanged. Returns a one-line reason when it
    /// cannot start.
    func drawMap(file: URL, node: String, kindID: String, instruction: String) -> String? {
        guard let workspace, let root = workspace.rootNode?.url else { return "No project is open." }
        guard let kind = DiagramKind(rawValue: kindID), ResearchMap.drawKinds.contains(where: { $0.id == kindID }) else {
            return "Choose one of the diagram types."
        }
        let wanted = String(instruction.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        if kind == .custom && wanted.isEmpty { return "Say what the diagram should show." }
        if isRunning(on: file) { return "An AI job is already working on this map; draw when it has finished." }
        guard case .success(let map)? = workspace.researchMapText(file).map({ ResearchMap.parse($0) }), let target = map.node(node) else {
            return "That node no longer exists."
        }
        let name = kind == .custom ? "Diagram" : kind.title
        launch(kind: .mapDraw, file: file, title: "Draw \(name.lowercased()): " + Self.title(target.title)) { [weak workspace] job in
            guard let workspace else { return nil }
            // The map as it is now, not as it was when the action was chosen.
            guard case .success(let current)? = workspace.researchMapText(file).map({ ResearchMap.parse($0) }),
                  let from = current.node(node) else { return "That node no longer exists." }
            var path: [String] = []
            var cursor: ResearchMap.Node? = from
            while let item = cursor, path.count < 12 {
                path.insert(item.title, at: 0)
                cursor = item.parent.isEmpty ? nil : current.node(item.parent)
            }
            let evidence = from.evidence.map { (label: $0.label.rawValue, text: $0.text, source: $0.source) }
            let prompt = DiagramAI.mapPrompt(kind: kind, instruction: wanted, question: current.question, path: path, title: from.title,
                                             nodeText: from.description, evidence: evidence, root: root)
            let language = DiagramAI.mapLanguage(title: from.title, nodeText: from.description, evidence: evidence)?.code
            do {
                let spec = try await DiagramAI.generate(prompt: prompt, root: root, label: "map-draw:\(kind.rawValue)", system: DiagramAI.mapSystem,
                                                        expectedLanguage: language,
                                                        onStage: { stage in Task { @MainActor in job.update(stage) } },
                                                        record: { result in Task { @MainActor in result.record(in: workspace.semanticDatabase) } })
                job.update("Adding the diagram to the map")
                var description = "```mermaid\n\(DiagramAI.plainMermaid(spec, kind: kind))\n```"
                if !spec.question.isEmpty { description += "\n\n**Question:** \(spec.question)" }
                if !spec.takeaway.isEmpty { description += "\n\n**Takeaway:** \(spec.takeaway)" }
                if let omitted = spec.omitted { description += "\n\n**Left out:** \(omitted)" }
                let evidence = spec.nodes.compactMap { item -> ResearchMap.Evidence? in
                    guard let source = item.source, !source.isEmpty else { return nil }
                    return ResearchMap.Evidence(label: .projectFact, text: item.label + (item.note.map { ": " + $0 } ?? ""), source: source)
                }
                let key = file.standardizedFileURL.path
                let result = workspace.updateResearchMap(file) { map in
                    guard map.node(node) != nil else { throw ResearchMap.Rejection(message: "That node no longer exists.") }
                    let id = try map.addNode(parent: node, draft: ResearchMap.Draft(title: spec.title.isEmpty ? name : spec.title, description: description, evidence: evidence))
                    try map.update(id: id, visual: "diagram")
                    // The next snapshot of this map tells the page to show and select the new child.
                    workspace.researchMapJobCreated[key] = id
                }
                switch result {
                case .rejected(let problem), .unreadable(let problem):
                    workspace.researchMapJobCreated[key] = nil
                    return "The diagram could not be added to the map: \(problem)"
                case .done:
                    return nil
                }
            } catch is CancellationError {
                return "Drawing stopped. The map is unchanged."
            } catch {
                return "The diagram could not be drawn: \(error.localizedDescription)"
            }
        }
        return nil
    }

    /// Starts one of the single-node actions. Returns a one-line reason when it cannot start.
    private func runOnNode(file: URL, node: String, kind: Job.Kind, label: String, mode: ResearchMapRun.Mode,
                           prompt: @escaping (ResearchMap, ResearchMap.Node, String) -> String) -> String? {
        guard let workspace, let root = workspace.rootNode?.url else { return "No project is open." }
        if isRunning(on: file) { return "An AI job is already working on this map; run this action when it has finished." }
        guard case .success(let map)? = workspace.researchMapText(file).map({ ResearchMap.parse($0) }), let target = map.node(node) else {
            return "That node no longer exists."
        }
        launchMapRun(file: file, root: root, kind: kind, title: label + ": " + Self.title(target.title), mode: mode) { job, _ in
            job.update("Listing the repository")
            let scope = await Task.detached { ResearchScope.files(root: root, always: map.targets) }.value
            // The map as it is now, not as it was when the action was chosen.
            let current = workspace.researchMapText(file).flatMap { text -> ResearchMap? in
                if case .success(let m) = ResearchMap.parse(text) { return m }
                return nil
            } ?? map
            let text = prompt(current, current.node(node) ?? target, ResearchPrompt.scopeText(scope))
            return MapTask(prompt: text, web: Self.web(root), noProjectFiles: scope.isEmpty)
        }
        return nil
    }

    /// Continues a map whose research stopped early.
    func continueMap(file: URL) -> String? {
        guard let workspace, let root = workspace.rootNode?.url else { return "No project is open." }
        if isRunning(on: file) { return "An AI job is already working on this map." }
        guard case .success(let map)? = workspace.researchMapText(file).map({ ResearchMap.parse($0) }) else {
            return "This file is not a readable research map."
        }
        workspace.updateResearchMap(file) { $0.markResearching() }
        launchMapRun(file: file, root: root, kind: .mapContinue, title: "Continue: " + Self.title(map.title), mode: .continuation) { job, _ in
            job.update("Listing the repository")
            let scope = await Task.detached { ResearchScope.files(root: root, always: map.targets + map.attachments) }.value
            let limits = ResearchMapRun.limits(for: .continuation)
            let current = workspace.researchMapText(file).flatMap { text -> ResearchMap? in
                if case .success(let m) = ResearchMap.parse(text) { return m }
                return nil
            } ?? map
            let prompt = ResearchMapPrompt.continuation(map: current, question: current.question, scope: ResearchPrompt.scopeText(scope), limits: limits)
            return MapTask(prompt: prompt, web: Self.web(root), noProjectFiles: scope.isEmpty)
        }
        return nil
    }

    /// Stops the jobs working on `file`; what they produced so far stays in the map.
    func cancelJobs(on file: URL) {
        for job in jobs where job.file.standardizedFileURL == file.standardizedFileURL { cancel(job.id) }
    }

    /// The running job of `file`, for the map view.
    func mapJobInfo(for file: URL) -> ResearchMap.JobInfo? {
        guard let job = jobs.first(where: { $0.file.standardizedFileURL == file.standardizedFileURL }) else { return nil }
        let kind: String
        switch job.kind {
        case .map, .research: kind = "research"
        case .mapDevelop: kind = "develop"
        case .mapContinue: kind = "continue"
        case .mapDescribe: kind = "describe"
        case .mapCorrect: kind = "correct"
        case .mapInvestigate: kind = "investigate"
        case .mapDraw: kind = "draw"
        case .mapTranslate: kind = "translate"
        case .mapReport: kind = "report"
        case .followUp, .comment: kind = "other"
        }
        return ResearchMap.JobInfo(kind: kind, label: job.title, step: job.step, startedAt: job.started.timeIntervalSince1970)
    }

    // MARK: - Running

    /// What a map job needs to run once it has listed its inputs.
    struct MapTask {
        var prompt: String
        var web: (allowed: Bool, unavailable: String?, note: String?)
        var noProjectFiles: Bool
    }

    /// Adds a job to the bar; `prepare` builds the prompt (it may take a while for big folders);
    /// the agent's node lines are applied to the map while it works, in batches.
    private func launchMapRun(file: URL, root: URL, kind: Job.Kind, title: String, mode: ResearchMapRun.Mode,
                              prepare: @escaping (JobHandle, MapRunDriver) async -> MapTask) {
        launch(kind: kind, file: file, title: title) { [weak self] job in
            guard let self, let workspace = self.workspace else { return nil }
            let driver = MapRunDriver(file: file, root: root, mode: mode, workspace: workspace)
            let task = await prepare(job, driver)
            let single = mode.singleNode != nil
            let system = ResearchMapPrompt.system(web: task.web.allowed, webRules: ResearchPrompt.webRules, languageLine: ResearchPrompt.languageLine, singleNode: single)
            let stream = driver.stream
            let outcome = await job.run(prompt: task.prompt, root: root, web: task.web.allowed, system: system, writing: single ? "Updating the node" : "Building the map",
                                        onText: { stream.feed($0) }, onQuery: { stream.query($0) })
            let summary = driver.finish(outcome: outcome)
            let reason = Self.incompleteReason(outcome, web: task.web)
                ?? (summary.lost > 0 ? "the map file could not be read, so \(summary.lost) nodes were not saved" : nil)
                ?? (mode.isResearch && summary.added == 0 ? "the assistant wrote no map nodes" : nil)
            let final = workspace.updateResearchMap(file) { map in
                if let note = task.web.note ?? task.web.unavailable.map({ "Web search was unavailable (\($0))." }), mode.isResearch,
                   !(map.root?.evidence.contains { $0.text == note } ?? true) {
                    map.nodes[0].evidence.append(ResearchMap.Evidence(label: .openAssumption, text: note, source: ""))
                }
                if task.noProjectFiles, mode.isResearch, map.root?.description.isEmpty == false {
                    map.nodes[0].evidence.append(ResearchMap.Evidence(label: .openAssumption, text: "The repository had no eligible files; the map rests on external sources and inference.", source: ""))
                }
                switch mode {
                case .research, .continuation:
                    if let reason { map.markIncomplete(reason) } else { map.markComplete() }
                case .develop, .describe, .correct, .investigate:
                    break
                }
            }
            // The map could not take its last update (the Markdown source holds text that is not a map, or the disk
            // refused the write): say so. The status is settled the next time the map is shown.
            switch final {
            case .rejected(let problem), .unreadable(let problem):
                return "The research map could not be updated at the end of the run: \(problem)"
            case .done:
                break
            }
            if case .develop = mode {
                if let reason = reason ?? outcome.failure {
                    return "Developing the branch stopped: \(reason). The nodes received are kept."
                }
                if summary.added == 0 { return "The assistant added no nodes to this branch." }
                return nil
            }
            if mode.singleNode != nil {
                if let reason = reason ?? outcome.failure { return "The action stopped: \(reason). The node is unchanged." }
                if summary.updated == 0 { return "The assistant changed nothing on this node." }
                return nil
            }
            return reason.map { "Research saved as incomplete: \($0)" }
        }
    }
}

extension ResearchMapRun.Mode {
    var isResearch: Bool { self == .research }
}

/// Applies a run's node lines to the map file on the main actor, at most every 0.4 s, in the order
/// the agent wrote them. The CLI's callbacks arrive on background threads: `ResearchMapStream` parses
/// them under a lock and this driver applies what is ready. A batch the file could not take (the tab
/// holds text that is not a map while the person edits the Markdown) waits for the next flush.
@MainActor
final class MapRunDriver {
    let file: URL
    let stream: ResearchMapStream
    private let root: URL
    private var applier: ResearchMapRun
    private weak var workspace: WorkspaceManager?
    private var scheduled = false
    private var sentQueries: [String] = []
    private var pendingEvents: [ResearchMapRun.Event] = []
    private var pendingQueries: [String] = []
    private(set) var added = 0
    private(set) var updated = 0

    init(file: URL, root: URL, mode: ResearchMapRun.Mode, workspace: WorkspaceManager) {
        self.file = file
        self.root = root
        self.workspace = workspace
        self.applier = ResearchMapRun(mode: mode)
        self.stream = ResearchMapStream(mode: mode)
        stream.onReady = { [weak self] in
            Task { @MainActor in self?.poke() }
        }
    }

    private func poke() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.scheduled = false
            self?.flush(final: false)
        }
    }

    private func flush(final: Bool) {
        let batch = final ? stream.finish() : stream.take()
        pendingEvents += batch.events
        for query in batch.queries where !pendingQueries.contains(query) { pendingQueries.append(query) }
        guard !pendingEvents.isEmpty || !pendingQueries.isEmpty, let workspace else { return }
        let exists = ResearchJobs.existsIn(root)
        let events = pendingEvents
        let queries = pendingQueries
        // The applier's references and counters advance only when the file took the batch.
        var attempt = applier
        var createdCount = 0
        let result = workspace.updateResearchMap(file) { map in
            createdCount = attempt.apply(events, to: &map, pathExists: exists).count
            map.addWebQueries(queries)
        }
        guard case .done = result else { return }
        applier = attempt
        updated = applier.updated
        added += createdCount
        pendingEvents = []
        pendingQueries = []
        for query in queries where !sentQueries.contains(query) { sentQueries.append(query) }
    }

    /// Applies the rest of the stream. Web queries the CLI refused leave the map's history. `lost` is the
    /// number of node lines the file never took.
    func finish(outcome: JobOutcome) -> (added: Int, updated: Int, lost: Int) {
        flush(final: true)
        let kept = Set(outcome.queries)
        let dropped = sentQueries.filter { !kept.contains($0) }
        if !dropped.isEmpty, let workspace {
            workspace.updateResearchMap(file) { map in map.webQueries.removeAll { dropped.contains($0) } }
        }
        return (added, updated, pendingEvents.count)
    }
}

/// The thread-safe half of a map run: parses the agent's text into node events and collects them
/// until the driver takes them.
final class ResearchMapStream: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: ResearchMapRun
    private var events: [ResearchMapRun.Event] = []
    private var queries: [String] = []
    private var notified = false
    var onReady: (() -> Void)?

    init(mode: ResearchMapRun.Mode) {
        parser = ResearchMapRun(mode: mode)
    }

    func feed(_ text: String) {
        lock.lock()
        let ready = parser.feed(text)
        events += ready
        let notify = !ready.isEmpty && !notified
        if notify { notified = true }
        lock.unlock()
        if notify { onReady?() }
    }

    func query(_ query: String) {
        lock.lock()
        if !queries.contains(query) { queries.append(query) }
        let notify = !notified
        if notify { notified = true }
        lock.unlock()
        if notify { onReady?() }
    }

    func take() -> (events: [ResearchMapRun.Event], queries: [String]) {
        lock.lock(); defer { lock.unlock() }
        notified = false
        let batch = (events, queries)
        events = []
        queries = []
        return batch
    }

    /// Everything left, including a last line the stream did not end with a newline.
    func finish() -> (events: [ResearchMapRun.Event], queries: [String]) {
        lock.lock(); defer { lock.unlock() }
        events += parser.finish()
        notified = false
        let batch = (events, queries)
        events = []
        queries = []
        return batch
    }

    var malformedLines: Int {
        lock.lock(); defer { lock.unlock() }
        return parser.malformedLines
    }
}
