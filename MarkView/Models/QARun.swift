import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-003 and REQ-005): the outcome of each selected branch and the rules that decide it.
// Foundation only; checked on its own by tools/tests/qa-tests.sh.

/// What happened to one selected branch. Failed, blocked and interrupted are distinct (DEC-010); a branch whose condition could not be
/// established is not executed and is reported as uncovered (DEC-011).
/// A point in the original branch: earlier steps are skipped, never silently marked as met.
struct QAStartPoint: Codable, Equatable {
    var branch: String
    var node: String
}

enum QAOutcome: String, Codable, CaseIterable {
    /// Every step and check held.
    case passed
    /// A check did not hold.
    case failed
    /// The check could not go on: its baseline, its application or a step could not be brought about.
    case blocked
    /// The check was stopped before it reached a verdict.
    case interrupted
    /// The branch's condition was not achieved, so the branch was not executed.
    case uncovered

    /// A check is completed when it reached a verdict about the product. A blocked branch (baseline or launch failure) is not.
    var isCompleted: Bool { self == .passed || self == .failed }

    /// Failed, blocked and interrupted checks each get a bug report, even when the cause is not a product defect (DEC-010).
    var createsBug: Bool { self == .failed || self == .blocked || self == .interrupted }

    /// The words that open the title of the bug made for this outcome; nil where no bug is made.
    var bugTitlePrefix: String? {
        switch self {
        case .failed: return "QA failed"
        case .blocked: return "QA blocked"
        case .interrupted: return "QA interrupted"
        case .passed, .uncovered: return nil
        }
    }

    var label: String {
        switch self {
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        case .interrupted: return "Interrupted"
        case .uncovered: return "Uncovered"
        }
    }
}

enum QABlockReason: String, Codable {
    case baselineNotEstablished
    case launchFailed
    case secondInstanceRefused
    case loginFailed
    case permissionMissing
    case approvalMissing
    case elementNotFound
    /// Only in run records written before 5.61.0, when a step had a fixed budget of 12 actions.
    case stepBudgetExhausted
    /// The assistant chose the same action again and again on a page that did not change.
    case stepStuck
    case other
}

enum QAInterruption: String, Codable {
    case stoppedByUser
    case applicationCrashed
    case permissionRevoked
    case other
}

struct QACheckVerdict: Codable, Equatable {
    var outcome: QAOutcome
    var reason: String
    /// The step the verdict is about, when there is one.
    var node: String? = nil
    var blockReason: QABlockReason? = nil
    var interruption: QAInterruption? = nil
}

enum QACheckPhase: String, Codable {
    /// The prepared baseline (and, for a native check, the launch of the application) is being established.
    case baseline
    /// The branch's condition is being established and verified.
    case condition
    case execution
    case finished
}

enum QACheckEvent: Equatable {
    case baselineEstablished
    case baselineFailed(QABlockReason, String)
    case conditionVerified
    case conditionNotAchieved(String)
    /// A step was done, or a check held.
    case nodeMet(String)
    case checkNotMet(String, String)
    case cannotProceed(String, QABlockReason, String)
    case interrupted(QAInterruption, String)
    case allNodesDone
}

/// The life of one check. A check is executed only after its baseline is established and, when the branch has a condition, after the
/// condition is verified; the first verdict is final. Events that do not fit the phase are kept in `ignored`, never acted on, so a
/// check cannot pass without a baseline or past a condition that was not achieved.
struct QACheckMachine {
    let conditionRequired: Bool
    private(set) var phase: QACheckPhase = .baseline
    private(set) var verdict: QACheckVerdict?
    private(set) var nodesMet: [String] = []
    private(set) var ignored: [QACheckEvent] = []

    init(conditionRequired: Bool) { self.conditionRequired = conditionRequired }

    mutating func apply(_ event: QACheckEvent) {
        guard verdict == nil else { ignored.append(event); return }
        if case .interrupted(let kind, let message) = event {
            finish(QACheckVerdict(outcome: .interrupted, reason: message, interruption: kind))
            return
        }
        switch (phase, event) {
        case (.baseline, .baselineEstablished):
            phase = conditionRequired ? .condition : .execution
        case (.baseline, .baselineFailed(let reason, let message)):
            finish(QACheckVerdict(outcome: .blocked, reason: message, blockReason: reason))
        case (.condition, .conditionVerified):
            phase = .execution
        case (.condition, .conditionNotAchieved(let message)), (.execution, .conditionNotAchieved(let message)):
            // An automated condition (a network fault) can only be confirmed once the steps have run: a fault that was never hit
            // leaves the branch uncovered, however the steps went.
            finish(QACheckVerdict(outcome: .uncovered, reason: message))
        case (.execution, .nodeMet(let node)):
            nodesMet.append(node)
        case (.execution, .checkNotMet(let node, let message)):
            finish(QACheckVerdict(outcome: .failed, reason: message, node: node))
        case (.execution, .cannotProceed(let node, let reason, let message)):
            finish(QACheckVerdict(outcome: .blocked, reason: message, node: node, blockReason: reason))
        case (.execution, .allNodesDone):
            finish(QACheckVerdict(outcome: .passed, reason: "Every step and check held."))
        default:
            ignored.append(event)
        }
    }

    private mutating func finish(_ verdict: QACheckVerdict) {
        self.verdict = verdict
        phase = .finished
    }
}

/// What one step cost a person, as the runner counted it (REQ-008).
struct QAStepEffort: Codable, Equatable {
    var node: String
    var actor: String?
    var effort: QAEffort
}

struct QACheckResult: Codable, Equatable, Identifiable {
    var branch: String
    var verdict: QACheckVerdict
    var nodesMet: [String] = []
    var startedAt: Date
    var finishedAt: Date
    /// The whole branch, and each step of it that was started.
    var effort = QAEffort()
    var steps: [QAStepEffort] = []
    var skippedNodes: [String]? = nil
    var id: String { branch }
}

/// One line of what happened, with the second it happened at: the subtitles of the video, the feed of the run view and the report.
struct QATimelineEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case preparation
        case action
        case observation
        case result
    }

    var id: Int
    /// Seconds from the start of the run.
    var time: Double
    var branch: String
    var node: String?
    var actor: String?
    var kind: Kind
    var text: String
}

/// One selected branch in a run's report: its outcome, or nil while it has not been checked.
struct QARunLine: Equatable {
    var branch: String
    var outcome: QAOutcome?
    var reason: String?
}

/// A run of the selected branches of one scenario against one target. Each branch has an outcome of its own (DEC-003).
struct QARunRecord: Codable, Equatable, Identifiable {
    static let currentSchema = 1

    var schema: Int = QARunRecord.currentSchema
    var id: String
    var scenarioID: String
    var targetID: String
    var targetKind: QATargetKind
    var selected: [String]
    var startedAt: Date
    var finishedAt: Date? = nil
    var results: [QACheckResult] = []
    var timeline: [QATimelineEntry] = []
    /// What the review found on the screens of the run: defects become bugs, the rest stays here as suggestions.
    var findings: [QAFinding] = []
    var startPoint: QAStartPoint? = nil

    /// Stores the result of a selected branch. A branch that was not selected, or already has its result, is refused.
    @discardableResult
    mutating func record(_ result: QACheckResult) -> Bool {
        guard selected.contains(result.branch), !results.contains(where: { $0.branch == result.branch }) else { return false }
        results.append(result)
        return true
    }

    /// Every selected branch with its own outcome, in the order they were selected.
    var lines: [QARunLine] {
        selected.map { branch in
            let result = results.first { $0.branch == branch }
            return QARunLine(branch: branch, outcome: result?.verdict.outcome, reason: result?.verdict.reason)
        }
    }

    var isFinished: Bool { selected.allSatisfy { branch in results.contains { $0.branch == branch } } }

    func count(_ outcome: QAOutcome) -> Int { lines.filter { $0.outcome == outcome }.count }

    var pending: Int { lines.filter { $0.outcome == nil }.count }

    /// The results that become bug reports (DEC-010).
    var bugResults: [QACheckResult] { results.filter { $0.verdict.outcome.createsBug } }
}

extension QATriage {
    /// Marks one finding of a run. False when the run has no such finding or the mark is refused.
    @discardableResult
    static func mark(_ record: inout QARunRecord, finding id: String, _ state: QATriageState?, note: String, now: Date) -> Bool {
        guard let index = record.findings.firstIndex(where: { $0.id == id }) else { return false }
        return mark(&record.findings[index], state, note: note, now: now)
    }
}
