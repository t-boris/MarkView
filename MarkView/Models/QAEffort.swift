import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-008, DEC-021): what a step or a branch cost a person in interactions, as the runner counted it,
// and the findings of the step-by-step review. Foundation only.

/// The interactions a person would need, counted by the runner (never estimated by the assistant).
struct QAEffort: Codable, Equatable {
    var clicks = 0
    var fills = 0
    var scrolls = 0
    var loads = 0
    var keys = 0
    /// How many times the screen changed to a new state.
    var screens = 0
    var milliseconds = 0

    /// Clicks, fills, scrolls, loads and keys: what the person does, not what the page does.
    var interactions: Int { clicks + fills + scrolls + loads + keys }

    static func + (lhs: QAEffort, rhs: QAEffort) -> QAEffort {
        QAEffort(clicks: lhs.clicks + rhs.clicks, fills: lhs.fills + rhs.fills, scrolls: lhs.scrolls + rhs.scrolls, loads: lhs.loads + rhs.loads,
                 keys: lhs.keys + rhs.keys, screens: lhs.screens + rhs.screens, milliseconds: lhs.milliseconds + rhs.milliseconds)
    }
}

enum QAFindingKind: String, Codable, CaseIterable {
    case layout
    case typography
    case missingControl
    case superfluousControl
    case extraStep
    case inconsistency
    case wording
    /// Something that does not work, as opposed to something that could be better.
    case defect
    case other
}

enum QAFindingSeverity: String, Codable, CaseIterable {
    case high
    case medium
    case low
}

/// One thing the review noticed on a screen, with what to do about it.
struct QAFinding: Codable, Equatable, Identifiable {
    var id: String
    /// The step of the scenario the screen belongs to.
    var node: String?
    /// The application the screen belongs to.
    var app: String?
    var kind: QAFindingKind
    var severity: QAFindingSeverity
    var title: String
    var detail: String
    /// A concrete improvement: add, remove or move a control, drop a stage, change a size or a colour.
    var proposal: String
    /// A defect becomes a bug; anything else stays a suggestion in the run report.
    var isDefect: Bool
    /// The picture of the screen, relative to the run's folder.
    var frame: String? = nil
    /// Seconds from the start of the run.
    var time: Double? = nil
}
