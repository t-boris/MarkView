import Foundation

// A managed implementation run (agent-aware-implementation-runs, DEC-027, DEC-029, DEC-030): a Cockpit plan for one feature whose
// implementation steps the planner writes and whose delivery steps MarkView adds from the Definition of Done the person reviewed.
// What the run does next follows evidence: a step whose completion the checkout, GitHub or the run's own results already support is
// skipped, a scheduled "Ask me" action waits for the person, and merge and release wait while a confirmed review finding is
// unresolved for the revision to be delivered. Everything here is a value or a pure function; the probes and the agents live elsewhere.

/// What a step of a managed run is for. Steps the planner writes are `work`; MarkView adds the others.
enum CockpitStepKind: String, Codable, Equatable, Sendable, CaseIterable {
    case work, branch, version, tests, review, fix, reverify, pullRequest, checks, merge, release, checklist, final

    /// An action outside the checkout whose result MarkView reads back from git and GitHub.
    var isExternalDelivery: Bool { [.branch, .pullRequest, .checks, .merge, .release].contains(self) }
    /// An action that delivers the change: it waits while a confirmed review finding is unresolved (REQ-004).
    var isPublishing: Bool { self == .merge || self == .release }
    /// A step that belongs to delivery (shown in the run's delivery status), as opposed to writing the change.
    var isDelivery: Bool { self != .work }
    /// A step that checks the change rather than writing or delivering it: it may not change source or commit, so the reviewer and
    /// the verifiers stay independent of what they check (DEC-036). Every other step may change source and commit on the branch.
    var isVerification: Bool { [.tests, .review, .reverify, .checks, .final].contains(self) }
}

/// The feature a managed run implements and the checklist the person reviewed for it.
struct CockpitFeatureContext: Codable, Equatable {
    var slug: String
    var title: String
    /// The feature folder, relative to the project.
    var folder: String
    /// The branch the work is delivered from.
    var branch: String
    var done: DefinitionOfDone
    /// The checklist items the project's own delivery rules require (`ImplementationDeliveryRules.isMandatory`).
    var mandatory: [String]
    /// Where the checklist and the project's rules disagree; the person reconciles them before approval.
    var conflicts: [DeliveryConflict] = []
    /// The person read the conflicts and chose to run with the checklist as it is.
    var conflictsAcknowledged: Bool = false

    static func branch(for slug: String) -> String { "feat/" + slug }
}

/// The person's answer to a scheduled "Ask me" action.
struct CockpitGateDecision: Codable, Equatable, Sendable {
    var stepID: UUID
    var approved: Bool
    var at: Date
}

/// A delivery action MarkView found already done when its step came up, without Cockpit's approval (REQ-002, REQ-004).
struct CockpitExternalCompletion: Codable, Equatable, Sendable {
    var stepID: UUID
    var evidence: String
    var at: Date
}

/// A confirmed finding of the independent review: what it violates, the revision it was found in, and how it was resolved.
struct CockpitReviewFinding: Codable, Equatable, Identifiable, Sendable {
    enum Basis: String, Codable, Sendable { case criterion, rule }
    enum State: String, Codable, Sendable { case open, fixed, accepted }
    struct Acceptance: Codable, Equatable, Sendable {
        var rationale: String
        var revision: String
        var at: Date
    }

    var id: String
    var title: String
    var detail: String
    /// An acceptance criterion of the feature, or a mandatory project rule (DEC-032 decides which may be accepted).
    var basis: Basis
    /// The violated criterion or rule, in its own words.
    var reference: String
    /// The revision the review examined.
    var revision: String
    var state: State = .open
    /// What shows that the fix works, and the revision it was verified at.
    var fixEvidence: String? = nil
    var verifiedRevision: String? = nil
    var acceptance: Acceptance? = nil

    /// Risk acceptance is permitted only for a finding against an acceptance criterion (DEC-032).
    var mayAcceptRisk: Bool { basis == .criterion }

    /// Whether the finding blocks merge and release of `revision`: a fix counts only once verified at that revision, an acceptance only
    /// for that revision (a later revision needs re-verification or a new acceptance).
    func blocks(at revision: String?) -> Bool {
        switch state {
        case .open: return true
        case .fixed: return verifiedRevision == nil || verifiedRevision != revision
        case .accepted: return acceptance == nil || acceptance?.revision != revision
        }
    }
}

/// What a review step reported, before MarkView gives it an id and a revision.
struct CockpitReportedFinding: Codable, Equatable, Sendable {
    var title: String
    var detail: String
    var basis: CockpitReviewFinding.Basis
    var reference: String
}

/// A re-verification of one finding at the checkout's current revision.
struct CockpitFindingCheck: Codable, Equatable, Sendable {
    var id: String
    var fixed: Bool
    var evidence: String
}

/// Work a step handed to its agent's own subagents, as the step accounted for it.
struct CockpitDelegatedWork: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case finished, stopped, outstanding }
    var work: String
    var outcome: Outcome
}

/// A process that may still write to the checkout after its step ended: started under the step's terminal and still alive.
struct CockpitProcessRecord: Codable, Equatable, Hashable, Sendable {
    var pid: Int32
    /// When the process started (seconds since 1970), so a reused process id is not taken for it.
    var started: Double
    var command: String
}

/// What a managed run keeps besides the Cockpit's own record.
struct CockpitManagedState: Codable, Equatable {
    var decisions: [CockpitGateDecision] = []
    var findings: [CockpitReviewFinding] = []
    var external: [CockpitExternalCompletion] = []
    /// Processes of an interrupted or ended step not yet confirmed stopped: they block a retry (REQ-003).
    var delegates: [CockpitProcessRecord] = []
    /// The checkout's revision when each step last passed, by step id.
    var revisions: [String: String] = [:]
    /// The feature was recorded as started when the first step of the run began (REQ-001).
    var implementationStarted = false

    func decision(for stepID: UUID) -> CockpitGateDecision? { decisions.last { $0.stepID == stepID } }

    mutating func decide(_ stepID: UUID, approved: Bool, at now: Date = Date()) {
        decisions.removeAll { $0.stepID == stepID }
        decisions.append(CockpitGateDecision(stepID: stepID, approved: approved, at: now))
    }

    /// Findings a review step reported are recorded against the revision it examined, numbered on from the run's last one.
    mutating func addFindings(_ reported: [CockpitReportedFinding], revision: String) {
        var next = (findings.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        for item in reported where !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(CockpitReviewFinding(id: "R\(next)", title: item.title, detail: item.detail, basis: item.basis,
                                                 reference: item.reference, revision: revision))
            next += 1
        }
    }

    /// A fix or re-verification step checked findings at `revision`. Only a re-verification makes a fix count (`verified`).
    mutating func apply(_ checks: [CockpitFindingCheck], revision: String, verified: Bool) {
        for check in checks {
            guard let index = findings.firstIndex(where: { $0.id == check.id }) else { continue }
            if check.fixed {
                findings[index].state = .fixed
                findings[index].fixEvidence = check.evidence
                if verified { findings[index].verifiedRevision = revision }
            } else if findings[index].state == .fixed {
                findings[index].state = .open
                findings[index].verifiedRevision = nil
            }
        }
    }

    enum AcceptanceFailure: Error, Equatable { case unknown, notPermitted, noRationale, noRevision }

    /// The person accepted the risk of one finding for one revision (DEC-029, DEC-032).
    mutating func acceptRisk(_ id: String, rationale: String, revision: String?, at now: Date = Date()) throws {
        guard let index = findings.firstIndex(where: { $0.id == id }) else { throw AcceptanceFailure.unknown }
        guard findings[index].mayAcceptRisk else { throw AcceptanceFailure.notPermitted }
        let reason = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw AcceptanceFailure.noRationale }
        guard let revision, !revision.isEmpty else { throw AcceptanceFailure.noRevision }
        findings[index].state = .accepted
        findings[index].acceptance = CockpitReviewFinding.Acceptance(rationale: reason, revision: revision, at: now)
    }

    func blockingFindings(at revision: String?) -> [CockpitReviewFinding] { findings.filter { $0.blocks(at: revision) } }
}

/// What git and GitHub say about the delivery of one branch now.
struct CockpitDeliveryEvidence: Equatable, Sendable {
    struct PullRequest: Equatable, Sendable {
        var number: Int
        var url: String
        /// OPEN, MERGED or CLOSED, as GitHub names them.
        var state: String
        var headSHA: String
        var mergeCommit: String?
    }
    enum Checks: String, Equatable, Sendable { case passed, failed, pending, none }

    var head: String?
    var currentBranch: String?
    var branchExists = false
    /// Whether GitHub answered; without it nothing about pull requests, checks or releases is known.
    var github = false
    var pullRequest: PullRequest?
    /// The checks of the pull request's head commit.
    var checks: Checks = .none
    /// A published release that contains the merge commit.
    var release: String?

    static let unknown = CockpitDeliveryEvidence()
}

/// Whether current evidence supports a step's completion.
enum CockpitStepSupport: Equatable {
    case supported(String)
    case unsupported
    /// The state of an external action cannot be established; it stays pending (REQ-003).
    case uncertain(String)
}

enum CockpitManagedRun {
    /// Whether a step's agent may change source and commit: the steps that write or deliver the change (DEC-036), and the bounded
    /// recovery attempt of any step, which is the repair its verification then checks again (DEC-037).
    static func changesAllowed(for kind: CockpitStepKind, recoveryAttempt: Int?) -> Bool { !kind.isVerification || recoveryAttempt != nil }

    // MARK: Composing the plan

    /// The plan of a managed run: the branch, the planner's implementation steps, then tests, an independent review, fixes and their
    /// re-verification, the version, the pull request, CI, merge, release, the other checklist items and a final verification. An item
    /// set to Skip adds nothing; an item set to Ask me waits for the person; the Require items the agents keep throughout (records,
    /// issues, commits) become instructions of every step and success criteria.
    static func compose(work: [CockpitStep], criteria: [String], feature: CockpitFeatureContext, implementer: String, reviewer: String,
                        delegation: Set<String>) -> (steps: [CockpitStep], criteria: [String]) {
        let done = feature.done
        func mode(_ id: String) -> DoneMode { done.mode(of: id) ?? .skip }
        func item(_ id: String) -> DoneItem? { done.items.first { $0.id == id } }
        let standing = ["records", "issues", "commit"].compactMap(item).filter { $0.mode == .require }
        let standingText = standing.isEmpty ? "" : "\n\nThroughout this step: " + standing.map(\.instruction).joined(separator: " ")
        var steps: [CockpitStep] = []
        func add(_ kind: CockpitStepKind, _ itemID: String?, title: String, agent: String, assignment: String, condition: String,
                 recovery: CockpitStepRecovery? = nil) {
            let asks = itemID.map { mode($0) == .ask } ?? false
            steps.append(CockpitStep(title: title, agent: agent, assignment: assignment + standingText, completionCondition: condition,
                                     isPrerequisite: true, kind: kind, doneItem: itemID, asksFirst: asks ? true : nil, recovery: recovery))
        }
        let branch = feature.branch
        if mode("branch") != .skip {
            add(.branch, "branch", title: "Branch \(branch) from origin/main", agent: implementer,
                assignment: (item("branch")?.instruction ?? "") + " Use the branch \(branch); if it exists already, check it out and keep its commits.",
                condition: "The checkout is on \(branch), which contains origin/main.")
        }
        for var step in work {
            step.kind = .work
            step.assignment += standingText
            if step.delegate == true, !delegation.contains(step.agent) { step.delegate = nil }
            steps.append(step)
        }
        let feature = "the feature in \(feature.folder)"
        if mode("tests") != .skip {
            add(.tests, "tests", title: "Run the tests and the build", agent: implementer,
                assignment: (item("tests")?.instruction ?? "") + " Report the commands you ran and their results as evidence.",
                condition: "The project's automated tests and build pass at the current revision, with the commands and results reported.")
        }
        add(.review, nil, title: "Independent review", agent: reviewer,
            assignment: "Review the changes on \(branch) against origin/main for \(feature): its acceptance criteria and the project's mandatory rules "
                + "(AGENTS.md, CLAUDE.md, the project workflow). Do not change files. Report each confirmed violation in findings, naming the "
                + "violated acceptance criterion or rule (basis \"criterion\" or \"rule\") in its own words. Report passed when the review is complete, "
                + "whether or not it found violations.",
            condition: "Every change was reviewed and every confirmed violation is reported as a finding.")
        add(.fix, nil, title: "Fix the review findings", agent: implementer,
            assignment: "Fix every open review finding listed in the prior results and the run's findings. For each, report a findingChecks entry "
                + "with its id, whether it is fixed and the evidence. If there are none, report passed and say so.",
            condition: "Every open finding is fixed, with evidence, or reported as not fixed.")
        add(.reverify, nil, title: "Verify the changes again", agent: reviewer,
            assignment: "Run the tests again at the current revision and check every review finding of this run again at that revision. Report a "
                + "findingChecks entry for every finding, with whether it is fixed and the evidence.",
            condition: "The tests pass at the current revision and every finding was checked at it.")
        if mode("version") != .skip {
            add(.version, "version", title: "Bump the version", agent: implementer, assignment: item("version")?.instruction ?? "",
                condition: "The version is bumped by the project's rules and committed.")
        }
        if mode("pr") != .skip {
            add(.pullRequest, "pr", title: "Open the pull request", agent: implementer,
                assignment: (item("pr")?.instruction ?? "") + " Use the branch \(branch).",
                condition: "A pull request from \(branch) exists, with a description and a test plan.")
        }
        if mode("ci") != .skip {
            // The step only checks (DEC-036); a failed check is repaired by its bounded recovery, which may write (DEC-037).
            add(.checks, "ci", title: "CI is green", agent: implementer,
                assignment: (item("ci")?.instruction ?? "") + " This step only checks: if a check fails, do not change files in this step; "
                    + "report each failing check (name, link, log excerpt) as the blocker. Cockpit then runs a bounded repair on \(branch) and checks again.",
                condition: "Every check of the pull request's head commit has passed.", recovery: .ciRepair(branch: branch))
        }
        if mode("merge") != .skip {
            add(.merge, "merge", title: "Merge the pull request", agent: implementer, assignment: item("merge")?.instruction ?? "",
                condition: "The pull request is merged and main contains the work.")
        }
        if mode("deploy") != .skip {
            add(.release, "deploy", title: "Build and release", agent: implementer,
                assignment: (item("deploy")?.instruction ?? "") + " Report the release or deployment and its version as evidence.",
                condition: "The release or deployment that contains the merged work exists and its version is reported.")
        }
        let handled: Set<String> = ["branch", "records", "issues", "tests", "commit", "pr", "ci", "merge", "version", "deploy"]
        for other in done.items where !handled.contains(other.id) && other.mode != .skip {
            add(.checklist, other.id, title: other.title.isEmpty ? "Checklist item" : other.title, agent: implementer,
                assignment: other.instruction, condition: "Done as described, with evidence: \(other.title)")
        }
        let required = done.items.filter { $0.mode == .require }.map { "Definition of Done — \($0.title.isEmpty ? $0.instruction : $0.title)" }
        let allCriteria = criteria + required.filter { !criteria.contains($0) }
        add(.final, nil, title: "Verify the delivery", agent: reviewer,
            assignment: "Check every success criterion against the prior results and the project's current state, and report criteriaResults for each.",
            condition: "Every success criterion is evaluated with evidence.")
        return (steps, allCriteria)
    }

    // MARK: Evidence

    /// Whether current evidence supports `step`'s completion: for steps in the checkout, a result of this run at the current revision;
    /// for delivery actions, what git and GitHub say.
    static func support(for step: CockpitStep, feature: CockpitFeatureContext, results: [CockpitRun.StepResult],
                        managed: CockpitManagedState, delivery: CockpitDeliveryEvidence) -> CockpitStepSupport {
        let passed = results.last { $0.stepID == step.id }?.passed == true
        let atHead = passed && delivery.head != nil && managed.revisions[step.id.uuidString] == delivery.head
        switch step.kind ?? .work {
        case .work, .review, .version:
            return passed ? .supported("Passed in this run.") : .unsupported
        case .checklist:
            if managed.decision(for: step.id)?.approved == false { return .supported("Declined by you.") }
            return passed ? .supported("Passed in this run.") : .unsupported
        case .tests, .reverify, .final:
            return atHead ? .supported("Passed at the current revision.") : .unsupported
        case .fix:
            return managed.findings.contains { $0.state == .open } || !passed && results.contains(where: { $0.stepID == step.id }) ? .unsupported
                : .supported(managed.findings.isEmpty ? "No review findings to fix." : "No open review finding.")
        case .branch:
            guard let current = delivery.currentBranch else { return .unsupported }
            return current == feature.branch ? .supported("The checkout is on \(feature.branch).") : .unsupported
        case .pullRequest:
            guard delivery.github else { return .uncertain("GitHub did not answer, so whether the pull request exists is unknown.") }
            guard let pr = delivery.pullRequest, pr.state != "CLOSED" else { return .unsupported }
            return .supported("Pull request #\(pr.number) exists: \(pr.url)")
        case .checks:
            guard delivery.github else { return .uncertain("GitHub did not answer, so the checks are unknown.") }
            guard let pr = delivery.pullRequest, delivery.checks == .passed, pr.headSHA == delivery.head || pr.state == "MERGED" else { return .unsupported }
            return .supported("Every check of \(String(pr.headSHA.prefix(9))) passed (pull request #\(pr.number)).")
        case .merge:
            guard delivery.github else { return .uncertain("GitHub did not answer, so whether the pull request is merged is unknown.") }
            guard let pr = delivery.pullRequest, pr.state == "MERGED" else { return .unsupported }
            return .supported("Pull request #\(pr.number) is merged" + (pr.mergeCommit.map { " as \(String($0.prefix(9)))." } ?? "."))
        case .release:
            if let tag = delivery.release { return .supported("Release \(tag) contains the merged work.") }
            return passed ? .supported("Passed in this run.") : .unsupported
        }
    }

    /// Where a managed run starts or resumes: the first step whose completion current evidence does not support, with the reasons the
    /// steps before it are skipped (DEC-027, over Cockpit DEC-016). An uncertain step is not skipped: it stays pending.
    static func firstUnsupported(plan: CockpitPlan, results: [CockpitRun.StepResult], managed: CockpitManagedState,
                                 delivery: CockpitDeliveryEvidence) -> (index: Int, skipped: [String]) {
        guard let feature = plan.feature else { return (0, []) }
        var skipped: [String] = []
        for (index, step) in plan.steps.enumerated() {
            guard case .supported(let reason) = support(for: step, feature: feature, results: results, managed: managed, delivery: delivery) else {
                return (index, skipped)
            }
            skipped.append("\(index + 1). \(step.title): \(reason)")
        }
        return (plan.steps.count, skipped)
    }

    // MARK: Delivery status

    struct DeliveryLine: Equatable, Identifiable {
        enum State: Equatable { case done(String), external(String), declined(blocking: Bool), blocked(String), running, pending }
        var stepID: UUID
        var title: String
        var state: State
        var id: UUID { stepID }
    }

    /// Which delivery steps completed and which are pending or blocked (REQ-004 partial delivery).
    static func deliveryStatus(_ run: CockpitRun) -> [DeliveryLine] {
        guard let feature = run.plan.feature else { return [] }
        let managed = run.managed ?? CockpitManagedState()
        return run.plan.steps.enumerated().compactMap { index, step in
            guard (step.kind ?? .work).isDelivery, step.kind != .final else { return nil }
            let record = run.steps.indices.contains(index) ? run.steps[index] : nil
            let state: DeliveryLine.State
            if let external = managed.external.last(where: { $0.stepID == step.id }) { state = .external(external.evidence) }
            else if managed.decision(for: step.id)?.approved == false {
                state = .declined(blocking: step.doneItem.map(feature.mandatory.contains) ?? false)
            } else if record?.status == .passed { state = .done(CockpitText.firstLine(record?.detail ?? "")) }
            else if record?.status == .running { state = .running }
            else if record?.status == .failed || record?.status == .interrupted {
                state = .blocked(CockpitText.firstLine(record?.detail ?? "").isEmpty ? "Interrupted." : CockpitText.firstLine(record?.detail ?? ""))
            } else { state = .pending }
            return DeliveryLine(stepID: step.id, title: step.title, state: state)
        }
    }

    /// A managed run reports success only when the stated criteria are met and every mandatory and required delivery action is done.
    static func deliveryComplete(_ run: CockpitRun) -> Bool {
        guard let feature = run.plan.feature else { return true }
        for line in deliveryStatus(run) {
            switch line.state {
            case .done, .external: continue
            case .declined(let blocking):
                let step = run.plan.steps.first { $0.id == line.stepID }
                let required = step?.doneItem.flatMap { feature.done.mode(of: $0) } == .require
                if blocking || required { return false }
            default: return false
            }
        }
        return true
    }

    // MARK: Reports of a step

    /// What a managed step's report changes in the run: findings of a review, checks of a fix or re-verification, the revision it
    /// passed at. Delegated work left outstanding fails the step (REQ-002).
    static func absorb(_ result: inout CockpitHostResult, step: CockpitStep, revision: String?, managed: inout CockpitManagedState,
                       delegationAllowed: Bool) {
        let kind = step.kind ?? .work
        let delegated = result.delegates ?? []
        if !delegated.isEmpty, !delegationAllowed {
            result.passed = false
            result.detail += "\n\nThe step delegated work although delegation was not allowed for it:\n" + delegated.map { "- " + $0.work }.joined(separator: "\n")
        }
        let outstanding = delegated.filter { $0.outcome == .outstanding }
        if !outstanding.isEmpty {
            result.passed = false
            result.detail += "\n\nDelegated work is still outstanding, so the step cannot succeed:\n" + outstanding.map { "- " + $0.work }.joined(separator: "\n")
        }
        let revision = revision ?? ""
        if kind == .review, let reported = result.findings { managed.addFindings(reported, revision: revision) }
        if kind == .fix || kind == .reverify, let checks = result.findingChecks {
            managed.apply(checks, revision: revision, verified: kind == .reverify && result.passed)
        }
        if kind == .reverify, result.passed {
            let unchecked = managed.findings.filter { $0.state != .accepted && $0.verifiedRevision != revision && $0.state != .open }
            if !unchecked.isEmpty {
                result.passed = false
                result.detail += "\n\nThese findings were not checked at the current revision: " + unchecked.map(\.id).joined(separator: ", ")
            }
        }
        if result.passed, !revision.isEmpty { managed.revisions[step.id.uuidString] = revision }
    }
}
