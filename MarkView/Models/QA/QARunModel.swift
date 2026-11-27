import AppKit
import SwiftUI
import MarkViewCore

// End-to-End QA (feature end-to-end-qa, REQ-003, REQ-008, REQ-009): the state of a run on screen. It starts the runner, shows what each
// player's page looks like, keeps the feed of what is happening and what the review finds, asks the person for the yes that production
// needs, records the video of each branch with its subtitles, and saves the run when it ends. Branches that run side by side each have
// their players' pictures and their recording; their results, reviews and findings follow the order of the plan. The run itself
// (QARunner) knows nothing of this; it only tells what happens.

/// Carries the runner's events, in order, from whatever thread it runs on to the model.
private final class QAEventSink: QARunObserver {
    let continuation: AsyncStream<QARunEvent>.Continuation
    init(_ continuation: AsyncStream<QARunEvent>.Continuation) { self.continuation = continuation }
    func handle(_ event: QARunEvent) { continuation.yield(event) }
}

@MainActor
final class QARunModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case finished
    }

    /// How closely the screens are reviewed (DEC-021): not at all, once for the last screen of each step, or for every new screen.
    enum ReviewDepth: String, CaseIterable {
        case off
        case steps
        case screens

        var title: String {
            switch self {
            case .off: return "Not at all"
            case .steps: return "After each step"
            case .screens: return "Every new screen"
            }
        }
    }

    /// The page of one player of one branch in progress (`tile`).
    struct Player: Identifiable {
        let id: String
        let branch: String
        /// The player's id, or `setupPlayer` for the session that prepares data.
        let actor: String
        var name: String
        var address = ""
        var title = ""
        var picture: NSImage?
    }

    struct FeedItem: Identifiable {
        let id: Int
        /// Seconds from the start of the run.
        let time: Double
        let kind: QATimelineEntry.Kind
        let actor: String?
        let node: String?
        let text: String
        let picture: NSImage?
        /// The screen the picture is a thumbnail of, as the page was (PNG), and its number in the run (a finding's own screen has a negative one):
        /// the viewer shows it at full size.
        var screenshot: Data? = nil
        var screen = 0
        var finding: QAFinding? = nil
    }

    private struct ReviewJob {
        var event: QAScreenEvent
        /// True for the screen a step ended on; false for a screen shown while the step was still being carried out.
        var endOfStep: Bool
        /// Seconds from the start of the run at which the screen was shown: where it is in the recording, whenever the review ends.
        var shownAt: Double
    }

    private struct PendingScreen {
        var event: QAScreenEvent
        var shownAt: Double
    }

    /// The recording of one branch in progress: the latest picture of each of its players and the subtitle that is current.
    private struct Recording {
        var writer: QAVideoWriter
        /// The players shown side by side in its frames.
        var slots: [String]
        var start: Date
        var pictures: [String: CGImage] = [:]
        var subtitle: String?
    }

    static let setupPlayer = "setup"
    /// A run reviews at most this many screens, whatever their number, so its cost stays bounded.
    static let maxReviews = 40

    @Published private(set) var isPaused = false
    @Published private(set) var pauseRequested = false
    private var control: QARunControl?
    private var sessions = QARunSessions()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var players: [Player] = []
    @Published private(set) var feed: [FeedItem] = []
    /// In the order of the plan, whichever branch ended first.
    @Published private(set) var results: [QACheckResult] = []
    @Published private(set) var findings: [QAFinding] = []
    /// The branches in progress, in the order of the plan, and the step each is at.
    @Published private(set) var running: [String] = []
    @Published private(set) var runningNodes: [String: String] = [:]
    @Published private(set) var record: QARunRecord?
    /// The label of every branch of the run, and how many there are.
    @Published private(set) var labels: [String: String] = [:]
    @Published private(set) var branchCount = 0
    /// The recording of each branch, once it is written.
    @Published private(set) var videos: [String: URL] = [:]
    /// What the run waits for the person to say yes or no to.
    @Published private(set) var question: QAConfirmation?
    @Published private(set) var notice: String?
    /// The bug reports this run filed or found filed already, in the order of its checks and findings; final once the run has finished.
    @Published private(set) var filedBugIDs: [String] = []
    @Published private(set) var costUSD: Double?
    /// Screens waiting for, or in, the review.
    @Published private(set) var reviewing = 0
    /// The live view is hidden after "Back to the scenario" and comes back with "Show the run".
    @Published private(set) var dismissed = false
    /// The video is on unless the person turns it off before a run (REQ-009).
    @Published var recordVideo: Bool { didSet { Settings.standard.set(recordVideo, for: Setting.qaRecordVideo) } }
    @Published var reviewDepth: ReviewDepth { didSet { Settings.standard.set(reviewDepth.rawValue, for: Setting.qaReviewDepth) } }

    private(set) var scenario: QAScenario?
    private var plan: QAExecutionPlan?
    private var root: URL?
    private var runID = ""
    private var runStart = Date()
    private var runTask: Task<Void, Never>?
    private var consumer: Task<Void, Never>?
    private var reviewer: Task<Void, Never>?
    /// The deletion of the older runs the retention rule gives up, started with a run; a newer run's replaces it, and the model going away ends it.
    private var pruning: Task<Void, Never>?
    private var sink: QAEventSink?
    private var assistant: QACLIAssistant?
    private var selectedAssistant: CLICompletion.Assistant?
#if MARKVIEW_HOSTED_TEST_HOST
    /// The isolated app host uses local fixtures for the runner instead of a real browser or assistant.
    var testDriverFactory: (any QADriverFactory)?
    var testRunnerAssistant: (any QAAssistant)?
#endif
    private var answer: CheckedContinuation<Bool, Never>?
    private var nextFeedID = 1
    private var reviewCost = 0.0
    /// True when the run lets its branches run side by side: a player's tile and every line of the feed then name their branch.
    private var sideBySide = false
    private var pausedBranches: Set<String> = []
    /// True once the window has gone to another project during the run: the window's filer now files into that project, so the
    /// run's bugs are not filed (`releaseSessions`).
    private var projectLeft = false

    /// Where the bugs of a run are filed (REQ-007). Set by the window that owns the project's bug reports; without it nothing is filed.
    var bugFiler: QABugFiler?
    /// The runs that results outside QA link to; set by the window that owns them. Without it no run is pruned.
    var runLinks: (any QARunLinks)?

    // The review of the screens. Each branch has its queue, and the queues are reviewed one after another in the order of the plan,
    // so that every review is told the findings before it and the findings are numbered the same way whichever branch ends first.
    private var reviewQueues: [String: AsyncStream<ReviewJob>.Continuation] = [:]
    /// The screens each branch has queued for the review, by signature: a branch never queues one screen twice or more than a run reviews.
    private var queued: [String: Set<String>] = [:]
    /// The screens reviewed in the run, by signature: a screen two branches show is reviewed once, in the earlier branch of the plan.
    private var reviewed: Set<String> = []
    /// The newest new screen of each step in progress, by `tile(branch, node)`. It is reviewed once the next one appears (then it was
    /// shown mid-step) or the step ends (then it is the screen the step ended on), so the review is told which it is.
    private var pendingScreen: [String: PendingScreen] = [:]
    private var reviewsMade = 0

    // The pictures of the branches in progress, by branch and then player (`setupPlayer` for the preparation).
    private var recordings: [String: Recording] = [:]
    /// The same screens as taken (PNG) and their numbers in the run, for the viewer.
    private var screenshots: [String: [String: Data]] = [:]
    private var screenNumbers: [String: [String: Int]] = [:]
    private var screenCount = 0
    private var thumbnails: [String: [String: NSImage]] = [:]
    private var videoTasks: [Task<Void, Never>] = []
    /// When the recording of each branch began, in seconds from the start of the run: a finding's time is counted from the run's start.
    private var videoStarts: [String: Double] = [:]

    var isRunning: Bool { phase == .running }
    var activeRunID: String? { isRunning ? runID : nil }
    /// The branch in progress when only one is: "Continue from step" picks a step of it, and Cockpit names it.
    var currentBranch: String? { running.count == 1 ? running.first : nil }
    var currentNode: String? { currentBranch.flatMap { runningNodes[$0] } }

    init() {
        recordVideo = Settings.standard.value(Setting.qaRecordVideo)
        reviewDepth = ReviewDepth(rawValue: Settings.standard.value(Setting.qaReviewDepth)) ?? .screens
    }

    deinit {
        runTask?.cancel()
        pruning?.cancel()
        control?.stop()
        let retained = sessions
        // task: the browser sessions close after the run is gone; cancelling it would leave them open
        Task { await retained.close() }
    }

    func dismiss() { dismissed = true }
    func show() { dismissed = false }

    // MARK: The person's marks on the findings (REQ-015)

    private var triageTail: Task<Void, Never>?

    /// Marks a finding once the run has ended (the bug reports are filed then); one mark after another, so that none is lost.
    func mark(_ id: String, _ state: QATriageState?, note: String = "") {
        guard phase == .finished else { return }
        let previous = triageTail
        triageTail = Task { [weak self] in
            await previous?.value
            await self?.applyMark(id, state, note: note)
        }
    }

    private func applyMark(_ id: String, _ state: QATriageState?, note: String) async {
        guard let record, let root, let outcome = await QATriageService.apply(record, root: root, finding: id, state: state, note: note, filer: bugFiler) else { return }
        self.record = outcome.record
        findings = outcome.record.findings
        notice = outcome.notice
    }

    // MARK: Start and stop

    func start(scenario: QAScenario, plan: QAExecutionPlan, gate: QAGate, root: URL, assistant selected: CLICompletion.Assistant? = nil, from startPoint: QAStartPoint? = nil) {
        guard phase != .running, gate.canPrepare else { return }
        let reuse = startPoint != nil && self.root == root && self.scenario?.id == scenario.id && self.plan?.target == plan.target
            && self.scenario?.actors == scenario.actors && self.scenario?.appKind == scenario.appKind
        let oldSessions = reuse ? nil : sessions
        if !reuse { sessions = QARunSessions() }
        let control = QARunControl()
        self.control = control
        reset()
        self.scenario = scenario
        self.plan = plan
        self.root = root
        phase = .running
        dismissed = false
        runStart = Date()
        labels = scenario.displayLabels(for: plan.branches)
        branchCount = plan.branches.count
        sideBySide = plan.branches.count > 1 && QARunner.branchLimit(scenario: scenario, branches: plan.branches) > 1
        QAStore.prepareLocalFolder(root)

        let runID = QAStore.newRunID(at: Date())
        self.runID = runID
        // The older runs of this scenario that the retention rule gives up are deleted in the background (Q-010); the new run is never one.
        pruning?.cancel()
        pruning = Task.detached(priority: .utility) { [filer = self.bugFiler, links = self.runLinks, scenarioID = scenario.id] in
            await QARunCleanup.prune(root: root, scenarioID: scenarioID, runInProgress: runID, filer: filer, links: links)
        }
        let (events, continuation) = AsyncStream.makeStream(of: QARunEvent.self)
        let sink = QAEventSink(continuation)
        selectedAssistant = selected ?? .project(root)
        let assistant = QACLIAssistant(project: root, assistant: selectedAssistant)
        self.sink = sink
        self.assistant = assistant
        let factory: any QADriverFactory
        switch scenario.appKind {
        case .web: factory = QAWebDriverFactory()
        case .api: factory = QAAPIDriverFactory()
        case .nativeMacOS: factory = QANativeDriverFactory()
        }
#if MARKVIEW_HOSTED_TEST_HOST
        let runnerFactory = testDriverFactory ?? factory
        let runnerAssistant: any QAAssistant = testRunnerAssistant ?? assistant
#else
        let runnerFactory = factory
        let runnerAssistant: any QAAssistant = assistant
#endif
        var config = QARunner.Config()
        config.captureInputs = recordVideo
        config.keepSessions = true
        config.startPoint = startPoint
        let runner = QARunner(scenario: scenario, plan: plan, gate: gate, factory: runnerFactory, assistant: runnerAssistant, runID: runID,
                              confirm: { [weak self] confirmation in await self?.ask(confirmation) ?? false }, observer: sink, config: config, control: control, sessions: sessions)

        var queues: [AsyncStream<ReviewJob>] = []
        for branch in plan.branches {
            let (queue, continuation) = AsyncStream.makeStream(of: ReviewJob.self)
            queues.append(queue)
            reviewQueues[branch.id] = continuation
        }
        reviewer = Task { [weak self] in
            // A queue ends when its branch has ended; a later branch's screens wait until then.
            for queue in queues {
                for await job in queue {
                    guard let self else { return }
                    await self.review(job)
                }
            }
        }
        consumer = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        runTask = Task { [weak self] in
            await oldSessions?.close()
            _ = await runner.run()
            continuation.finish()
            await self?.consumer?.value
            self?.finishReviewQueues()
            await self?.reviewer?.value
            // Stop cancels this task to end the checks in progress, but what the run found is still saved and its bugs filed
            // (BUG-133): the finish runs detached from this task, so that cancellation does not reach it.
            await Task.detached { [weak self] in await self?.finishRun() }.value
        }
    }

    /// Stops the run: the branches in progress are interrupted and the ones not started stay uncovered.
    func stop() {
        control?.stop()
        runTask?.cancel()
        reviewer?.cancel()
        reply(false)
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        pauseRequested = true
        control?.pause()
    }

    func resume(at node: String? = nil) {
        guard isRunning else { return }
        if let node, !(scenario?.enumerateBranches().branches.first { $0.id == currentBranch }?.nodes.contains(node) ?? false) { return }
        pauseRequested = false
        control?.resume(at: node)
    }

    var restartBranches: [QABranch] { plan?.branches ?? [] }

    var continuationSteps: [QANode] {
        guard let scenario, let branch = scenario.enumerateBranches().branches.first(where: { $0.id == currentBranch }) else { return [] }
        return branch.nodes.compactMap { scenario.node($0) }
    }

    /// Called on project changes; wait for the active runner before closing its players. A run in progress is stopped and files
    /// no bugs: they belong to its project, not to the one the window opens.
    func releaseSessions() {
        if isRunning { projectLeft = true }
        stop()
        let task = runTask, old = sessions
        sessions = QARunSessions()
        // task: the old sessions close once the run has ended; cancelling it would leave them open
        Task { await task?.value; await old.close() }
    }

    func reply(_ yes: Bool) {
        question = nil
        answer?.resume(returning: yes)
        answer = nil
    }

    private func ask(_ confirmation: QAConfirmation) async -> Bool {
        if Task.isCancelled { return false }
        return await withCheckedContinuation { continuation in
            question = confirmation
            answer = continuation
        }
    }

    private func reset() {
        isPaused = false
        pauseRequested = false
        feed = []
        screenshots = [:]
        screenNumbers = [:]
        screenCount = 0
        results = []
        findings = []
        videos = [:]
        record = nil
        notice = nil
        filedBugIDs = []
        projectLeft = false
        costUSD = nil
        question = nil
        players = []
        running = []
        runningNodes = [:]
        pausedBranches = []
        recordings = [:]
        thumbnails = [:]
        reviewing = 0
        reviewQueues = [:]
        queued = [:]
        reviewed = []
        videoTasks = []
        videoStarts = [:]
        pendingScreen = [:]
        reviewsMade = 0
        reviewCost = 0
        nextFeedID = 1
    }

    // MARK: Events

    func handle(_ event: QARunEvent) {
        switch event {
        case .runStarted:
            break
        case .branchStarted(let branch, _):
            running.insert(branch, at: running.firstIndex { planIndex($0) > planIndex(branch) } ?? running.endIndex)
            runningNodes[branch] = nil
            showPlayers(of: branch)
            startVideo(branch)
        case .narration(let entry):
            recordings[entry.branch]?.subtitle = entry.text
            let key = entry.actor ?? Self.setupPlayer
            addFeed(entry.branch, time: entry.time, kind: entry.kind, actor: entry.actor, node: entry.node, text: entry.text, picture: thumbnails[entry.branch]?[key],
                    screenshot: screenshots[entry.branch]?[key], screen: screenNumbers[entry.branch]?[key] ?? 0)
            addFrame(entry.branch)
        case .paused(let branch, let paused):
            if paused { pausedBranches.insert(branch) } else { pausedBranches.remove(branch) }
            isPaused = !pausedBranches.isEmpty
            pauseRequested = false
            recordings[branch]?.subtitle = paused ? "Execution paused" : "Execution resumed"
            addFrame(branch)
        case .screen(let screen):
            show(screen)
        case .input(let branch, let actor, let mark, let png):
            let key = actor ?? Self.setupPlayer
            var shown = recordings[branch]?.pictures ?? [:]
            if let png, let image = QAFrameComposer.image(from: png) { shown[key] = image }
            addFrame(branch, input: (key, mark), pictures: shown)
        case .nodeStarted(let branch, let node, _, _):
            runningNodes[branch] = node
            players.removeAll { $0.id == Self.tile(branch, nil) }
        case .nodeFinished(let branch, let node, let effort):
            if reviewDepth != .off, var last = pendingScreen.removeValue(forKey: Self.tile(branch, node)) {
                last.event.stepEffort = effort
                enqueue(last.event, shownAt: last.shownAt, endOfStep: true)
            }
        case .branchFinished(let result):
            let branch = result.branch
            results.insert(result, at: results.firstIndex { planIndex($0.branch) > planIndex(branch) } ?? results.endIndex)
            running.removeAll { $0 == branch }
            runningNodes[branch] = nil
            pausedBranches.remove(branch)
            isPaused = !pausedBranches.isEmpty
            pendingScreen = pendingScreen.filter { $0.value.event.branch != branch }
            finishVideo(branch)
            reviewQueues[branch]?.finish()
        case .runFinished(let finished):
            record = finished
        }
    }

    /// The id of a player's tile: each branch in progress shows its own players, and the session that prepares data is nobody's.
    static func tile(_ branch: String, _ actor: String?) -> String { "\(branch)|\(actor ?? setupPlayer)" }

    /// Where a branch is in the plan; a branch the plan does not have comes last.
    private func planIndex(_ branch: String) -> Int { plan?.branches.firstIndex { $0.id == branch } ?? Int.max }

    /// A branch that starts takes the place of the branches that have ended: their tiles and pictures go, its players' tiles come.
    private func showPlayers(of branch: String) {
        players.removeAll { !running.contains($0.branch) }
        screenshots = screenshots.filter { running.contains($0.key) }
        thumbnails = thumbnails.filter { running.contains($0.key) }
        guard let scenario, let found = plan?.branches.first(where: { $0.id == branch }) else { return }
        for actor in scenario.actors(in: found) {
            let name = scenario.actors.first { $0.id == actor }?.name ?? actor
            players.append(Player(id: Self.tile(branch, actor), branch: branch, actor: actor, name: playerName(name, branch)))
        }
    }

    private func playerName(_ name: String, _ branch: String) -> String {
        guard let label = branchLabel(branch) else { return name }
        return "\(name) · \(label)"
    }

    /// The label that tells a branch's tiles and feed lines from the other branches' when they run side by side; nil when one runs at a
    /// time, whose tiles and lines need none.
    private func branchLabel(_ branch: String) -> String? {
        guard sideBySide else { return nil }
        return labels[branch] ?? branch
    }

    private func show(_ screen: QAScreenEvent) {
        let branch = screen.branch
        let key = screen.actor ?? Self.setupPlayer
        let id = Self.tile(branch, screen.actor)
        if screen.actor == nil, !players.contains(where: { $0.id == id }) {
            let first = players.firstIndex { $0.branch == branch } ?? players.endIndex
            players.insert(Player(id: id, branch: branch, actor: key, name: playerName("Preparation", branch)), at: first)
        }
        guard let index = players.firstIndex(where: { $0.id == id }) else { return }
        players[index].address = screen.observation.address
        players[index].title = screen.observation.title
        guard let png = screen.png, let full = QAFrameComposer.image(from: png) else { return }
        recordings[branch]?.pictures[key] = full
        screenshots[branch, default: [:]][key] = png
        screenCount += 1
        screenNumbers[branch, default: [:]][key] = screenCount
        let thumbnail = QAFrameComposer.thumbnail(from: png)
        thumbnails[branch, default: [:]][key] = thumbnail
        players[index].picture = thumbnail
        addFrame(branch)
        guard screen.isNew, let node = screen.node, reviewDepth != .off else { return }
        let shown = PendingScreen(event: screen, shownAt: max(0, Date().timeIntervalSince(runStart)))
        if let earlier = pendingScreen.updateValue(shown, forKey: Self.tile(branch, node)), reviewDepth == .screens {
            enqueue(earlier.event, shownAt: earlier.shownAt, endOfStep: false)
        }
    }

    /// A line of the feed. The lines of branches running side by side interleave, so each begins with its branch's label, the one its
    /// players' tiles carry, to be read in turn and matched to the branch's video.
    private func addFeed(_ branch: String, time: Double, kind: QATimelineEntry.Kind, actor: String?, node: String?, text: String, picture: NSImage?,
                         screenshot: Data? = nil, screen: Int = 0, finding: QAFinding? = nil) {
        let line = branchLabel(branch).map { "\($0) · \(text)" } ?? text
        feed.append(FeedItem(id: nextFeedID, time: time, kind: kind, actor: actor, node: node, text: line, picture: picture, screenshot: screenshot, screen: screen, finding: finding))
        nextFeedID += 1
    }

    /// The newest screenshot of a player's tile as it was taken, for the viewer; nil before the first one and once the tile is gone.
    func screenshot(ofPlayer id: String) -> Data? {
        guard let player = players.first(where: { $0.id == id }) else { return nil }
        return screenshots[player.branch]?[player.actor]
    }

    private func finishRun() async {
        // The last recording is still being closed when the run ends; the bug reports name it.
        for task in videoTasks { await task.value }
        videoTasks = []
        let total = (assistant?.costUSD ?? 0) + reviewCost
        costUSD = total > 0 ? total : nil
        // The run file is written before the run counts as finished, so the list of runs and the marks on the findings find it.
        if var finished = record, let root {
            finished.findings = findings
            record = finished
            let saved = finished
            do { try await Task.detached(priority: .utility) { try QAStore.saveRun(saved, root: root) }.value } catch { notice = "The run could not be saved: \(error.localizedDescription)" }
        }
        if let record, let root { await fileBugs(record, root: root) }
        phase = .finished
        isPaused = false
        pauseRequested = false
        running = []
        runningNodes = [:]
    }

    // MARK: The bugs of the run (REQ-007)

    /// Files a bug for every check that failed, was blocked or was interrupted, and for every defect the review found. What is filed already
    /// (the same run and branch or finding) is not filed again; the outcome of each is told in the notice.
    private func fileBugs(_ record: QARunRecord, root: URL) async {
        guard let filer = bugFiler, let scenario else { return }
        let base = root.standardizedFileURL.path + "/"
        var recordings: [String: QABugVideo] = [:]
        for (branch, url) in videos {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            recordings[branch] = QABugVideo(path: String(path.dropFirst(base.count)), startsAt: videoStarts[branch] ?? 0)
        }
        let candidates = QABugDrafts.drafts(run: record, scenario: scenario, findings: record.findings, videos: recordings,
                                            runFolder: QAStore.runFolder(root, runID: runID), now: Date())
        guard !candidates.isEmpty else { return }
        guard !projectLeft else {
            let count = candidates.count == 1 ? "Its bug was" : "Its \(candidates.count) bugs were"
            notice = ([notice, "\(count) not filed: the window opened another project during the run."]).compactMap { $0 }.joined(separator: " ")
            return
        }
        let results = await filer.file(candidates)
        var created: [String] = [], already = 0, failures: [String] = [], ids: [String] = []
        for result in results {
            switch result.status {
            case .created(let id): created.append(id); ids.append(id)
            case .alreadyFiled(let id): already += 1; ids.append(id)
            case .failed(let message): failures.append(message)
            }
        }
        filedBugIDs = ids.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var parts: [String] = []
        if !created.isEmpty { parts.append("Filed \(created.count == 1 ? "bug" : "bugs"): " + created.joined(separator: ", ") + ".") }
        if already > 0 { parts.append("\(already) already filed.") }
        if let first = failures.first { parts.append("\(failures.count) could not be filed: \(first)") }
        notice = ([notice] + parts.map { Optional($0) }).compactMap { $0 }.joined(separator: " ")
    }

    // MARK: The report of a branch

    /// What the branch cost a person, and the steps that cost the most.
    func effortSummary(_ result: QACheckResult) -> String {
        if scenario?.appKind == .api {
            return "\(result.steps.count) API steps · \(result.effort.milliseconds) ms"
        }
        let steps = result.steps.compactMap { step -> (title: String, effort: QAEffort)? in
            scenario?.node(step.node).map { (title: $0.title, effort: step.effort) }
        }
        var text = QAReview.branchSummary(effort: result.effort, costliest: steps)
        if result.effort.screens > 0 { text += " \(result.effort.screens) \(result.effort.screens == 1 ? "screen" : "screens")." }
        return text
    }

    // MARK: The review of the screens (REQ-008)

    private func enqueue(_ screen: QAScreenEvent, shownAt: Double, endOfStep: Bool) {
        guard screen.png != nil, let queue = reviewQueues[screen.branch], queued[screen.branch, default: []].count < Self.maxReviews else { return }
        let signature = QAScreen.signature(address: screen.observation.address, snapshot: screen.observation.snapshot)
        guard queued[screen.branch, default: []].insert(signature).inserted else { return }
        reviewing += 1
        queue.yield(ReviewJob(event: screen, endOfStep: endOfStep, shownAt: shownAt))
    }

    private func finishReviewQueues() {
        for queue in reviewQueues.values { queue.finish() }
    }

    private func review(_ job: ReviewJob) async {
        defer { reviewing -= 1 }
        let screen = job.event
        // The cap and the screens shown before are counted here, in the order of the plan, so the run reviews the same screens and
        // numbers their frames the same way whichever branch ended first.
        let signature = QAScreen.signature(address: screen.observation.address, snapshot: screen.observation.snapshot)
        guard reviewsMade < Self.maxReviews, reviewed.insert(signature).inserted else { return }
        reviewsMade += 1
        let number = reviewsMade
        guard !Task.isCancelled, let scenario, let root, let png = screen.png else { return }
        guard let node = screen.node.flatMap({ scenario.node($0) }), let app = scenario.app(scenario.appID(of: node) ?? "") else { return }
        let actorName = screen.actor.flatMap { id in scenario.actors.first { $0.id == id }?.name } ?? "the user"
        let input = QAReviewInput(app: app, node: node, actorName: actorName, screenAddress: screen.observation.address, screenTitle: screen.observation.title,
                                  snapshot: screen.observation.snapshot, effort: screen.stepEffort, branchEffort: screen.branchEffort, evidence: screen.evidence,
                                  alreadyReported: findings.map(\.title), endOfStep: job.endOfStep, language: QALanguage.name(of: scenario))
        let folder = QAStore.runFolder(root, runID: runID)
        let relative = "frames/\(number).png"
        let file = folder.appendingPathComponent(relative)
        let written = await Task.detached(priority: .utility) { () -> Bool in
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AtomicFile.write(png, to: file)
                return true
            } catch { return false }
        }.value
        guard written, !Task.isCancelled else { return }

        var request = CLICompletion.Request(project: root, prompt: QAReview.prompt(input) + "\n\nThe screenshot is the image file at \(file.path). Open it and look at it before you answer.",
                                            systemPrompt: QAReview.systemPrompt(), jsonSchema: QAReview.schema, readableFolder: folder, timeout: 150,
                                            assistantOverride: selectedAssistant, label: "qa-review")
        request.images = [file]
        request.effort = "low"
        do {
            let result = try await AIOperation<CLICompletion.Request, CLICompletion.Result>.ask(request, name: "qa-review")
            reviewCost += result.costUSD ?? 0
            var found = QAReview.parse(result.structured, input: input, firstFindingNumber: findings.count + 1)
            let picture = QAFrameComposer.thumbnail(from: png)
            let at = job.shownAt
            for index in found.indices {
                found[index].frame = relative
                found[index].time = at
                found[index].app = app.id
                found[index].branch = screen.branch
                findings.append(found[index])
                addFeed(screen.branch, time: at, kind: .observation, actor: screen.actor, node: screen.node, text: found[index].title, picture: picture, screenshot: png,
                        screen: -(findings.count), finding: found[index])
            }
        } catch is CancellationError {
            return
        } catch {
            notice = "A screen could not be reviewed: \(error.localizedDescription)"
        }
    }

    // MARK: The video (REQ-009)

    private func startVideo(_ branch: String) {
        guard recordVideo, let root, let scenario, scenario.appKind != .api, let plan, let index = plan.branches.firstIndex(where: { $0.id == branch }) else { return }
        var slots = scenario.actors(in: plan.branches[index])
        if slots.isEmpty { slots = [Self.setupPlayer] }
        let size = QAFrameComposer.pictureSize(players: slots.count)
        // Numbered by the branch's place in the plan, as the run's report looks for it (QARunArchive).
        let url = QAStore.runFolder(root, runID: runID).appendingPathComponent("branch-\(index + 1).mp4")
        let start = Date()
        do {
            recordings[branch] = Recording(writer: try QAVideoWriter(url: url, pictureSize: size), slots: slots, start: start)
            videoStarts[branch] = start.timeIntervalSince(runStart)
        } catch { notice = "The video could not be started: \(error.localizedDescription)" }
    }

    /// The latest pictures of a branch's players, side by side, with the subtitle that is current, at this second of the branch.
    private func addFrame(_ branch: String, input: (String, QAInputMark)? = nil, pictures source: [String: CGImage]? = nil) {
        guard let recording = recordings[branch] else { return }
        let slots = recording.slots
        let pictures = source ?? recording.pictures
        var shown = slots.map { pictures[$0] }
        // The session that prepares data is nobody's: it takes the first player's place until the steps begin.
        if let setup = pictures[Self.setupPlayer], !shown.isEmpty, shown[0] == nil { shown[0] = setup }
        var marks: [Int: QAInputMark] = [:]
        if let (key, mark) = input, let index = key == Self.setupPlayer ? (shown.isEmpty ? nil : 0) : slots.firstIndex(of: key) { marks[index] = mark }
        let names = slots.map(videoName)
        guard let composed = QAFrameComposer.compose(shown, marks: marks, names: names) else { return }
        do { try recording.writer.append(composed, at: max(0, Date().timeIntervalSince(recording.start)), subtitle: recording.subtitle,
                                         minimumDuration: input == nil ? 0 : 0.75) } catch {
            notice = "The video stopped: \(error.localizedDescription)"
            recordings[branch] = nil
        }
    }

    /// The name a player has in a branch's video, which is the branch's own: without the branch's name that its tile may carry.
    private func videoName(_ id: String) -> String {
        if id == Self.setupPlayer { return "Preparation" }
        return scenario?.actors.first { $0.id == id }?.name ?? id
    }

    private func finishVideo(_ branch: String) {
        guard let writer = recordings.removeValue(forKey: branch)?.writer else { return }
        let task = Task { [weak self] in
            do {
                let url = try await writer.finish()
                self?.videos[branch] = url
            } catch QAVideoError.noFrames {
                // Nothing was shown, so there is nothing to keep.
            } catch {
                self?.notice = "The video could not be finished: \(error.localizedDescription)"
            }
        }
        videoTasks.append(task)
    }
}
