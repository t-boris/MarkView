import AppKit
import SwiftUI

// End-to-End QA (feature end-to-end-qa, REQ-003, REQ-008, REQ-009): the state of a run on screen. It starts the runner, shows what each
// player's page looks like, keeps the feed of what is happening and what the review finds, asks the person for the yes that production
// needs, records the video with its subtitles, and saves the run when it ends. The run itself (QARunner) knows nothing of this; it only
// tells what happens.

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

    struct Player: Identifiable {
        let id: String
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
        var number: Int
        /// True for the screen a step ended on; false for a screen shown while the step was still being carried out.
        var endOfStep: Bool
        /// Seconds from the start of the run at which the screen was shown: where it is in the recording, whenever the review ends.
        var shownAt: Double
    }

    private struct PendingScreen {
        var event: QAScreenEvent
        var shownAt: Double
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
    @Published private(set) var results: [QACheckResult] = []
    @Published private(set) var findings: [QAFinding] = []
    @Published private(set) var currentBranch: String?
    @Published private(set) var currentNode: String?
    @Published private(set) var record: QARunRecord?
    /// The label of every branch of the run, and how many there are.
    @Published private(set) var labels: [String: String] = [:]
    @Published private(set) var branchCount = 0
    /// The recording of each branch, once it is written.
    @Published private(set) var videos: [String: URL] = [:]
    /// What the run waits for the person to say yes or no to.
    @Published private(set) var question: QAConfirmation?
    @Published private(set) var notice: String?
    @Published private(set) var costUSD: Double?
    /// Screens waiting for, or in, the review.
    @Published private(set) var reviewing = 0
    /// The live view is hidden after "Back to the scenario" and comes back with "Show the run".
    @Published private(set) var dismissed = false
    /// The video is on unless the person turns it off before a run (REQ-009).
    @Published var recordVideo: Bool { didSet { UserDefaults.standard.set(recordVideo, forKey: Self.videoKey) } }
    @Published var reviewDepth: ReviewDepth { didSet { UserDefaults.standard.set(reviewDepth.rawValue, forKey: Self.depthKey) } }

    private static let videoKey = "qaRecordVideo"
    private static let depthKey = "qaReviewDepth"

    private(set) var scenario: QAScenario?
    private var plan: QAExecutionPlan?
    private var root: URL?
    private var runID = ""
    private var runStart = Date()
    private var runTask: Task<Void, Never>?
    private var consumer: Task<Void, Never>?
    private var reviewer: Task<Void, Never>?
    private var sink: QAEventSink?
    private var assistant: QACLIAssistant?
    private var selectedAssistant: CLICompletion.Assistant?
    private var answer: CheckedContinuation<Bool, Never>?
    private var nextFeedID = 1
    private var reviewCost = 0.0

    /// Where the bugs of a run are filed (REQ-007). Set by the window that owns the project's bug reports; without it nothing is filed.
    var bugFiler: QABugFiler?

    // The review of the screens.
    private var jobs: AsyncStream<ReviewJob>.Continuation?
    private var reviewed: Set<String> = []
    /// The newest new screen of each step in progress. It is reviewed once the next one appears (then it was shown mid-step) or the step
    /// ends (then it is the screen the step ended on), so the review is told which it is.
    private var pendingScreen: [String: PendingScreen] = [:]
    private var reviewsMade = 0

    // The recording of the branch in progress.
    private var writer: QAVideoWriter?
    private var pictures: [String: CGImage] = [:]
    /// The same screens as taken (PNG) and their numbers in the run, for the viewer.
    private var screenshots: [String: Data] = [:]
    private var screenNumbers: [String: Int] = [:]
    private var screenCount = 0
    private var thumbnails: [String: NSImage] = [:]
    private var slots: [String] = []
    private var subtitle: String?
    private var branchStart = Date()
    private var branchIndex = 0
    private var videoTasks: [Task<Void, Never>] = []
    /// When the recording of each branch began, in seconds from the start of the run: a finding's time is counted from the run's start.
    private var videoStarts: [String: Double] = [:]

    var isRunning: Bool { phase == .running }
    var activeRunID: String? { isRunning ? runID : nil }

    init() {
        recordVideo = UserDefaults.standard.object(forKey: Self.videoKey) as? Bool ?? true
        reviewDepth = UserDefaults.standard.string(forKey: Self.depthKey).flatMap(ReviewDepth.init(rawValue:)) ?? .screens
    }

    deinit {
        runTask?.cancel()
        control?.stop()
        let retained = sessions
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
        players = scenario.actors.map { Player(id: $0.id, name: $0.name) }
        labels = scenario.displayLabels(for: plan.branches)
        branchCount = plan.branches.count
        QAStore.prepareLocalFolder(root)

        let runID = QAStore.newRunID(at: Date())
        self.runID = runID
        // The older runs of this scenario that the retention rule gives up are deleted in the background (Q-010); the new run is never one.
        Task.detached(priority: .utility) { [filer = self.bugFiler, scenarioID = scenario.id] in
            await QARunCleanup.prune(root: root, scenarioID: scenarioID, runInProgress: runID, filer: filer)
        }
        let (events, continuation) = AsyncStream.makeStream(of: QARunEvent.self)
        let sink = QAEventSink(continuation)
        selectedAssistant = selected ?? .project(root)
        let assistant = QACLIAssistant(project: root, assistant: selectedAssistant)
        self.sink = sink
        self.assistant = assistant
        let factory: QADriverFactory
        switch scenario.appKind {
        case .web: factory = QAWebDriverFactory()
        case .api: factory = QAAPIDriverFactory()
        case .nativeMacOS: factory = QANativeDriverFactory()
        }
        var config = QARunner.Config()
        config.captureInputs = recordVideo
        config.keepSessions = true
        config.startPoint = startPoint
        let runner = QARunner(scenario: scenario, plan: plan, gate: gate, factory: factory, assistant: assistant, runID: runID,
                              confirm: { [weak self] confirmation in await self?.ask(confirmation) ?? false }, observer: sink, config: config, control: control, sessions: sessions)

        let (queue, jobsContinuation) = AsyncStream.makeStream(of: ReviewJob.self)
        jobs = jobsContinuation
        reviewer = Task { [weak self] in
            for await job in queue {
                guard let self else { return }
                await self.review(job)
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
            self?.jobs?.finish()
            await self?.reviewer?.value
            await self?.finishRun()
        }
    }

    /// Stops the run: the branch in progress is interrupted and the ones not started stay uncovered.
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

    /// Called on project changes; wait for the active runner before closing its players.
    func releaseSessions() {
        stop()
        let task = runTask, old = sessions
        sessions = QARunSessions()
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
        costUSD = nil
        question = nil
        currentBranch = nil
        currentNode = nil
        pictures = [:]
        thumbnails = [:]
        writer = nil
        subtitle = nil
        reviewing = 0
        reviewed = []
        videoTasks = []
        videoStarts = [:]
        pendingScreen = [:]
        reviewsMade = 0
        reviewCost = 0
        nextFeedID = 1
    }

    // MARK: Events

    private func handle(_ event: QARunEvent) {
        switch event {
        case .runStarted:
            break
        case .branchStarted(let branch, _):
            currentBranch = branch
            currentNode = nil
            branchIndex = (plan?.branches.firstIndex { $0.id == branch } ?? 0) + 1
            branchStart = Date()
            pictures = [:]
            screenshots = [:]
            thumbnails = [:]
            subtitle = nil
            players.removeAll { $0.id == Self.setupPlayer }
            for index in players.indices { players[index].picture = nil; players[index].address = ""; players[index].title = "" }
            startVideo(branch)
        case .narration(let entry):
            subtitle = entry.text
            let key = entry.actor ?? Self.setupPlayer
            addFeed(time: entry.time, kind: entry.kind, actor: entry.actor, node: entry.node, text: entry.text, picture: thumbnails[key], screenshot: screenshots[key], screen: screenNumbers[key] ?? 0)
            addFrame()
        case .paused(let paused):
            isPaused = paused
            pauseRequested = false
            subtitle = paused ? "Execution paused" : "Execution resumed"
            addFrame()
        case .screen(let screen):
            show(screen)
        case .input(let actor, let mark, let png):
            let key = actor ?? Self.setupPlayer
            var shown = pictures
            if let png, let image = QAFrameComposer.image(from: png) { shown[key] = image }
            addFrame(input: (key, mark), pictures: shown)
        case .nodeStarted(_, let node, _, _):
            currentNode = node
            players.removeAll { $0.id == Self.setupPlayer }
        case .nodeFinished(_, let node, let effort):
            if reviewDepth != .off, var last = pendingScreen.removeValue(forKey: node) {
                last.event.stepEffort = effort
                enqueue(last.event, shownAt: last.shownAt, endOfStep: true)
            }
        case .branchFinished(let result):
            results.append(result)
            currentNode = nil
            finishVideo(result.branch)
        case .runFinished(let finished):
            record = finished
        }
    }

    private func show(_ screen: QAScreenEvent) {
        let key = screen.actor ?? Self.setupPlayer
        if screen.actor == nil, !players.contains(where: { $0.id == key }) { players.insert(Player(id: key, name: "Preparation"), at: 0) }
        guard let index = players.firstIndex(where: { $0.id == key }) else { return }
        players[index].address = screen.observation.address
        players[index].title = screen.observation.title
        guard let png = screen.png, let full = QAFrameComposer.image(from: png) else { return }
        pictures[key] = full
        screenshots[key] = png
        screenCount += 1
        screenNumbers[key] = screenCount
        let thumbnail = QAFrameComposer.thumbnail(from: png)
        thumbnails[key] = thumbnail
        players[index].picture = thumbnail
        addFrame()
        guard screen.isNew, let node = screen.node, reviewDepth != .off else { return }
        let shown = PendingScreen(event: screen, shownAt: max(0, Date().timeIntervalSince(runStart)))
        if let earlier = pendingScreen.updateValue(shown, forKey: node), reviewDepth == .screens {
            enqueue(earlier.event, shownAt: earlier.shownAt, endOfStep: false)
        }
    }

    private func addFeed(time: Double, kind: QATimelineEntry.Kind, actor: String?, node: String?, text: String, picture: NSImage?, screenshot: Data? = nil,
                         screen: Int = 0, finding: QAFinding? = nil) {
        feed.append(FeedItem(id: nextFeedID, time: time, kind: kind, actor: actor, node: node, text: text, picture: picture, screenshot: screenshot, screen: screen, finding: finding))
        nextFeedID += 1
    }

    /// The newest screenshot of a player as it was taken, for the viewer; nil before the first one and between branches.
    func screenshot(ofPlayer id: String) -> Data? { screenshots[id] }

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
        currentBranch = nil
        currentNode = nil
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
        let results = await filer.file(candidates)
        var created: [String] = [], already = 0, failures: [String] = []
        for result in results {
            switch result.status {
            case .created(let id): created.append(id)
            case .alreadyFiled: already += 1
            case .failed(let message): failures.append(message)
            }
        }
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
        guard reviewsMade < Self.maxReviews, screen.png != nil else { return }
        let signature = QAScreen.signature(address: screen.observation.address, snapshot: screen.observation.snapshot)
        guard reviewed.insert(signature).inserted else { return }
        reviewsMade += 1
        reviewing += 1
        jobs?.yield(ReviewJob(event: screen, number: reviewsMade, endOfStep: endOfStep, shownAt: shownAt))
    }

    private func review(_ job: ReviewJob) async {
        defer { reviewing -= 1 }
        guard !Task.isCancelled, let scenario, let root, let png = job.event.png else { return }
        let screen = job.event
        guard let node = screen.node.flatMap({ scenario.node($0) }), let app = scenario.app(scenario.appID(of: node) ?? "") else { return }
        let actorName = screen.actor.flatMap { id in scenario.actors.first { $0.id == id }?.name } ?? "the user"
        let input = QAReviewInput(app: app, node: node, actorName: actorName, screenAddress: screen.observation.address, screenTitle: screen.observation.title,
                                  snapshot: screen.observation.snapshot, effort: screen.stepEffort, branchEffort: screen.branchEffort, evidence: screen.evidence,
                                  alreadyReported: findings.map(\.title), endOfStep: job.endOfStep, language: QALanguage.name(of: scenario))
        let folder = QAStore.runFolder(root, runID: runID)
        let relative = "frames/\(job.number).png"
        let file = folder.appendingPathComponent(relative)
        let written = await Task.detached(priority: .utility) { () -> Bool in
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: file, options: .atomic)
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
            let result = try await CLICompletion.run(request)
            reviewCost += result.costUSD ?? 0
            var found = QAReview.parse(result.structured, input: input, firstFindingNumber: findings.count + 1)
            let picture = QAFrameComposer.thumbnail(from: png)
            let at = job.shownAt
            for index in found.indices {
                found[index].frame = relative
                found[index].time = at
                found[index].app = app.id
                findings.append(found[index])
                addFeed(time: at, kind: .observation, actor: screen.actor, node: screen.node, text: found[index].title, picture: picture, screenshot: png,
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
        writer = nil
        guard recordVideo, let root, let scenario, scenario.appKind != .api, let plan, let found = plan.branches.first(where: { $0.id == branch }) else { return }
        slots = scenario.actors(in: found)
        if slots.isEmpty { slots = [Self.setupPlayer] }
        let size = QAFrameComposer.pictureSize(players: slots.count)
        let url = QAStore.runFolder(root, runID: runID).appendingPathComponent("branch-\(branchIndex).mp4")
        do {
            writer = try QAVideoWriter(url: url, pictureSize: size)
            videoStarts[branch] = branchStart.timeIntervalSince(runStart)
        } catch { notice = "The video could not be started: \(error.localizedDescription)" }
    }

    /// The latest pictures of the players, side by side, with the subtitle that is current, at this second of the branch.
    private func addFrame(input: (String, QAInputMark)? = nil, pictures source: [String: CGImage]? = nil) {
        guard let writer else { return }
        let pictures = source ?? self.pictures
        var shown = slots.map { pictures[$0] }
        // The session that prepares data is nobody's: it takes the first player's place until the steps begin.
        if let setup = pictures[Self.setupPlayer], !shown.isEmpty, shown[0] == nil { shown[0] = setup }
        var marks: [Int: QAInputMark] = [:]
        if let (key, mark) = input, let index = key == Self.setupPlayer ? (shown.isEmpty ? nil : 0) : slots.firstIndex(of: key) { marks[index] = mark }
        let names = slots.map { id in players.first { $0.id == id }?.name ?? id }
        guard let composed = QAFrameComposer.compose(shown, marks: marks, names: names) else { return }
        do { try writer.append(composed, at: max(0, Date().timeIntervalSince(branchStart)), subtitle: subtitle,
                               minimumDuration: input == nil ? 0 : 0.75) } catch {
            notice = "The video stopped: \(error.localizedDescription)"
            self.writer = nil
        }
    }

    private func finishVideo(_ branch: String) {
        guard let writer else { return }
        self.writer = nil
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
