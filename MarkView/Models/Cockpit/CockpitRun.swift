import Foundation

/// Persisted process state. The executor delivers step results; this value never runs an agent itself.
struct CockpitRun: Codable, Equatable {
    private(set) var id: UUID
    enum Status: String, Codable { case awaitingApproval, running, paused, stopped, finished }
    enum StepStatus: String, Codable { case waiting, running, interrupted, passed, failed, skipped }
    struct StepRecord: Codable, Equatable {
        var stepID: UUID
        var status: StepStatus = .waiting
        var detail: String = ""
        var progress: CockpitProgress? = nil
        /// When the step began and ended. Absent in runs saved before the timeline existed.
        var startedAt: Date? = nil
        var endedAt: Date? = nil
    }
    struct StepResult: Codable, Equatable {
        var plan: CockpitPlan
        var stepID: UUID
        var passed: Bool
        var detail: String
        var build: String
        var scenarioID: String? = nil
        var qaRunID: String? = nil
        var progress: CockpitProgress? = nil
        var interrupted: Bool? = nil
        /// Specific input or decision requested from the person when `passed` is false.
        var neededInput: String? = nil
        /// 1...N when this result came from an authorized bounded recovery attempt of a prerequisite.
        var recoveryAttempt: Int? = nil
        /// True when the step failed and the run went on to the next step (a step that is not a prerequisite, BUG-130).
        var continuedAfterFailure: Bool? = nil
    }
    struct Revision: Codable, Equatable {
        var plan: CockpitPlan
        var approval: CockpitApproval
        var step: Int
        var fingerprint: String
    }

    private(set) var plan: CockpitPlan
    private(set) var status: Status = .awaitingApproval
    private(set) var steps: [StepRecord]
    private(set) var results: [StepResult] = []
    private(set) var currentIndex: Int?
    private(set) var waitingReason = ""
    private(set) var approval: CockpitApproval?
    private(set) var pendingRevision: Revision?
    /// Seconds the run's agents have worked, across interruptions: what the time limit is measured against. Absent in older runs.
    private(set) var activeSeconds: Double? = nil
    /// Fix cycles the run's steps have used: what the fix cycle limit is measured against. Absent in older runs.
    private(set) var fixCyclesUsed: Int? = nil
    /// What the supervisor answered the agents, the latest `CockpitSupervisor.logLimit`. Absent in older runs.
    private(set) var exchanges: [CockpitSupervisorExchange]? = nil
    /// When the run was approved and started; absent in older runs.
    private(set) var startedAt: Date? = nil
    /// The last time the run showed a sign of life: a step began, the agent reported, asked or was refused. What "no report for N minutes" counts from.
    private(set) var lastSignal: Date? = nil
    /// What happened, the latest `CockpitRunEvent.capacity`. Absent in older runs.
    private(set) var events: [CockpitRunEvent]? = nil
    /// What the person switched off on the run screen while the run was going (DEC-028). Absent in older runs and until a lever is used.
    private(set) var switches: CockpitLiveSwitches? = nil
    /// What the person told the supervisor, the latest `CockpitCuratorNote.capacity`. Absent in older runs.
    private(set) var notes: [CockpitCuratorNote]? = nil
    /// The decisions, review findings, external completions and surviving processes of a managed implementation run; nil otherwise.
    private(set) var managed: CockpitManagedState? = nil
    /// Specific input or decision needed from the person while paused on a failed step; absent in older runs.
    private(set) var neededInput: String? = nil
    /// Bounded recovery attempts already run for the current prerequisite failure; absent when none have run.
    private(set) var recoveryAttempts: Int? = nil

    /// Extracts the specific blocker or needed input for the failure banner: explicit `neededInput` first,
    /// then reported progress blockers, then a `"Blocker:"` clause in `detail`.
    static func blockerSummary(detail: String, neededInput: String?, progress: CockpitProgress?) -> String? {
        if let explicit = neededInput?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let blockers = (progress?.blockers ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !blockers.isEmpty { return blockers.joined(separator: "; ") }
        if let range = detail.range(of: "blocker:", options: .caseInsensitive) {
            var tail = String(detail[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let newline = tail.firstIndex(of: "\n") { tail = String(tail[..<newline]).trimmingCharacters(in: .whitespaces) }
            for suffix in [" No project files changed", " No build/check"] {
                if let cut = tail.range(of: suffix, options: .caseInsensitive) {
                    tail = String(tail[..<cut.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if !tail.isEmpty { return tail }
        }
        return nil
    }

    /// What input or decision the currently failed step needs from the person, if known.
    var failedStepNeededInput: String? {
        let index = currentIndex
        let stepID = index.flatMap { steps.indices.contains($0) ? steps[$0].stepID : nil }
        let lastResult = stepID.flatMap { id in results.last { $0.stepID == id && !$0.passed } }
        let progress = index.flatMap { steps.indices.contains($0) ? steps[$0].progress : nil } ?? lastResult?.progress
        return Self.blockerSummary(detail: waitingReason, neededInput: neededInput ?? lastResult?.neededInput, progress: progress)
    }

    /// True when the run is paused specifically because a prerequisite step failed.
    var isPausedOnFailedPrerequisite: Bool {
        guard status == .paused, let index = currentIndex,
              steps.indices.contains(index), plan.steps.indices.contains(index) else { return false }
        return steps[index].status == .failed && plan.steps[index].isPrerequisite
    }

    /// True when a prerequisite step with `stepID` has a passing non-recovery result in this run.
    func hasPassedPrerequisite(stepID: UUID) -> Bool {
        results.contains { $0.stepID == stepID && $0.passed && $0.recoveryAttempt == nil }
    }

    /// Non-nil when starting a same-run revision at `index` would skip an unpassed prerequisite while paused on a failed prerequisite.
    func revisionPrerequisiteBlocker(plan candidate: CockpitPlan, startingAt index: Int) -> String? {
        guard isPausedOnFailedPrerequisite else { return nil }
        for prior in 0..<min(max(0, index), candidate.steps.count) where candidate.steps[prior].isPrerequisite {
            if !hasPassedPrerequisite(stepID: candidate.steps[prior].id) {
                let title = candidate.steps[prior].title
                return "Step \(prior + 1) (\u{201C}\(title)\u{201D}) is a prerequisite that has not passed yet. Start from step \(prior + 1) or earlier, or turn off its prerequisite requirement."
            }
        }
        return nil
    }

    /// When the run began, or its first event for a run saved before the start time was kept.
    var began: Date? { startedAt ?? events?.first?.at }
    /// The latest time anything is known to have happened in the run.
    var lastKnownActivity: Date? { [lastSignal, events?.last?.at].compactMap { $0 }.max() }

    init(plan: CockpitPlan) {
        id = UUID()
        self.plan = plan
        steps = plan.steps.map { StepRecord(stepID: $0.id) }
    }

    /// Adds one event to the timeline. `signal` marks it as a sign that the agent is alive.
    private mutating func log(_ kind: CockpitRunEvent.Kind, stepID: String?, _ text: String = "", at now: Date, signal: Bool = false) {
        events = CockpitRunEvent.appending(CockpitRunEvent(at: now, kind: kind, stepID: stepID, text: text), to: events ?? [])
        if signal { lastSignal = now }
    }

    private mutating func log(_ kind: CockpitRunEvent.Kind, step index: Int?, _ text: String = "", at now: Date, signal: Bool = false) {
        log(kind, stepID: index.flatMap { steps.indices.contains($0) ? steps[$0].stepID.uuidString : nil }, text, at: now, signal: signal)
    }

    /// Step `index` begins now.
    private mutating func began(_ index: Int, at now: Date) {
        guard steps.indices.contains(index) else { return }
        steps[index].startedAt = now
        steps[index].endedAt = nil
        let title = plan.steps.indices.contains(index) ? plan.steps[index].title : ""
        log(.stepStarted, step: index, "Step \(index + 1) of \(steps.count): \(title)", at: now, signal: true)
    }

    mutating func start(approval: CockpitApproval, at index: Int, now: Date = Date()) -> Bool {
        guard status == .awaitingApproval || status == .stopped || status == .finished,
              approval.permits(plan), steps.indices.contains(index) else { return false }
        self.approval = approval
        for i in steps.indices { steps[i] = StepRecord(stepID: plan.steps[i].id, status: i < index ? .skipped : .waiting) }
        currentIndex = index; steps[index].status = .running; waitingReason = ""; neededInput = nil; recoveryAttempts = nil; status = .running
        startedAt = now
        log(.started, step: nil, index == 0 ? "The run was approved and started." : "The run was approved and started at step \(index + 1).", at: now)
        began(index, at: now)
        return true
    }

    /// A failed prerequisite never advances; if bounded recovery is authorized in the approved plan it stays running until recovery
    /// finishes, otherwise the run pauses so the user can respond, revise the plan, or retry. A failed step that is not a prerequisite
    /// pauses too, unless the workflow went on past it (`continuedAfterFailure`, BUG-130): then the failure is recorded and the next
    /// step begins.
    mutating func completeCurrent(passed: Bool, detail: String, build: String, scenarioID: String? = nil, qaRunID: String? = nil, progress: CockpitProgress? = nil, neededInput: String? = nil, recoveryAttempt: Int? = nil, continuedAfterFailure: Bool = false, now: Date = Date()) -> Bool {
        guard status == .running, let index = currentIndex, steps.indices.contains(index), steps[index].status == .running else { return false }
        let normalizedNeeded = neededInput?.trimmingCharacters(in: .whitespacesAndNewlines)
        var keptNeeded = (normalizedNeeded?.isEmpty ?? true) ? nil : normalizedNeeded
        // A CI step that failed where Cockpit may not repair it (Fix bugs is off) hands over the control to change, not only the
        // agent's own words (BUG-129).
        if !passed, plan.steps.indices.contains(index), plan.steps[index].verifiesCI, !plan.allowsRepair(by: switches ?? CockpitLiveSwitches()) {
            keptNeeded = "CI did not pass, and Fix bugs is off, so Cockpit may not change source to repair it. Turn on Fix bugs (Open Plan) and retry this step."
                + (keptNeeded.map { " The agent reported: \($0)" } ?? "")
        }
        let stepPlan = plan.steps.indices.contains(index) ? plan.steps[index] : nil
        // Only the workflow lets a run go on after a failure, and never after a prerequisite or a recovery attempt.
        let goesOn = !passed && continuedAfterFailure && stepPlan.map { !$0.isPrerequisite } == true && recoveryAttempt == nil
        results.append(StepResult(plan: plan, stepID: steps[index].stepID, passed: passed, detail: detail, build: build,
                                  scenarioID: scenarioID, qaRunID: qaRunID, progress: progress,
                                  neededInput: keptNeeded, recoveryAttempt: recoveryAttempt, continuedAfterFailure: goesOn ? true : nil))
        if let attempt = recoveryAttempt {
            recoveryAttempts = attempt
            steps[index].detail = detail
            if passed {
                log(.recovered, step: index, "Recovery attempt \(attempt) passed; re-checking prerequisite.", at: now, signal: true)
            } else {
                steps[index].status = .failed
                steps[index].endedAt = now
                status = .paused
                waitingReason = detail
                if let keptNeeded { self.neededInput = keptNeeded }
                log(.stepFailed, step: index, "Recovery attempt \(attempt) failed: " + CockpitText.firstLine(detail), at: now, signal: true)
            }
            return true
        }
        if goesOn {
            steps[index].status = .failed
            steps[index].detail = detail
            steps[index].endedAt = now
            self.neededInput = nil
            let next = index + 1 < steps.count ? " The run goes on with step \(index + 2)." : ""
            log(.stepFailed, step: index, CockpitText.firstLine(detail) + next, at: now, signal: true)
            advance(after: index, at: now)
        } else if !passed {
            let used = recoveryAttempts ?? 0
            if let recovery = stepPlan?.recovery, stepPlan?.isPrerequisite == true, recovery.isConfigured,
               used < recovery.boundedAttempts, pendingRevision == nil {
                steps[index].detail = detail
                self.neededInput = keptNeeded
                log(.stepFailed, step: index, "Prerequisite failed; attempting recovery (\(used + 1) of \(recovery.boundedAttempts)): " + CockpitText.firstLine(detail), at: now, signal: true)
                return true
            }
            steps[index].status = .failed
            steps[index].detail = detail
            steps[index].endedAt = now
            status = .paused
            waitingReason = detail
            self.neededInput = keptNeeded
            log(.stepFailed, step: index, CockpitText.firstLine(detail), at: now, signal: true)
        } else {
            steps[index].status = .passed
            steps[index].detail = detail
            steps[index].endedAt = now
            recoveryAttempts = nil
            self.neededInput = nil
            log(.stepPassed, step: index, CockpitText.firstLine(detail), at: now, signal: true)
            advance(after: index, at: now)
        }
        return true
    }

    /// The step after `index` begins, or the run finishes and says which steps failed on the way.
    private mutating func advance(after index: Int, at now: Date) {
        if index + 1 < steps.count {
            currentIndex = index + 1; steps[index + 1].status = .running
            began(index + 1, at: now)
            return
        }
        currentIndex = nil; status = .finished
        let failed = failedStepTitles
        log(.finished, step: nil, failed.isEmpty ? "Every step passed."
            : "Finished; \(failed.count) \(failed.count == 1 ? "step" : "steps") failed: " + failed.joined(separator: "; ") + ".", at: now)
    }

    /// The steps of this run that failed and that the run went on past, as "Step N: title", in order.
    var failedStepTitles: [String] {
        steps.indices.filter { steps[$0].status == .failed }.map { index in
            "Step \(index + 1): " + (plan.steps.indices.contains(index) ? plan.steps[index].title : "")
        }
    }

    mutating func retryPrerequisite() -> Bool {
        guard status == .paused, let index = currentIndex, steps.indices.contains(index),
              plan.steps[index].isPrerequisite, steps[index].status == .failed,
              approval?.permits(plan) == true else { return false }
        steps[index].status = .running; waitingReason = ""; neededInput = nil; recoveryAttempts = nil; status = .running
        return true
    }

    /// Retries any failed step on which the run paused (prerequisite or regular).
    mutating func retryFailedStep() -> Bool {
        guard status == .paused, let index = currentIndex, steps.indices.contains(index),
              steps[index].status == .failed, approval?.permits(plan) == true else { return false }
        steps[index].status = .running; waitingReason = ""; neededInput = nil; recoveryAttempts = nil; status = .running
        return true
    }

    /// Pausing requests a safe boundary; an in-flight agent must actually stop before its executor calls this.
    mutating func pauseAtBoundary(reason: String, now: Date = Date()) {
        guard status == .running else { return }
        if let index = currentIndex, steps.indices.contains(index), steps[index].status == .running { steps[index].status = .waiting }
        status = .paused; waitingReason = reason
        log(.paused, step: currentIndex, reason.isEmpty ? "The run was paused." : reason, at: now)
    }

    mutating func resumeAtBoundary(now: Date = Date()) -> Bool {
        guard status == .paused, let index = currentIndex, steps.indices.contains(index),
              steps[index].status == .waiting, approval?.permits(plan) == true else { return false }
        steps[index].status = .running; status = .running; waitingReason = ""
        log(.resumed, step: index, "The run was resumed.", at: now, signal: true)
        return true
    }

    /// A stop keeps the reason of an interrupted step (a limit that was reached), which the person needs to read afterwards.
    mutating func stop(now: Date = Date()) {
        if status != .stopped { log(.stopped, step: currentIndex, "The run was stopped.", at: now) }
        status = .stopped
        if let index = currentIndex, steps.indices.contains(index), steps[index].status == .interrupted { return }
        waitingReason = ""
    }

    mutating func addExchange(_ exchange: CockpitSupervisorExchange) {
        exchanges = CockpitSupervisor.appending(exchange, to: exchanges ?? [])
        let outcome = exchange.failed ? "no answer" : (exchange.outOfScope ? "outside the plan: " : "") + exchange.answer
        log(.question, stepID: exchange.stepID, "Asked: \(exchange.question) — \(outcome)", at: exchange.asked, signal: true)
    }

    /// The person switched levers on the run screen. Each lever that changed goes on the timeline; nothing here widens the controls
    /// (`CockpitLiveSwitches` can only say "off").
    mutating func setSwitches(_ cuts: CockpitLiveSwitches, now: Date = Date()) {
        let before = switches ?? CockpitLiveSwitches()
        guard before != cuts else { return }
        switches = cuts.isEmpty ? nil : cuts
        for change in CockpitLiveSwitches.changes(from: before, to: cuts) {
            log(.switched, step: currentIndex, change.off ? "\(change.name) was switched off by you." : "\(change.name) was switched back on.", at: now)
        }
    }

    /// The person told the supervisor something, or responded directly to a failed step.
    mutating func addNote(_ note: CockpitCuratorNote) {
        guard !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !(notes ?? []).contains(where: { $0.id == note.id }) else { return }
        notes = CockpitCuratorNote.appending(note, to: notes ?? [])
        let prefix = note.kind == .stepResponse ? "Response for failed step: " : "Note to the supervisor: "
        log(.note, step: currentIndex, prefix + CockpitSupervisor.clip(note.text, to: 120), at: note.at)
    }

    /// The gate refused a tool call of the step's agent. A refusal is also a sign that the agent is working.
    mutating func noteRefusal(_ text: String, now: Date = Date()) {
        guard status == .running else { return }
        log(.refusal, step: currentIndex, text, at: now, signal: true)
    }

    /// The coordinator paused or resumed the run (the person's Pause, a limit). The run's own status follows only at a step's end,
    /// so this is what puts the pause on the timeline.
    mutating func notePauseState(paused: Bool, reason: String, now: Date = Date()) {
        // A failed step already paused the run and said why; only a pause the person or a limit caused is news.
        if paused && status == .paused { return }
        if paused {
            log(.paused, step: currentIndex, reason.isEmpty ? "The run was paused." : reason, at: now)
            return
        }
        // Retrying a failed prerequisite begins it again now, not when its result arrives.
        if let index = currentIndex, steps.indices.contains(index), steps[index].status == .failed {
            steps[index].startedAt = now; steps[index].endedAt = nil
            log(.resumed, step: index, "Retrying the step.", at: now, signal: true)
        } else {
            log(.resumed, step: currentIndex, "The run was resumed.", at: now, signal: true)
        }
    }

    /// A limit stopped the running step.
    mutating func noteLimit(_ text: String, now: Date = Date()) {
        log(.limit, step: currentIndex, text, at: now)
    }

    /// The run showed a sign of life that is not worth an event of its own (the agent called a MarkView tool).
    mutating func noteSignal(at now: Date = Date()) {
        if lastSignal.map({ now > $0 }) ?? true { lastSignal = now }
    }

    mutating func addUsage(seconds: Double, fixCycles: Int) {
        activeSeconds = (activeSeconds ?? 0) + max(0, seconds)
        fixCyclesUsed = (fixCyclesUsed ?? 0) + max(0, fixCycles)
    }

    mutating func recordProgress(_ progress: CockpitProgress, stepID: UUID, now: Date = Date()) -> Bool {
        guard status == .running, let index = currentIndex, steps.indices.contains(index), steps[index].stepID == stepID,
              steps[index].status == .running else { return false }
        let before = steps[index].progress
        steps[index].progress = progress
        lastSignal = now
        if before?.activity != progress.activity || before?.passNumber != progress.passNumber {
            log(.report, step: index, "Pass \(progress.passNumber): \(progress.activity)", at: now, signal: true)
        }
        for bug in progress.bugs where !(before?.bugs.contains(bug) ?? false) { log(.bug, step: index, "Filed \(bug)", at: now, signal: true) }
        for fix in progress.fixes where !(before?.fixes.contains(fix) ?? false) { log(.fix, step: index, "Confirmed fix \(fix)", at: now, signal: true) }
        for blocker in progress.blockers where !(before?.blockers.contains(blocker) ?? false) { log(.report, step: index, "Blocker: \(blocker)", at: now, signal: true) }
        return true
    }

    /// The user explicitly chose a starting point after reviewing an interrupted step's known evidence.
    mutating func continueAfterInterruption(plan newPlan: CockpitPlan, approval: CockpitApproval, at index: Int, now: Date = Date()) -> Bool {
        guard (status == .paused || status == .stopped), let oldIndex = currentIndex, steps.indices.contains(oldIndex), steps[oldIndex].status == .interrupted,
              approval.permits(newPlan), newPlan.steps.indices.contains(index) else { return false }
        let partial = steps[oldIndex]
        results.append(StepResult(plan: plan, stepID: partial.stepID, passed: false,
                                  detail: "Interrupted; effects may be incomplete. " + partial.detail, build: "",
                                  progress: partial.progress, interrupted: true))
        plan = newPlan
        self.approval = approval
        steps = newPlan.steps.enumerated().map { StepRecord(stepID: $0.element.id, status: $0.offset < index ? .skipped : .waiting) }
        currentIndex = index
        steps[index].status = .running
        status = .running
        waitingReason = ""
        neededInput = nil
        recoveryAttempts = nil
        pendingRevision = nil
        log(.recovered, step: index, "Continuing from step \(index + 1) after an interruption.", at: now)
        began(index, at: now)
        return true
    }

    /// A managed run (`plan.feature`) changes its own state: a decision, a finding, an external completion, a process. The timeline
    /// gets `event` when there is one.
    mutating func updateManaged(_ change: (inout CockpitManagedState) -> Void, event: String? = nil, now: Date = Date()) {
        guard plan.feature != nil else { return }
        var state = managed ?? CockpitManagedState()
        change(&state)
        managed = state
        if let event, !event.isEmpty { log(.managed, step: currentIndex, event, at: now) }
    }

    /// Whether the run still holds the project: approved and started, and neither stopped nor finished (REQ-001).
    var isUnfinished: Bool { status == .running || status == .paused }

    /// The person continues a managed run that paused on a failed or interrupted step, from the step evidence selected (DEC-027). The
    /// plan and its approval stay as they were; an interrupted step's partial result is kept, and so are the changes in the checkout.
    mutating func continueManaged(at index: Int, now: Date = Date()) -> Bool {
        guard plan.feature != nil, status == .paused || status == .stopped, let approval, approval.permits(plan),
              steps.indices.contains(index) else { return false }
        if let oldIndex = currentIndex, steps.indices.contains(oldIndex), steps[oldIndex].status == .interrupted {
            let partial = steps[oldIndex]
            results.append(StepResult(plan: plan, stepID: partial.stepID, passed: false,
                                      detail: "Interrupted; effects may be incomplete. " + partial.detail, build: "",
                                      progress: partial.progress, interrupted: true))
        }
        let before = steps
        steps = plan.steps.enumerated().map { offset, step in
            if offset < index { return StepRecord(stepID: step.id, status: before[offset].status == .passed ? .passed : .skipped, detail: before[offset].detail) }
            return StepRecord(stepID: step.id)
        }
        currentIndex = index
        steps[index].status = .running
        status = .running
        waitingReason = ""
        neededInput = nil
        recoveryAttempts = nil
        pendingRevision = nil
        log(.recovered, step: index, "Continuing from step \(index + 1), the first step current evidence does not support.", at: now)
        began(index, at: now)
        return true
    }

    /// The person ends a saved run that no longer runs anywhere (its worker ended with the app), so the project is free for a new one.
    mutating func end(now: Date = Date()) {
        guard isUnfinished else { return }
        if let index = currentIndex, steps.indices.contains(index), steps[index].status == .running { steps[index].status = .interrupted }
        status = .stopped
        log(.stopped, step: currentIndex, "Ended by you.", at: now)
    }

    mutating func discardPendingRevision(reason: String) {
        guard pendingRevision != nil else { return }
        pendingRevision = nil
        waitingReason = reason
    }

    /// Record the person's approved revision before sending it to the coordinator.
    mutating func queueRevision(plan: CockpitPlan, approval: CockpitApproval, at index: Int, fingerprint: String) -> Bool {
        guard pendingRevision == nil, (status == .running || status == .paused), approval.permits(plan), plan.steps.indices.contains(index), !fingerprint.isEmpty,
              revisionPrerequisiteBlocker(plan: plan, startingAt: index) == nil else { return false }
        pendingRevision = Revision(plan: plan, approval: approval, step: index, fingerprint: fingerprint)
        return true
    }

    /// A coordinator may adopt a revision only at a boundary; prior results keep their original plans.
    mutating func applyRevision(fingerprint: String, now: Date = Date()) -> Bool {
        guard let revision = pendingRevision, revision.fingerprint == fingerprint, revision.approval.permits(revision.plan) else { return false }
        plan = revision.plan
        approval = revision.approval
        steps = plan.steps.enumerated().map { StepRecord(stepID: $0.element.id, status: $0.offset < revision.step ? .skipped : .waiting) }
        currentIndex = revision.step
        steps[revision.step].status = .running
        status = .running
        waitingReason = ""
        neededInput = nil
        recoveryAttempts = nil
        pendingRevision = nil
        log(.revised, step: revision.step, "The approved changes were applied from step \(revision.step + 1).", at: now)
        began(revision.step, at: now)
        return true
    }

    /// A process recovered after the app exited must not run by itself. An in-flight step may
    /// have had partial effects, so its outcome remains unknown until recovery is decided.
    /// `reason` replaces the standard text when the step was stopped on purpose, for example because a limit was reached.
    mutating func prepareAfterRestart(reason: String? = nil, now: Date = Date()) {
        guard status == .running else { return }
        if let index = currentIndex, steps.indices.contains(index), steps[index].status == .running {
            steps[index].status = .interrupted
            steps[index].endedAt = now
        }
        status = .paused
        waitingReason = reason ?? "The previous step was interrupted; its outcome is unknown. Separately detached background processes may still be running."
        log(.paused, step: currentIndex, waitingReason, at: now)
    }
}

/// One thing that happened in a run, for its timeline.
struct CockpitRunEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case started, stepStarted, stepPassed, stepFailed, report, question, bug, fix, refusal, limit, paused, resumed, stopped, finished, recovered, revised, switched, note, managed
    }
    var at: Date
    var kind: Kind
    /// The step it belongs to (`CockpitStep.id.uuidString`), or nil for the run as a whole.
    var stepID: String?
    var text: String

    /// A run keeps its latest events, and each is a line, not a document.
    static let capacity = 1_000
    static let textLimit = 300

    static func appending(_ event: CockpitRunEvent, to events: [CockpitRunEvent]) -> [CockpitRunEvent] {
        var event = event
        if event.text.count > textLimit { event.text = String(event.text.prefix(textLimit - 1)) + "…" }
        let next = events + [event]
        return next.count > capacity ? Array(next.suffix(capacity)) : next
    }
}

// MARK: What the person is told, and when

extension CockpitRun {
    /// How long a running step may go without any sign of life before the person is warned.
    static let silenceThreshold: TimeInterval = 20 * 60

    /// How long the running step's agent has been quiet: since its last sign of life, or since the step began when it has shown none.
    /// nil when no step is running. `activity` is a sign of life that was too small to save (a MarkView tool call).
    func quietSeconds(now: Date, activity: Date? = nil) -> TimeInterval? {
        guard status == .running, let index = currentIndex, steps.indices.contains(index), steps[index].status == .running else { return nil }
        guard let since = [lastSignal, activity, steps[index].startedAt].compactMap({ $0 }).max() else { return nil }
        return max(0, now.timeIntervalSince(since))
    }

    /// Whether the silence warning is due: the step has been quiet longer than the threshold.
    func isSilent(now: Date, activity: Date? = nil, threshold: TimeInterval = CockpitRun.silenceThreshold) -> Bool {
        (quietSeconds(now: now, activity: activity) ?? 0) >= threshold
    }
}

/// A macOS notification about a run. `key` identifies the moment, so the same moment is announced once.
struct CockpitNotice: Equatable {
    enum Kind: String { case paused, stepFailed, limit, finished, stopped, silent }
    var kind: Kind
    var title: String
    var body: String
    var key: String

    /// What the person should hear when the run goes from `before` to `after`; nil when nothing needs their attention.
    /// A run seen for the first time (`before` nil) is announced only when it is already waiting for them.
    static func transition(from before: CockpitRun?, to after: CockpitRun, limitReached: Bool = false) -> CockpitNotice? {
        guard before?.status != after.status || before?.results.count != after.results.count else { return nil }
        let name = after.plan.displayTitle
        func notice(_ kind: Kind, _ title: String, _ body: String) -> CockpitNotice {
            CockpitNotice(kind: kind, title: title, body: String(body.prefix(200)), key: "\(after.id.uuidString)/\(kind.rawValue)/\(after.results.count)")
        }
        // A step that failed while the run goes on is announced as it happens (REQ-008, BUG-130).
        if let last = after.results.last, last.continuedAfterFailure == true, after.results.count > (before?.results.count ?? 0),
           let index = after.plan.steps.firstIndex(where: { $0.id == last.stepID }) {
            let goesOn = after.status == .finished ? "The run finished." : "The run goes on."
            return notice(.stepFailed, "A Cockpit step failed", "\(after.plan.steps[index].title): \(CockpitText.firstLine(last.detail)) \(goesOn)")
        }
        switch after.status {
        case .finished where before?.status != .finished:
            let failed = after.failedStepTitles
            return notice(.finished, failed.isEmpty ? "Cockpit run finished" : "Cockpit run finished with failures",
                          failed.isEmpty ? name : "\(name): \(failed.count) \(failed.count == 1 ? "step" : "steps") failed")
        case .paused where before?.status == .running || before == nil:
            if let index = after.currentIndex, after.steps.indices.contains(index), after.steps[index].status == .failed {
                return notice(.stepFailed, "A Cockpit step failed", "\(after.plan.steps[index].title): \(CockpitText.firstLine(after.steps[index].detail))")
            }
            return notice(limitReached ? .limit : .paused, limitReached ? "A Cockpit limit was reached" : "Cockpit run paused", CockpitText.firstLine(after.waitingReason).isEmpty ? name : CockpitText.firstLine(after.waitingReason))
        case .stopped where before?.status == .running:
            return notice(limitReached ? .limit : .stopped, limitReached ? "A Cockpit limit was reached" : "Cockpit run stopped", CockpitText.firstLine(after.waitingReason).isEmpty ? name : CockpitText.firstLine(after.waitingReason))
        default:
            return nil
        }
    }

    /// The warning for a step that has shown no sign of life for `minutes`.
    static func silence(of run: CockpitRun, minutes: Int) -> CockpitNotice? {
        guard run.status == .running, let index = run.currentIndex, run.plan.steps.indices.contains(index) else { return nil }
        return CockpitNotice(kind: .silent, title: "A Cockpit step has gone quiet",
                             body: "\(run.plan.steps[index].title): no report for \(minutes) min. It may be waiting for an answer in its terminal.",
                             key: "\(run.id.uuidString)/silent/\(run.plan.steps[index].id.uuidString)/\(run.results.count)")
    }
}

// MARK: Where a note to the supervisor has got to

extension CockpitRun {
    /// What happened to a note since the person sent it: how many supervisor answers were written after it (each carried it), and the
    /// first step that began after it (its briefing carried it). Both zero/nil means it is still queued.
    struct NoteDelivery: Equatable {
        var answersAfter: Int
        var briefedStep: Int?
        var isQueued: Bool { answersAfter == 0 && briefedStep == nil }
    }

    func delivery(of note: CockpitCuratorNote) -> NoteDelivery {
        let answers = (exchanges ?? []).filter { $0.asked > note.at }.count
        var briefed: Int?
        if let began = (events ?? []).first(where: { $0.kind == .stepStarted && $0.at > note.at }),
           let id = began.stepID, let index = steps.firstIndex(where: { $0.stepID.uuidString == id }) {
            briefed = index + 1
        }
        return NoteDelivery(answersAfter: answers, briefedStep: briefed)
    }
}
