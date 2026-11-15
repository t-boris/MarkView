import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// How one repair ended, so that the ledger and the notices tell the truth.
enum StudioFixResult: Equatable {
    /// The corrections were saved (with what Undo needs), or the rules were prepared (nothing to undo).
    case fixed(StudioRepairUndo?)
    /// The assistant found that data did not cause the error.
    case notData(String)
    /// MarkView refused the assistant's corrections.
    case refused(String)
    /// The assistant did not answer, or the run could not finish.
    case failed(String)
    /// The person cancelled.
    case cancelled
    /// The page changed while the assistant worked; nothing was done.
    case dropped
}

/// Problems and repair (REQ-017, REQ-019, REQ-020, DEC-013): Studio repairs the page errors it can repair by itself, after the page has
/// settled at open and after later errors, and the same repairs run on the person's click from the Log. What is repairable is decided by
/// fixed rules (UIStudioRepair.swift); the assistant only proposes data, which MarkView checks before it saves anything. Owns what came of
/// this open's repairs, the last fix for Undo, the sign-in page the application sent the page to, and the debounced automatic look.
@MainActor
final class StudioRepair: ObservableObject {
    unowned let session: StudioSession

    /// What came of this open's repairs, so that nothing loops (REQ-020).
    var repairLedger = StudioRepairLedger()

    /// The last fix, for Undo (REQ-020); nil once undone, dismissed or the scenario changed.
    @Published var repairUndo: StudioRepairUndo?

    /// The sign-in page the application sent the current page to, when the scenario did not ask for it (REQ-020).
    @Published var signInWall: String?

    /// The debounced automatic repair waiting to look at the page.
    var autoRepairTask: Task<Void, Never>?

    /// The page's errors Fix data may be offered for: one per message, the latest first, only those of the page as it is now.
    /// A Reset or a fix starts a new page, so an error is offered again only when it comes back after the fix.
    var fixableErrors: [StudioDataFix.PageError] {
        StudioDataFix.fixable(session.events.map { StudioDataFix.Seen(kind: $0.kind, detail: $0.detail, generation: $0.generation, date: $0.date) },
                              generation: session.simulator.generation)
    }

    /// The page error the data fix of `key` is about: one of the page as it is now, or an earlier page of the same scenario (a reload or
    /// a fix starts a new page, not a new scenario), so a row of the Log keeps its action.
    func fixError(for key: String) -> StudioDataFix.PageError? {
        if let current = fixableErrors.first(where: { $0.key == key }) { return current }
        let seen = session.events.filter { $0.scenarioID == session.scenario.id }
            .map { StudioDataFix.Seen(kind: $0.kind, detail: $0.detail, generation: $0.generation, date: $0.date) }
        return StudioDataFix.latest(seen, key: key)
    }

    /// Repairs the simulated data a page error came from (REQ-017). The person's click; the same repair runs by itself at open and
    /// after later errors (REQ-020, DEC-013). The assistant reads the error, what the page was answered with, the records and the
    /// code (read-only) and either corrects existing records or says that data did not cause the error. MarkView checks every
    /// correction on a copy; nothing is saved unless all of them pass.
    func fixData(_ key: String? = nil) {
        guard let error = fixableErrors.first(where: { key == nil || $0.key == key }) ?? key.flatMap({ fixError(for: $0) }) else {
            session.notice = "The page reports no error that data could have caused."
            return
        }
        repairProblem(StudioProblem.Item(kind: .dataError, key: error.key, text: error.key))
    }

    func performDataFix(_ error: StudioDataFix.PageError) async -> StudioFixResult {
        let generation = session.simulator.generation, scenarioID = session.scenario.id
        session.sessionLog.add(.notice, "Fix data: asking the assistant about \"\(String(error.key.prefix(160)))\"")
        func fixRequest(retryProblems: [String]) -> CLICompletion.Request {
            var call = CLICompletion.Request(project: session.root,
                                             prompt: StudioDataFix.prompt(error: error, route: session.route, served: session.servedAnswers, spec: session.spec,
                                                                          records: session.scenario.data ?? session.spec.seed, scenario: session.scenario,
                                                                          redactor: session.redactor, hashes: session.secretHashes, retryProblems: retryProblems),
                                             systemPrompt: StudioDataFix.system, jsonSchema: StudioDataFix.schema, readableFolder: session.root)
            call.timeout = StudioDataFix.timeout
            call.effort = "medium"
            call.label = "ui-studio:fix-data"
            return call
        }
        // Asked twice at most: the second time with what MarkView refused in the first answer.
        let fixing = AIOperation<[String], DataFixAnswer>(
            name: "ui-studio:fix-data",
            maxRepairAttempts: 1,
            buildRequest: { fixRequest(retryProblems: $0) },
            parse: { [weak self] _, result, _ in
                guard let self else { throw CancellationError() }
                guard let plan = StudioDataFix.plan(from: result.structured) else { throw DataFixUnreadable() }
                // The page the assistant looked at is gone (a Reset, another scenario): its corrections would be for other data.
                guard !self.session.closed, self.session.simulator.generation == generation, self.session.scenario.id == scenarioID else { throw DataFixDropped() }
                if plan.kind == .notData { return .notData(plan) }
                let outcome = StudioDataFix.apply(plan.changes, spec: self.session.spec, scenarioData: self.session.scenario.data,
                                                  redactor: self.session.redactor)
                let problems = plan.unreadable + outcome.problems
                guard problems.isEmpty, outcome.ok else { throw DataFixRefused(problems: problems) }
                return .corrected(outcome)
            },
            repair: { [weak self] context in
                self?.session.busyDetail = "The assistant is correcting its answer"
                return fixRequest(retryProblems: (context.error as? DataFixRefused)?.problems ?? [])
            },
            onResult: { [weak self] result in self?.session.recordUsage(result.inputTokens, result.outputTokens, result.costUSD ?? 0) })
        session.busyDetail = "The assistant is reading the error and the code"
        let answer: DataFixAnswer
        do {
            answer = try await fixing.execute([], onActivity: { [weak self] activity in
                Task { @MainActor in self?.session.progress(activity) }
            }).output
        } catch is CancellationError {
            return .cancelled
        } catch is DataFixUnreadable {
            session.notice = "Fix data: the assistant's answer was not a set of corrections. Nothing was changed."
            return .failed("The answer was not a set of corrections.")
        } catch is DataFixDropped {
            session.notice = "Fix data was dropped: the scenario was reset while the assistant worked. Nothing was changed."
            return .dropped
        } catch let refused as DataFixRefused {
            for problem in refused.problems.prefix(10) { session.sessionLog.add(.notice, problem: true, "Fix data refused a correction: " + problem) }
            session.notice = "Fix data: the assistant's corrections were refused (\(refused.problems.first ?? "no correction")). Nothing was changed."
            return .refused("The corrections were refused.")
        } catch {
            session.notice = "Fix data failed: \(error.localizedDescription) Nothing was changed."
            return .failed(error.localizedDescription)
        }
        switch answer {
        case .notData(let plan):
            let where_ = plan.codePointer.isEmpty ? "" : " Look at \(plan.codePointer)."
            session.notice = "Fix data: data did not cause this error. \(plan.summary)\(where_) Nothing was changed."
            return .notData(plan.summary + where_)
        case .corrected(let outcome):
            return await commitDataFix(outcome, error: error)
        }
    }

    /// Saves checked corrections and reloads the page on them: the scenario's own records first (a failure there changes
    /// nothing), then the environment's seed, then a restore, which is a new page generation.
    func commitDataFix(_ outcome: StudioDataFix.Outcome, error: StudioDataFix.PageError?, undoing: Bool = false,
                       automatic: Bool = false) async -> StudioFixResult {
        session.busyDetail = "Saving the corrected data"
        var changedScenario: StudioScenario?
        if outcome.applied.contains(where: \.inScenario), let data = outcome.scenarioData {
            var next = session.scenario
            next.data = data
            next.updated = Date()
            next.revision += 1
            if !next.id.hasPrefix("builtin-") {
                let root = session.root, saving = next
                do {
                    session.savedScenarios = try await Task.detached { () throws -> [StudioScenario] in
                        try StudioStore.saveScenario(saving, root: root)
                        return StudioStore.loadScenarios(root)
                    }.value
                } catch {
                    session.notice = "Fix data: the scenario could not be saved (\(error.localizedDescription)). Nothing was changed."
                    return .failed("The scenario could not be saved.")
                }
            }
            changedScenario = next
        }
        var environment = session.simulator.spec
        // Only the entities that were corrected: the map's refill or a preparation may have changed others while the scenario was saved.
        let seeded = Set(outcome.applied.filter(\.inSeed).map(\.entity))
        if !seeded.isEmpty {
            for name in seeded { environment.seed[name] = outcome.seed[name] }
            environment.updated = Date()
        }
        session.replaceEnvironment(environment)
        if let changedScenario {
            session.switchScenario(to: changedScenario, keepingRecordedSteps: true)
        }
        session.notice = nil
        session.notice = undoing ? "Undone: the records have their earlier values again." : StudioDataFix.summary(outcome.applied)
        for reason in StudioDataFix.reasons(outcome.applied) where !undoing { session.sessionLog.add(.notice, reason) }
        session.busyDetail = "Reloading the page on the corrected data"
        let problem = await session.restore()
        if let problem { session.sessionLog.add(.notice, problem: true, "After Fix data the page was not restored completely: " + problem) }
        if let error, fixableErrors.contains(where: { $0.key == error.key }) {
            session.sessionLog.add(.notice, problem: true, "The page still reports \"\(String(error.key.prefix(160)))\" on the corrected data. Fix data can run again.")
        }
        guard !undoing else { return .fixed(nil) }
        return .fixed(StudioRepairUndo(summary: StudioDataFix.summary(outcome.applied), scenarioID: session.scenario.id, applied: outcome.applied,
                                       automatic: automatic))
    }

    /// A reference the work of `runWork` writes its result into.
    final class RepairBox {
        var result: StudioFixResult?
        /// The turn the sign-in request will add, to tell it from an earlier one.
        var historyMark: String?
        var identity = ""
    }

    // MARK: - What can be repaired

    /// Remembers the sign-in page the application sent the page to, or forgets it once the page is somewhere else. Not when the scenario
    /// asked for the sign-in screen itself.
    func noteSignInWall(_ route: String) {
        let path = URLComponents(string: route)?.path ?? route
        if !StudioLogFormat.isSignInPath(route) && !StudioLogFormat.isSignInPath(path) {
            signInWall = nil
            return
        }
        let wanted = URLComponents(string: session.scenario.route)?.path ?? session.scenario.route
        guard !StudioLogFormat.isSignInPath(session.scenario.route), !StudioLogFormat.isSignInPath(wanted) else { return }
        signInWall = route
    }

    /// The problems of the page as it is now that a repair may start for, in the order that helps. For an automatic repair, only those
    /// the ledger still allows.
    func repairItems(automatic: Bool) -> [StudioProblem.Item] {
        var items: [StudioProblem.Item] = []
        if let wall = signInWall {
            items.append(StudioProblem.Item(kind: .signInRedirect, key: wall, text: "The application sent the page to its sign-in page (\(wall))"))
        }
        let unresolved = session.dependencies.filter { $0.mode == .unresolved }
        if !unresolved.isEmpty {
            items.append(StudioProblem.Item(kind: .missingRule, key: "requests without a rule",
                                            text: "\(unresolved.count) request\(unresolved.count == 1 ? "" : "s") without a simulation rule"))
        }
        for error in fixableErrors {
            items.append(StudioProblem.Item(kind: .dataError, key: error.key, text: error.key))
        }
        return StudioProblem.ordered(items).filter { item in
            repairLedger.mayRun(StudioRepairLedger.identity(kind: item.kind, scenario: session.scenario.id, key: item.key), automatic: automatic)
        }
    }

    /// The error keys of the scenario's page errors Fix can still be offered for (a row of an earlier page keeps its action).
    var fixableKeys: Set<String> {
        Set(session.events.filter { $0.scenarioID == session.scenario.id && StudioDataFix.isFixable(kind: $0.kind, detail: $0.detail) }
            .map { StudioDataFix.key(of: $0.detail) })
    }

    /// The page errors of this scenario the assistant judged not caused by data.
    var notDataKeys: Set<String> { repairLedger.notDataKeys(scenario: session.scenario.id) }

    // MARK: - On the person's click

    /// Fix problems (the Log): every repairable problem of the page, in turn, one assistant run at a time. The list is read again after
    /// each repair, since a sign-in or a rule changes what the page reports.
    func fixProblems() {
        guard session.busy == nil else { return }
        guard let first = repairItems(automatic: false).first, let box = startRepair(first, automatic: false) else {
            session.notice = "Nothing on this page is something Studio can repair: code errors and blocked services are only reported."
            return
        }
        Task { [weak self, session] in
            guard let self else { return }
            var tried: Set<String> = [first.id]
            await session.awaitWork()
            if case .cancelled? = finishRepair(first, box: box, automatic: false) { return }
            for _ in 0..<4 {
                guard let item = repairItems(automatic: false).first(where: { !tried.contains($0.id) }) else { break }
                tried.insert(item.id)
                if case .cancelled? = await repair(item, automatic: false) { break }
            }
        }
    }

    /// The action of one problem row. The work starts at once (the busy banner is up when this returns).
    func repairProblem(_ item: StudioProblem.Item) {
        guard let box = startRepair(item, automatic: false) else { return }
        Task { [weak self, session] in
            await self?.session.awaitWork()
            self?.finishRepair(item, box: box, automatic: false)
        }
    }

    // MARK: - By itself

    /// Looks at the page after `delay` seconds, and repairs what it may. Called whenever something may have changed: the end of a
    /// restore, a page error, the end of the map. Calls within the delay make one look.
    func scheduleAutoRepair(delay: TimeInterval = 2) {
        guard session.spec.repairsAutomatically else { return }
        autoRepairTask?.cancel()
        autoRepairTask = Task { [weak self, session] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.runAutomaticRepair()
        }
    }

    private func runAutomaticRepair() async {
        guard session.spec.repairsAutomatically, session.isSettled, let item = repairItems(automatic: true).first else { return }
        if await repair(item, automatic: true) != nil { scheduleAutoRepair(delay: 3) }
    }

    // MARK: - One repair

    /// Repairs one problem. Returns nil when nothing was done (the ledger or the state did not allow it).
    @discardableResult
    func repair(_ item: StudioProblem.Item, automatic: Bool) async -> StudioFixResult? {
        guard let box = startRepair(item, automatic: automatic) else { return nil }
        await session.awaitWork()
        return finishRepair(item, box: box, automatic: automatic)
    }

    /// Starts the work of one repair at once, on the main actor, so that the busy banner is up when this returns; nil when the ledger or
    /// the state does not allow it. `finishRepair` records what came of it once the work has ended.
    func startRepair(_ item: StudioProblem.Item, automatic: Bool) -> RepairBox? {
        let identity = StudioRepairLedger.identity(kind: item.kind, scenario: session.scenario.id, key: item.key)
        guard !session.closed, session.busy == nil, repairLedger.mayRun(identity, automatic: automatic) else { return nil }
        let box = RepairBox()
        box.identity = identity
        switch item.kind {
        case .dataError:
            guard let error = fixError(for: item.key) else { return nil }
            session.sessionLog.add(.notice, (automatic ? "Repairing by itself: " : "Repairing: ") + String(item.text.prefix(200)))
            session.runWork("Fixing data") { session in box.result = await self.performDataFix(error) }
        case .missingRule:
            session.sessionLog.add(.notice, (automatic ? "Repairing by itself: " : "Repairing: ") + String(item.text.prefix(200)))
            session.runWork("Preparing the missing rules") { session in box.result = await self.performPrepare() }
        case .signInRedirect:
            session.sessionLog.add(.notice, (automatic ? "Repairing by itself: " : "Repairing: ") + String(item.text.prefix(200)))
            box.historyMark = session.history.last?.id ?? ""
            session.change(Self.signInRequest(wall: item.key, wanted: session.scenario.route))
        case .blockedService, .notData, .noise, .other:
            return nil
        }
        return box
    }

    /// Records what came of a repair that `startRepair` began: the ledger, the Undo, the log.
    @discardableResult
    func finishRepair(_ item: StudioProblem.Item, box: RepairBox, automatic: Bool) -> StudioFixResult? {
        if item.kind == .signInRedirect {
            if let last = session.history.last, last.id != box.historyMark {
                switch last.status {
                case .applied, .kept: box.result = .fixed(nil)
                case .clarification: box.result = .refused("The assistant asked a question instead.")
                default: box.result = .failed("The signed-in scenario was not made.")
                }
            } else {
                box.result = .failed("The signed-in scenario was not made.")
            }
        }
        guard let result = box.result else { return nil }
        let outcome: StudioRepairLedger.Outcome?
        switch result {
        case .fixed(let undo):
            outcome = .fixed
            if var undo {
                undo.automatic = automatic
                undo.errorKey = item.key
                repairUndo = undo
            }
            session.sessionLog.add(.notice, (automatic ? "Repaired by itself: " : "Repaired: ") + String(item.text.prefix(160)))
        case .notData(let why):
            outcome = .notData
            session.sessionLog.add(.notice, "Not caused by data: " + String(why.prefix(300)))
        case .refused: outcome = .refused
        case .failed: outcome = .failed
        case .cancelled: outcome = .refused
        case .dropped: outcome = nil
        }
        if let outcome { repairLedger.record(box.identity, outcome: outcome, automatic: automatic) }
        return result
    }

    /// Prepares the rules for the requests nothing could answer, then loads the page again so that it asks for them. The preparation
    /// has its own deadlines; this waits for it (the person can cancel).
    func performPrepare() async -> StudioFixResult {
        let contracts = session.forgetUnresolvedDependencies()
        guard !contracts.isEmpty else { return .failed("No request is waiting for a rule.") }
        session.showBusyDetail("Preparing rules for \(contracts.count) request\(contracts.count == 1 ? "" : "s") again")
        session.reloadPage()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        _ = try? await session.call("return await window.__markviewStudio.whenIdle(60000, 400);")
        var quiet = 0
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline, !Task.isCancelled, quiet < 3 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            quiet = session.isPreparing ? 0 : quiet + 1
        }
        guard !Task.isCancelled else { return .cancelled }
        session.updateReadiness()
        let still = session.dependencies.filter { $0.mode == .unresolved }.count
        return still == 0 ? .fixed(nil) : .failed("\(still) request\(still == 1 ? "" : "s") still without a rule.")
    }

    /// What the assistant is asked when the application sends the page to its sign-in page: a signed-in scenario, through the same path
    /// as any context change (REQ-010, REQ-013): checked on the page, corrected once, saved, replayed at the next open.
    static func signInRequest(wall: String, wanted: String) -> String {
        "The application sends the page to its sign-in page (\(wall)) because the scenario is not signed in. "
            + "Change only the scenario, not the source code: sign the scenario's simulated test user in by submitting the application's real "
            + "sign-in form in the scenario's restoration steps, with the role the application expects, and end on the page that was wanted "
            + "(\(wanted)) with a screen-specific element from the source as the expectation. The test user and its password are simulated; "
            + "no real account is used."
    }

    // MARK: - Undo

    /// Writes the records of the last fix back as they were, and reloads the page on them.
    func undoRepair() {
        guard let undo = repairUndo, session.busy == nil else { return }
        repairUndo = nil
        if !undo.errorKey.isEmpty {
            // The person rejected this fix: Studio does not make it again by itself (a click still may).
            repairLedger.record(StudioRepairLedger.identity(kind: .dataError, scenario: undo.scenarioID, key: undo.errorKey), outcome: .refused,
                                automatic: false)
        }
        session.runWork("Undoing the fix") { session in
            let own = session.scenario.id == undo.scenarioID ? session.scenario.data : nil
            let reverted = StudioDataFix.revert(undo.applied, spec: session.spec, seed: session.spec.seed, scenarioData: own)
            let swapped = undo.applied.map { change -> StudioDataFix.Applied in
                var back = change
                back.old = change.new
                back.new = change.old
                return back
            }
            let outcome = StudioDataFix.Outcome(seed: reverted.seed, scenarioData: reverted.scenarioData, applied: swapped, problems: [])
            _ = await self.commitDataFix(outcome, error: nil, undoing: true)
        }
    }

    func dismissRepairNotice() { repairUndo = nil }

    init(session: StudioSession) {
        self.session = session
    }
}

/// What the assistant's answer to a data error came to.
private enum DataFixAnswer {
    case notData(StudioDataFix.Plan)
    case corrected(StudioDataFix.Outcome)
}

/// The answer was not a set of corrections; asking again does not change what the assistant meant.
private struct DataFixUnreadable: Error, AIUnrepairable {}

/// The page the answer was about is gone.
private struct DataFixDropped: Error, AIUnrepairable {}

/// MarkView refused the corrections; the problems go back to the assistant once.
private struct DataFixRefused: Error {
    let problems: [String]
}
