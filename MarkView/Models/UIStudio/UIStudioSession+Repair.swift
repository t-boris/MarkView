import Foundation

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

/// Problems and repair (REQ-019, REQ-020, DEC-013): Studio repairs the page errors it can repair by itself, after the page has
/// settled at open and after later errors, and the same repairs run on the person's click from the Log. What is repairable is
/// decided by fixed rules (UIStudioRepair.swift); the assistant only proposes data, which MarkView checks before it saves anything.
extension StudioSession {
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
        let wanted = URLComponents(string: scenario.route)?.path ?? scenario.route
        guard !StudioLogFormat.isSignInPath(scenario.route), !StudioLogFormat.isSignInPath(wanted) else { return }
        signInWall = route
    }

    /// The problems of the page as it is now that a repair may start for, in the order that helps. For an automatic repair, only those
    /// the ledger still allows.
    func repairItems(automatic: Bool) -> [StudioProblem.Item] {
        var items: [StudioProblem.Item] = []
        if let wall = signInWall {
            items.append(StudioProblem.Item(kind: .signInRedirect, key: wall, text: "The application sent the page to its sign-in page (\(wall))"))
        }
        let unresolved = dependencies.filter { $0.mode == .unresolved }
        if !unresolved.isEmpty {
            items.append(StudioProblem.Item(kind: .missingRule, key: "requests without a rule",
                                            text: "\(unresolved.count) request\(unresolved.count == 1 ? "" : "s") without a simulation rule"))
        }
        for error in fixableErrors {
            items.append(StudioProblem.Item(kind: .dataError, key: error.key, text: error.key))
        }
        return StudioProblem.ordered(items).filter { item in
            repairLedger.mayRun(StudioRepairLedger.identity(kind: item.kind, scenario: scenario.id, key: item.key), automatic: automatic)
        }
    }

    /// The error keys of the scenario's page errors Fix can still be offered for (a row of an earlier page keeps its action).
    var fixableKeys: Set<String> {
        Set(events.filter { $0.scenarioID == scenario.id && StudioDataFix.isFixable(kind: $0.kind, detail: $0.detail) }
            .map { StudioDataFix.key(of: $0.detail) })
    }

    /// The page errors of this scenario the assistant judged not caused by data.
    var notDataKeys: Set<String> { repairLedger.notDataKeys(scenario: scenario.id) }

    // MARK: - On the person's click

    /// Fix problems (the Log): every repairable problem of the page, in turn, one assistant run at a time. The list is read again after
    /// each repair, since a sign-in or a rule changes what the page reports.
    func fixProblems() {
        guard busy == nil else { return }
        guard let first = repairItems(automatic: false).first, let box = startRepair(first, automatic: false) else {
            notice = "Nothing on this page is something Studio can repair: code errors and blocked services are only reported."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var tried: Set<String> = [first.id]
            await awaitWork()
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
        Task { [weak self] in
            await self?.awaitWork()
            self?.finishRepair(item, box: box, automatic: false)
        }
    }

    // MARK: - By itself

    /// Looks at the page after `delay` seconds, and repairs what it may. Called whenever something may have changed: the end of a
    /// restore, a page error, the end of the map. Calls within the delay make one look.
    func scheduleAutoRepair(delay: TimeInterval = 2) {
        guard spec.repairsAutomatically else { return }
        autoRepairTask?.cancel()
        autoRepairTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.runAutomaticRepair()
        }
    }

    private func runAutomaticRepair() async {
        guard spec.repairsAutomatically, isSettled, let item = repairItems(automatic: true).first else { return }
        if await repair(item, automatic: true) != nil { scheduleAutoRepair(delay: 3) }
    }

    // MARK: - One repair

    /// Repairs one problem. Returns nil when nothing was done (the ledger or the state did not allow it).
    @discardableResult
    func repair(_ item: StudioProblem.Item, automatic: Bool) async -> StudioFixResult? {
        guard let box = startRepair(item, automatic: automatic) else { return nil }
        await awaitWork()
        return finishRepair(item, box: box, automatic: automatic)
    }

    /// Starts the work of one repair at once, on the main actor, so that the busy banner is up when this returns; nil when the ledger or
    /// the state does not allow it. `finishRepair` records what came of it once the work has ended.
    func startRepair(_ item: StudioProblem.Item, automatic: Bool) -> RepairBox? {
        let identity = StudioRepairLedger.identity(kind: item.kind, scenario: scenario.id, key: item.key)
        guard !closed, busy == nil, repairLedger.mayRun(identity, automatic: automatic) else { return nil }
        let box = RepairBox()
        box.identity = identity
        switch item.kind {
        case .dataError:
            guard let error = fixError(for: item.key) else { return nil }
            sessionLog.add(.notice, (automatic ? "Repairing by itself: " : "Repairing: ") + String(item.text.prefix(200)))
            runWork("Fixing data") { session in box.result = await session.performDataFix(error) }
        case .missingRule:
            sessionLog.add(.notice, (automatic ? "Repairing by itself: " : "Repairing: ") + String(item.text.prefix(200)))
            runWork("Preparing the missing rules") { session in box.result = await session.performPrepare() }
        case .signInRedirect:
            sessionLog.add(.notice, (automatic ? "Repairing by itself: " : "Repairing: ") + String(item.text.prefix(200)))
            box.historyMark = history.last?.id ?? ""
            change(Self.signInRequest(wall: item.key, wanted: scenario.route))
        case .blockedService, .notData, .noise, .other:
            return nil
        }
        return box
    }

    /// Records what came of a repair that `startRepair` began: the ledger, the Undo, the log.
    @discardableResult
    func finishRepair(_ item: StudioProblem.Item, box: RepairBox, automatic: Bool) -> StudioFixResult? {
        if item.kind == .signInRedirect {
            if let last = history.last, last.id != box.historyMark {
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
            sessionLog.add(.notice, (automatic ? "Repaired by itself: " : "Repaired: ") + String(item.text.prefix(160)))
        case .notData(let why):
            outcome = .notData
            sessionLog.add(.notice, "Not caused by data: " + String(why.prefix(300)))
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
        let contracts = forgetUnresolvedDependencies()
        guard !contracts.isEmpty else { return .failed("No request is waiting for a rule.") }
        showBusyDetail("Preparing rules for \(contracts.count) request\(contracts.count == 1 ? "" : "s") again")
        reloadPage()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        _ = try? await call("return await window.__markviewStudio.whenIdle(60000, 400);")
        var quiet = 0
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline, !Task.isCancelled, quiet < 3 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            quiet = isPreparing ? 0 : quiet + 1
        }
        guard !Task.isCancelled else { return .cancelled }
        updateReadiness()
        let still = dependencies.filter { $0.mode == .unresolved }.count
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
        guard let undo = repairUndo, busy == nil else { return }
        repairUndo = nil
        if !undo.errorKey.isEmpty {
            // The person rejected this fix: Studio does not make it again by itself (a click still may).
            repairLedger.record(StudioRepairLedger.identity(kind: .dataError, scenario: undo.scenarioID, key: undo.errorKey), outcome: .refused,
                                automatic: false)
        }
        runWork("Undoing the fix") { session in
            let own = session.scenario.id == undo.scenarioID ? session.scenario.data : nil
            let reverted = StudioDataFix.revert(undo.applied, spec: session.spec, seed: session.spec.seed, scenarioData: own)
            let swapped = undo.applied.map { change -> StudioDataFix.Applied in
                var back = change
                back.old = change.new
                back.new = change.old
                return back
            }
            let outcome = StudioDataFix.Outcome(seed: reverted.seed, scenarioData: reverted.scenarioData, applied: swapped, problems: [])
            _ = await session.commitDataFix(outcome, error: nil, undoing: true)
        }
    }

    func dismissRepairNotice() { repairUndo = nil }
}
