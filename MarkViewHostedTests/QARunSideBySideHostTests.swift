import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

// End-to-End QA: the branches of one run side by side (QARunner.branchLimit), through the window's own run (QARunModel.start) with a
// browser and an assistant made up for the check: how many branches run at once, which take turns, Pause and Stop with branches in
// flight, the person's questions, and the order of the review and its findings.

/// A page that shows the text typed into it last. Its screenshot is a real picture, so the review and the video work as in a run.
// unchecked Sendable: `lock` guards the typed text, which the steps of the session's branch write and read.
private final class ParallelDriver: QAActorDriver, @unchecked Sendable {
    static let picture = QATestImage.pngData()
    let request: QADriverRequest
    private let lock = NSLock()
    private var typed = ""
    init(_ request: QADriverRequest) { self.request = request }
    func open(_ address: String) async throws {}
    func observe() async throws -> QAObservation {
        let text = lock.withLock { typed }
        return QAObservation(address: request.address + "/page", title: "Page", snapshot: "typed \(text)\n[e1] textbox \"Note\"")
    }
    func perform(_ action: QAAction) async throws -> String {
        lock.withLock { typed = action.text }
        return "ok"
    }
    func screenshot() async -> Data? { Self.picture }
    func arm(_ fault: QAFault) async throws {}
    func faultHits() async -> Int { 0 }
    func close() async {}
}

// unchecked Sendable: `lock` guards the sessions asked for; branches running side by side open theirs at the same time.
private final class ParallelFactory: QADriverFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [QADriverRequest] = []
    var requests: [QADriverRequest] { lock.withLock { made } }
    func makeDriver(_ request: QADriverRequest) async throws -> QAActorDriver {
        lock.withLock { made.append(request) }
        return ParallelDriver(request)
    }
}

/// The assistant of the steps: it types a text naming the branch and the step, then says the step is done (a check is done at once).
/// Every answer takes a while, so the branches in progress all wait for one at the same time; the `slow` branch's take four times as long.
// unchecked Sendable: `lock` guards the counts; the branches running side by side ask at the same time.
private final class ParallelAssistant: QAAssistant, @unchecked Sendable {
    private let lock = NSLock()
    private var asking = 0
    private var most = 0
    private var asked = 0
    private let pause: UInt64
    private let slow: String?
    init(pause milliseconds: UInt64 = 150, slow: String? = nil) {
        pause = milliseconds * 1_000_000
        self.slow = slow
    }
    /// The most branches that waited for an answer at the same time, how many wait now, and how many answers were asked for.
    var peak: Int { lock.withLock { most } }
    var waiting: Int { lock.withLock { asking } }
    var calls: Int { lock.withLock { asked } }

    func decide(system: String, prompt: String, schema: [String: Any], isolation: isolated (any Actor)?) async throws -> Any? {
        let lines = prompt.components(separatedBy: "\n")
        let branch = lines.first { $0.hasPrefix("Active branch ID: ") }.map { String($0.dropFirst("Active branch ID: ".count)) } ?? ""
        let step = lines.first { $0.hasPrefix("Step (") } ?? ""
        lock.withLock { asking += 1; asked += 1; most = max(most, asking) }
        defer { lock.withLock { asking -= 1 } }
        try await Task.sleep(nanoseconds: branch == slow ? pause * 4 : pause)
        let title = step.components(separatedBy: "): ").dropFirst().joined(separator: "): ")
        let tag = ParallelFixture.tag(branch, title)
        if step.hasPrefix("Step (a check") || prompt.contains("typed \(tag)\n") {
            return ["move": "done", "narration": "Done.", "action": ["kind": "none"], "reason": "", "blockReason": ""] as [String: Any]
        }
        let action: [String: Any] = ["kind": "fill", "ref": "e1", "text": tag, "url": "", "method": "", "direction": "", "amount": 0]
        return ["move": "act", "narration": "Typing", "action": action, "reason": "", "blockReason": ""] as [String: Any]
    }
}

/// The review of a screen: one finding named after the text on it, a defect on the screen `defect`. It keeps what each review was told.
// unchecked Sendable: `lock` guards the reviews kept; the run's reviewer asks for them one after another.
private final class ParallelReviewer: @unchecked Sendable {
    struct Review: Equatable {
        var screen: String
        var reported: [String]
    }
    private let lock = NSLock()
    private var told: [Review] = []
    let defect: String
    init(defect: String) { self.defect = defect }
    var reviews: [Review] { lock.withLock { told } }

    func review(_ request: CLICompletion.Request) throws -> CLICompletion.Result {
        let lines = request.prompt.components(separatedBy: "\n")
        let screen = lines.first { $0.hasPrefix("typed ") }.map { String($0.dropFirst("typed ".count)) } ?? ""
        var reported: [String] = []
        if let start = lines.firstIndex(where: { $0.hasPrefix("Already reported on earlier screens") }) {
            for line in lines[(start + 1)...] {
                guard line.hasPrefix("- ") else { break }
                reported.append(String(line.dropFirst(2)))
            }
        }
        lock.withLock { told.append(Review(screen: screen, reported: reported)) }
        let isDefect = screen == defect
        let kind = isDefect ? "defect" : "wording"
        let finding: [String: Any] = ["kind": kind, "severity": "low", "title": ParallelFixture.title(of: screen),
                                      "detail": "Seen on the screen.", "proposal": "Change it.", "isDefect": isDefect]
        return try CLICompletion.Result(text: "", structured: ["findings": [finding]], inputTokens: 0, outputTokens: 0, costUSD: nil)
    }
}

/// Where the run's bug reports go: it keeps the keys the filer looked up and the reports it wrote.
private actor ParallelBugSink: QABugSink {
    private(set) var lookedUp: [String] = []
    private(set) var written: [QABugReport] = []
    func bugFolder() async -> URL? { nil }
    func filedBugs(forKeys keys: [String]) async throws -> [String: String] {
        lookedUp += keys
        return [:]
    }
    func allFiledKeys() async throws -> [String] { [] }
    func createBug(_ report: QABugReport) async throws -> String {
        written.append(report)
        return "BUG-\(written.count)"
    }
    func applyTriage(key: String, _ change: QABugTriageChange) async throws -> QABugTriageOutcome { .noReport }
}

@MainActor private enum ParallelFixture {
    static let made = Date(timeIntervalSince1970: 1_800_000_000)

    /// The text the assistant types on a step of a branch, and the title of the review's finding on that screen. Letters only: the screen
    /// of a step is told apart by its text, which ignores digits.
    nonisolated static func tag(_ branch: String, _ title: String) -> String {
        let path = branch.replacingOccurrences(of: ">", with: " ")
        return "\(path) at \(title)"
    }
    nonisolated static func title(of screen: String) -> String { "Look at \(screen)" }

    /// A start step "s" and after it `count` branches of one action each (`s>ba`, `s>bb`, …), for one player with no sign-in.
    static func scenario(_ kind: QAAppKind = .web, branches count: Int, target: QATargetKind = .local, policy: QANativeStartupPolicy? = nil,
                         changesData: QADataChange = .no) -> QAScenario {
        let ids = ["ba", "bb", "bc", "bd", "be"].prefix(count)
        var nodes = [QANode(id: "s", kind: .action, title: "Start", detail: "Open the page", changesData: changesData)]
        nodes += ids.map { QANode(id: $0, kind: .action, title: "Step \($0)", detail: "Do \($0)", changesData: changesData) }
        let location: QALocation
        if kind == .nativeMacOS {
            location = QALocation(application: QAApplication(bundleIdentifier: "com.example.shop", name: "Shop", startupPolicy: policy))
        } else {
            location = QALocation(url: target == .production ? "https://shop.example.com" : "http://localhost:3000")
        }
        var scenario = QAScenario(id: "parallel", title: "Side by side", goal: "Every branch passes", appKind: kind, apps: [QAApp(id: "shop", name: "Shop")],
                                  targets: [QATarget(id: "env", kind: target, name: "Environment", locations: ["shop": location])],
                                  actors: [QAActor(id: "buyer", name: "Buyer")], nodes: nodes, edges: ids.map { QAEdge(from: "s", to: $0) },
                                  start: "s", created: made, updated: made)
        scenario.selected = scenario.enumerateBranches().branches.map(\.id)
        return scenario
    }

    /// Starts the window's run of `scenario`, approved as the person would, with the made-up browser and assistant. Nil when the plan
    /// cannot be approved.
    static func start(_ run: QARunModel, _ scenario: QAScenario, root: URL, assistant: ParallelAssistant,
                      factory: ParallelFactory = ParallelFactory()) -> QAExecutionPlan? {
        let plan = QAPlanner.make(scenario, targetID: "env", savedLogins: [])
        var gate = QAGate(plan: plan)
        guard gate.approve(acknowledgedProduction: true) else { return nil }
        run.testDriverFactory = factory
        run.testRunnerAssistant = assistant
        run.start(scenario: scenario, plan: plan, gate: gate, root: root)
        return run.isRunning ? plan : nil
    }

    static func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qa-side-by-side-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The person's video and review settings, which the window's run writes through, as they were before a check.
    static func keepSettings() -> () -> Void {
        let video = Settings.standard.value(Setting.qaRecordVideo)
        let depth = Settings.standard.value(Setting.qaReviewDepth)
        return {
            Settings.standard.set(video, for: Setting.qaRecordVideo)
            Settings.standard.set(depth, for: Setting.qaReviewDepth)
        }
    }

    /// A window's run with no video and no review, unless a check turns them on.
    static func quietRun() -> QARunModel {
        let run = QARunModel()
        run.recordVideo = false
        run.reviewDepth = .off
        return run
    }
}

extension EditorHostTests {
    @MainActor func testQAWebBranchesRunThreeAtATime() async throws {
        let restore = ParallelFixture.keepSettings()
        defer { restore() }
        let root = try ParallelFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = ParallelFixture.quietRun()
        defer { run.stop() }
        let assistant = ParallelAssistant(slow: "s>ba")
        let plan = try XCTUnwrap(ParallelFixture.start(run, ParallelFixture.scenario(branches: 5), root: root, assistant: assistant))
        let order = plan.branches.map(\.id)
        XCTAssertEqual(order, ["s>ba", "s>bb", "s>bc", "s>bd", "s>be"])

        var shown = 0
        var tiles: Set<String> = []
        let ended = await ParallelFixture.eventually {
            shown = max(shown, run.running.count)
            tiles.formUnion(run.players.map(\.name))
            return run.phase == .finished
        }
        XCTAssertTrue(ended, "the run ends")
        XCTAssertEqual(assistant.peak, 3, "three web branches are checked at the same time, never more")
        XCTAssertEqual(shown, 3, "the window shows the three branches in progress")
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.results.max { $0.finishedAt < $1.finishedAt }?.branch, "s>ba", "the slow first branch ends last")
        XCTAssertEqual(run.results.map(\.branch), order, "the window lists the results in the order of the plan")
        XCTAssertEqual(record.results.map(\.branch), order, "the run keeps its results in the order of the plan")
        XCTAssertEqual(record.results.map(\.verdict.outcome), Array(repeating: .passed, count: 5), "every branch passes")
        XCTAssertNil(run.currentBranch, "no single branch is current once the run has ended")

        // The lines of the branches interleave: each names its branch with the label its player's tile carries.
        let labels = order.map { run.labels[$0] ?? "" }
        XCTAssertEqual(Set(labels).count, 5, "every branch has a label of its own")
        XCTAssertTrue(tiles.isSuperset(of: labels.map { "Buyer · \($0)" }), "the player's tile of each branch carries its label")
        XCTAssertTrue(record.timeline.contains { $0.node == "s" } && record.timeline.contains { $0.node == "be" }, "the steps of the branches are in the feed")
        XCTAssertEqual(run.feed.map(\.text), record.timeline.map { "\(run.labels[$0.branch] ?? "") · \($0.text)" },
                       "every line of the feed begins with the label of the branch it comes from")
    }

    @MainActor func testQANativeBranchesTakeTurns() async throws {
        let restore = ParallelFixture.keepSettings()
        defer { restore() }
        for policy in [QANativeStartupPolicy.attach, .launch] {
            let root = try ParallelFixture.folder()
            defer { try? FileManager.default.removeItem(at: root) }
            let run = ParallelFixture.quietRun()
            defer { run.stop() }
            let assistant = ParallelAssistant(), factory = ParallelFactory()
            let scenario = ParallelFixture.scenario(.nativeMacOS, branches: 3, policy: policy)
            _ = try XCTUnwrap(ParallelFixture.start(run, scenario, root: root, assistant: assistant, factory: factory))
            let ended = await ParallelFixture.eventually { run.phase == .finished }
            XCTAssertTrue(ended, "the native run ends (\(policy))")
            XCTAssertEqual(assistant.peak, 1, "native branches take turns (\(policy))")
            XCTAssertEqual(run.record?.results.map(\.verdict.outcome), Array(repeating: .passed, count: 3), "every native branch passes (\(policy))")
            XCTAssertEqual(factory.requests.count, policy == .attach ? 1 : 3,
                           "the attached application is one session for the whole run; a launched one is a session per branch (\(policy))")
            XCTAssertEqual(run.feed.map(\.text), run.record?.timeline.map(\.text), "branches in turn write their lines with no label (\(policy))")
        }
    }

    @MainActor func testQABaselineOrDataConditionKeepsBranchesInTurn() async throws {
        let restore = ParallelFixture.keepSettings()
        defer { restore() }
        var withBaseline = ParallelFixture.scenario(branches: 3)
        withBaseline.baseline = QACondition(kind: .state, establish: "Empty the cart", verify: "The cart is empty")
        var withData = ParallelFixture.scenario(branches: 3)
        if let index = withData.nodes.firstIndex(where: { $0.id == "bb" }) {
            withData.nodes[index].kind = .alternative
            withData.nodes[index].condition = QACondition(kind: .data, establish: "Use the decline test card", verify: "The card field holds it")
        }
        for (name, scenario) in [("a baseline", withBaseline), ("a data condition", withData)] {
            let root = try ParallelFixture.folder()
            defer { try? FileManager.default.removeItem(at: root) }
            let run = ParallelFixture.quietRun()
            defer { run.stop() }
            let assistant = ParallelAssistant()
            _ = try XCTUnwrap(ParallelFixture.start(run, scenario, root: root, assistant: assistant), "the plan with \(name) is approved")
            let ended = await ParallelFixture.eventually { run.phase == .finished }
            XCTAssertTrue(ended, "the run with \(name) ends")
            XCTAssertEqual(assistant.peak, 1, "a web run with \(name) checks its branches one at a time")
            XCTAssertEqual(run.record?.results.map(\.verdict.outcome), Array(repeating: .passed, count: 3), "every branch passes with \(name)")
            XCTAssertEqual(run.feed.map(\.text), run.record?.timeline.map(\.text), "branches in turn write their lines with no label (\(name))")
        }
    }

    @MainActor func testQAPauseAndResumeWithBranchesInFlight() async throws {
        let restore = ParallelFixture.keepSettings()
        defer { restore() }
        let root = try ParallelFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = ParallelFixture.quietRun()
        defer { run.stop() }
        let assistant = ParallelAssistant(pause: 200)
        let plan = try XCTUnwrap(ParallelFixture.start(run, ParallelFixture.scenario(branches: 3), root: root, assistant: assistant))

        let inFlight = await ParallelFixture.eventually { assistant.waiting == 3 }
        XCTAssertTrue(inFlight, "three branches wait for the assistant at once")
        run.pause()
        let pausedLines = Set(plan.branches.map { "\(run.labels[$0.id] ?? "") · Execution paused." })
        let paused = await ParallelFixture.eventually(10) { pausedLines.isSubset(of: run.feed.map(\.text)) }
        XCTAssertTrue(paused, "each branch in flight stops at the gate")
        XCTAssertTrue(run.isPaused, "the window shows the run paused")
        let asked = assistant.calls
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(assistant.calls, asked, "no branch asks the assistant while the run is paused")
        XCTAssertEqual(assistant.waiting, 0)

        run.resume()
        let ended = await ParallelFixture.eventually { run.phase == .finished }
        XCTAssertTrue(ended, "Resume lets every paused branch go on, and the run ends")
        XCTAssertFalse(run.isPaused)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.results.map(\.verdict.outcome), Array(repeating: .passed, count: 3), "every branch passes after the pause")
        let order = plan.branches.map(\.id)
        XCTAssertEqual(Set(record.timeline.filter { $0.text == "Execution paused." }.map(\.branch)), Set(order), "each branch tells it was paused")
        XCTAssertEqual(Set(record.timeline.filter { $0.text == "Execution resumed." }.map(\.branch)), Set(order), "and that it went on")
    }

    @MainActor func testQAStopWithBranchesInFlight() async throws {
        let restore = ParallelFixture.keepSettings()
        defer { restore() }
        let root = try ParallelFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = ParallelFixture.quietRun()
        defer { run.stop() }
        let sink = ParallelBugSink()
        run.bugFiler = QABugFiler(sink: sink)
        let assistant = ParallelAssistant(pause: 400)
        let scenario = ParallelFixture.scenario(branches: 5)
        let plan = try XCTUnwrap(ParallelFixture.start(run, scenario, root: root, assistant: assistant))
        let order = plan.branches.map(\.id)

        let inFlight = await ParallelFixture.eventually { assistant.waiting == 3 }
        XCTAssertTrue(inFlight, "three branches wait for the assistant at once")
        run.stop()
        let ended = await ParallelFixture.eventually(20) { run.phase == .finished }
        XCTAssertTrue(ended, "Stop ends the run with three branches in flight")
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.results.map(\.branch), order)
        XCTAssertEqual(record.results.prefix(3).map(\.verdict.interruption), Array(repeating: .stoppedByUser, count: 3), "the branches in flight are interrupted")
        XCTAssertTrue(record.results.dropFirst(3).allSatisfy { $0.verdict.outcome == .uncovered && $0.verdict.reason == "Not executed: the run was stopped." },
                      "the branches not started are not executed")

        let stopped = Array(order.prefix(3))
        let keys = await sink.lookedUp
        XCTAssertEqual(keys, [QABugDrafts.key(run: record.id, stopped: stopped)], "the run drafts one bug for the one Stop")
        let drafts = QABugDrafts.drafts(run: record, scenario: scenario, findings: [], videos: [:], runFolder: root, now: Date())
        XCTAssertEqual(drafts.map(\.origin), [.stop(branches: stopped)])
        XCTAssertTrue(drafts.first?.title.hasPrefix(QAOutcome.interrupted.bugTitlePrefix ?? "-") == true)
        for branch in stopped {
            XCTAssertTrue(drafts.first?.body.contains(QABugDrafts.code(branch)) == true, "the bug names the interrupted branch \(branch)")
        }
        // The Stop cancels the run, not the filing of what it found (BUG-133).
        let written = await sink.written
        XCTAssertEqual(written.map(\.key), keys, "the bug of the Stop is filed")
        XCTAssertTrue(written.first?.title.hasPrefix(QAOutcome.interrupted.bugTitlePrefix ?? "-") == true)
        XCTAssertEqual(run.filedBugIDs, ["BUG-1"])
        XCTAssertTrue(run.notice?.contains("Filed bug: BUG-1.") == true, "the notice names the filed bug: \(run.notice ?? "none")")
    }

    /// The window going to another project stops the run and files none of its bugs: the window's filer would put them into the
    /// project it opens. The notice says so.
    @MainActor func testQAProjectChangeDuringARunFilesNoBugs() async throws {
        let restore = ParallelFixture.keepSettings()
        defer { restore() }
        let root = try ParallelFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = ParallelFixture.quietRun()
        defer { run.stop() }
        let sink = ParallelBugSink()
        run.bugFiler = QABugFiler(sink: sink)
        let assistant = ParallelAssistant(pause: 400)
        _ = try XCTUnwrap(ParallelFixture.start(run, ParallelFixture.scenario(branches: 5), root: root, assistant: assistant))

        let inFlight = await ParallelFixture.eventually { assistant.waiting == 3 }
        XCTAssertTrue(inFlight, "three branches wait for the assistant at once")
        run.releaseSessions()
        let ended = await ParallelFixture.eventually(20) { run.phase == .finished }
        XCTAssertTrue(ended, "a project change ends the run")
        XCTAssertEqual(run.record?.results.prefix(3).map(\.verdict.interruption), Array(repeating: .stoppedByUser, count: 3))
        let lookedUp = await sink.lookedUp
        let written = await sink.written
        XCTAssertTrue(lookedUp.isEmpty && written.isEmpty, "nothing is filed into the other project")
        XCTAssertTrue(run.filedBugIDs.isEmpty)
        XCTAssertTrue(run.notice?.contains("Its bug was not filed: the window opened another project during the run.") == true,
                      "the notice says why: \(run.notice ?? "none")")
    }

    @MainActor func testQAConfirmationsAreAskedOneAtATime() async throws {
        let restore = ParallelFixture.keepSettings()
        defer { restore() }
        let root = try ParallelFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = ParallelFixture.quietRun()
        defer { run.stop() }
        let assistant = ParallelAssistant()
        let scenario = ParallelFixture.scenario(branches: 3, target: .production, changesData: .yes)
        _ = try XCTUnwrap(ParallelFixture.start(run, scenario, root: root, assistant: assistant))

        var asked: [String] = []
        let end = Date().addingTimeInterval(30)
        while run.phase != .finished && Date() < end {
            if let question = run.question {
                asked.append(question.id)
                // Long enough for the other branches to reach the same question, or one of their own.
                try await Task.sleep(nanoseconds: 150_000_000)
                run.reply(true)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(run.phase, .finished, "every question is answered and the run ends")
        XCTAssertEqual(asked.first, "node:s", "the step all branches share is asked first")
        XCTAssertEqual(asked.sorted(), ["node:ba", "node:bb", "node:bc", "node:s"], "each change is asked once, one question after another")
        XCTAssertEqual(assistant.peak, 3, "the branches still run side by side")
        XCTAssertEqual(run.record?.results.map(\.verdict.outcome), Array(repeating: .passed, count: 3), "every branch passes once the person said yes")
    }

    @MainActor func testQAFindingsFollowThePlanOrderAndTheirBranch() async throws {
        let restore = ParallelFixture.keepSettings()
        defer { restore() }
        let root = try ParallelFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = QARunModel()
        defer { run.stop() }
        run.recordVideo = true
        run.reviewDepth = .steps
        let defect = ParallelFixture.tag("s>bb", "Start")
        let reviewer = ParallelReviewer(defect: defect)
        AIAssistantRunner.setTestRunner { request, _, _ in try reviewer.review(request) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let sink = ParallelBugSink()
        run.bugFiler = QABugFiler(sink: sink)
        let assistant = ParallelAssistant(slow: "s>ba")
        let plan = try XCTUnwrap(ParallelFixture.start(run, ParallelFixture.scenario(branches: 3), root: root, assistant: assistant))
        let order = plan.branches.map(\.id)

        let ended = await ParallelFixture.eventually(60) { run.phase == .finished }
        XCTAssertTrue(ended, "the run ends")
        XCTAssertEqual(assistant.peak, 3)
        XCTAssertEqual(run.record?.results.max { $0.finishedAt < $1.finishedAt }?.branch, "s>ba", "the slow first branch ends last")

        // The screen each step ended on, in the order of the plan.
        var screens: [String] = []
        for branch in plan.branches {
            screens.append(ParallelFixture.tag(branch.id, "Start"))
            screens.append(ParallelFixture.tag(branch.id, "Step \(branch.nodes.last ?? "")"))
        }
        let titles = screens.map(ParallelFixture.title(of:))
        XCTAssertEqual(reviewer.reviews.map(\.screen), screens, "the screens are reviewed in the order of the plan")
        for (index, review) in reviewer.reviews.enumerated() {
            XCTAssertEqual(review.reported, Array(titles.prefix(index)), "the review of \(review.screen) is told exactly the findings before it")
        }
        XCTAssertEqual(run.findings.map(\.title), titles, "the findings follow the order of the plan")
        XCTAssertEqual(run.findings.map(\.id), (1...6).map { "f\($0)" }, "and are numbered in it")
        XCTAssertEqual(run.findings.map(\.frame), (1...6).map { "frames/\($0).png" }, "and so are their pictures")
        XCTAssertEqual(run.findings.map(\.branch), order.flatMap { [$0, $0] }, "each finding remembers its branch")
        XCTAssertEqual(run.record?.findings.map(\.branch), run.findings.map(\.branch), "the run keeps the branch of each finding")

        let found = try XCTUnwrap(run.findings.first { $0.title == ParallelFixture.title(of: defect) })
        XCTAssertEqual(found.node, "s", "the defect is on the step every branch shares")
        let written = await sink.written
        let bug = try XCTUnwrap(written.first { $0.key == QABugDrafts.key(run: run.record?.id ?? "", finding: found.id) }, "the defect is filed")
        XCTAssertTrue(bug.body.contains("/branch-2.mp4"), "its bug links the recording of the second branch, where it was seen")
        XCTAssertFalse(bug.body.contains("/branch-1.mp4"), "not the first branch with that step")
    }

    @MainActor func testQAFindingOfAnOlderRunHasNoBranch() throws {
        var finding = QAFinding(id: "f1", node: "s", app: "shop", kind: .wording, severity: .low, title: "Say Pay now", detail: "d", proposal: "p", isDefect: false)
        finding.branch = "s>bb"
        let data = try QAStore.encoder.encode(finding)
        XCTAssertEqual(try QAStore.decoder.decode(QAFinding.self, from: data).branch, "s>bb", "a finding keeps its branch")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["branch"] = nil
        let older = try JSONSerialization.data(withJSONObject: object)
        let decoded = try QAStore.decoder.decode(QAFinding.self, from: older)
        XCTAssertNil(decoded.branch, "a finding written before findings named their branch reads with none")
        XCTAssertEqual(decoded.title, finding.title)
    }
}
