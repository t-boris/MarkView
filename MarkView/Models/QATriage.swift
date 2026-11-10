import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-015): what the person decides about a finding after a run. A defect is confirmed as a bug,
// said not to be one, or said to have a workaround; a suggestion or a note is marked seen or dismissed. The mark lives on the finding in
// the run file and, for a defect, is carried to the bug report QA filed for it (the report in docs/bugs stays the place the bug lives).
// Foundation only; checked on its own by tools/tests/qa-tests.sh and qa-bugs-tests.sh.

enum QATriageState: String, Codable, CaseIterable, Equatable, Sendable {
    case confirmed
    case notABug
    case workaround
    case seen
    case dismissed

    /// How the mark reads next to the finding.
    var title: String {
        switch self {
        case .confirmed: return "Confirmed bug"
        case .notABug: return "Not a bug"
        case .workaround: return "Has a workaround"
        case .seen: return "Seen"
        case .dismissed: return "Dismissed"
        }
    }

    /// The button that sets it.
    var action: String {
        switch self {
        case .confirmed: return "Confirm bug"
        case .notABug: return "Not a bug"
        case .workaround: return "Has a workaround"
        case .seen: return "Mark seen"
        case .dismissed: return "Dismiss"
        }
    }

    /// The mark cannot be set without a note: the workaround is the point of it. Every other mark is one click.
    var needsNote: Bool { self == .workaround }

    var notePrompt: String { self == .workaround ? "What is the workaround?" : "" }
}

enum QATriage {
    /// The marks a finding offers: a defect is about a bug, anything else is read and put aside.
    static func states(for finding: QAFinding) -> [QATriageState] {
        finding.isDefect ? [.confirmed, .notABug, .workaround] : [.seen, .dismissed]
    }

    /// Sets the mark of a finding, or clears it with nil. Returns false and changes nothing for a mark the finding does not offer or a
    /// workaround with no words.
    @discardableResult
    static func mark(_ finding: inout QAFinding, _ state: QATriageState?, note: String, now: Date) -> Bool {
        guard let state else {
            finding.triage = nil
            finding.triageNote = nil
            finding.triagedAt = nil
            return true
        }
        let text = clean(note)
        guard states(for: finding).contains(state), !(state.needsNote && text.isEmpty) else { return false }
        finding.triage = state
        finding.triageNote = state.needsNote ? text : nil
        finding.triagedAt = now
        return true
    }

    /// How many findings nobody has marked yet.
    static func unmarked(_ findings: [QAFinding]) -> Int { findings.filter { $0.triage == nil }.count }

    /// The one line a run list shows: nothing for a run without findings.
    static func summary(_ findings: [QAFinding]) -> String? {
        guard !findings.isEmpty else { return nil }
        let open = unmarked(findings)
        let noun = findings.count == 1 ? "finding" : "findings"
        return open == 0 ? "\(findings.count) \(noun), all marked" : "\(findings.count) \(noun), \(open) not marked"
    }

    /// Single line, at most 400 characters: a note goes into a bug report and the run file.
    static func clean(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return flat.count > 400 ? String(flat.prefix(399)) + "…" : flat
    }
}

/// What a mark does to the bug report filed for the finding.
struct QABugTriageChange: Equatable, Sendable {
    /// The mark itself, written to the report as `qa_triage` so a later change knows what this app did; nil takes it away.
    var mark: QATriageState?
    /// A confirmed bug is ready to fix.
    var readyToFix: Bool
    /// The words of the "Workaround" section; nil removes the section.
    var workaround: String?
    /// Set for "not a bug": the report is closed as invalid with this reason.
    var cancelReason: String?

    static func make(_ state: QATriageState?, note: String) -> QABugTriageChange {
        let text = QATriage.clean(note)
        switch state {
        case .confirmed?: return QABugTriageChange(mark: .confirmed, readyToFix: true, workaround: nil, cancelReason: nil)
        case .workaround?: return QABugTriageChange(mark: .workaround, readyToFix: false, workaround: text, cancelReason: nil)
        case .notABug?: return QABugTriageChange(mark: .notABug, readyToFix: false, workaround: nil, cancelReason: "Marked not a bug after a QA run.")
        case .seen?, .dismissed?, nil: return QABugTriageChange(mark: nil, readyToFix: false, workaround: nil, cancelReason: nil)
        }
    }
}

enum QABugTriageOutcome: Equatable, Sendable {
    /// No report was filed for the finding (a suggestion, or a defect that was not filed): only the finding carries the mark.
    case noReport
    case updated(id: String)
    /// The report exists but could not be changed; `reason` says why.
    case notChanged(id: String, reason: String)
}

enum QABugTriage {
    static let workaroundHeading = "Workaround"

    /// The body of a report with its "Workaround" section set to `text`, or removed for nil or an empty text. The section is the last
    /// one the person reads before the notes of the run, so it is added at the end when it is new.
    static func settingWorkaround(_ text: String?, in body: String) -> String {
        let heading = "## \(workaroundHeading)"
        var lines = body.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) {
            var end = start + 1
            while end < lines.count, !lines[end].hasPrefix("## ") { end += 1 }
            lines.removeSubrange(start..<end)
            while lines.count > start, lines[start].trimmingCharacters(in: .whitespaces).isEmpty, start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.remove(at: start)
            }
        }
        var result = lines.joined(separator: "\n")
        guard let text = text.map(QATriage.clean), !text.isEmpty else { return result }
        while result.hasSuffix("\n\n") { result.removeLast() }
        if !result.hasSuffix("\n") && !result.isEmpty { result += "\n" }
        return result + (result.isEmpty ? "" : "\n") + heading + "\n\n" + text + "\n"
    }
}
