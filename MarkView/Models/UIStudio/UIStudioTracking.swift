import Foundation

/// The text of the records UI Studio writes for its changes (REQ-012, DEC-008): the conversation's feature, a requirement
/// for each applied change, a fixed bug report for a repair, and the notes that Undo and a switch leave on them. Everything
/// that comes from the person, the assistant, the page or the code is redacted here, before it reaches a record: known
/// secret values, bearer credentials, credential shapes and confidential `name=value` pairs, as the session log does.
struct StudioTrackingText {
    /// What a record says about a change beyond the operation itself.
    struct Facts {
        /// The scenario the change was made and verified in, in words.
        var scenario = ""
        /// The change's pictures as attached to the feature: "Before" or "After", the source's id, and its file relative to
        /// the project root.
        var pictures: [(label: String, source: String, file: String)] = []
        /// The record this one replaces after a switch between requirement and bug.
        var movedFrom: String? = nil
    }

    static let provenance = "Recorded by MarkView UI Studio"
    /// The most characters of a patch a record carries; History keeps the whole patch.
    static let patchLimit = 40_000

    var redactor: StudioRedactor
    /// Hashes of the project's secret values → their names (never the values), as the session log redacts them.
    var hashes: [String: String] = [:]
    /// The day the records are written (YYYY-MM-DD).
    var date: String

    func clean(_ text: String) -> String {
        StudioLogFormat.redact(text.trimmingCharacters(in: .whitespacesAndNewlines), redactor: redactor, hashes: hashes)
    }

    /// The first non-empty line of `text`, redacted, at most `limit` characters.
    func line(_ text: String, limit: Int = 80) -> String {
        let first = clean(text).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard first.count > limit else { return first }
        return String(first.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Text for inline code: redacted, one line, without backticks.
    private func code(_ text: String) -> String {
        "`" + line(text, limit: 300).replacingOccurrences(of: "`", with: "'") + "`"
    }

    // MARK: Feature

    /// The conversation's feature is titled from its first applied change.
    func featureTitle(_ operation: StudioOperation) -> String {
        let request = line(operation.request, limit: 70)
        return "UI Studio: " + (request.isEmpty ? "interface changes" : request)
    }

    func featureOverview(title: String, _ operation: StudioOperation) -> String {
        """
        # \(title)

        ## Idea

        \(clean(operation.request))

        ## UI Studio conversation

        Recorded by MarkView UI Studio from one conversation, started \(date). Every change applied in it is a requirement of \
        this feature; a repair of something broken is a bug report linked to it. Undo marks a record reverted and nothing is \
        deleted. Clear in UI Studio starts the next feature.

        ## Problem

        ## Scope

        """
    }

    // MARK: Requirement

    func requirementTitle(_ operation: StudioOperation) -> String {
        let request = line(operation.request)
        return request.isEmpty ? "Interface change" : request
    }

    /// The statement, the checks as criteria, the request with its element, scope, files, scenario and revisions, the
    /// pictures and the redacted patch.
    func requirementBody(_ operation: StudioOperation, facts: Facts) -> String {
        let statement = clean(operation.summary.isEmpty ? operation.request : operation.summary)
        return "## Statement\n\n\(statement)\n\n## Acceptance Criteria\n\n"
            + criteria(operation, otherwise: "Applied to the project's sources").joined(separator: "\n") + "\n\n"
            + "## UI Studio change\n\n" + details(operation, facts: facts).joined(separator: "\n") + "\n"
            + picturesList(facts) + codeChanges(operation)
    }

    /// A context turn (REQ-013): a new saved scenario, no code.
    func contextTitle(_ operation: StudioOperation) -> String {
        let request = line(operation.request, limit: 70)
        return "Scenario: " + (request.isEmpty ? "view context" : request)
    }

    /// The statement, the checks as criteria, the scenario the turn made with what changed and what could not be done,
    /// the request's facts and the pictures.
    func contextBody(_ operation: StudioOperation, facts: Facts) -> String {
        let said = [operation.summary, operation.answer, operation.request].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        var change: [String] = []
        if let context = operation.context {
            if !context.scenarioName.isEmpty {
                change.append("- New scenario: " + line(context.scenarioName, limit: 120)
                              + (context.previousScenarioName.isEmpty ? "" : ", made from " + line(context.previousScenarioName, limit: 120)))
            }
            change += context.lines.map { "- " + line($0, limit: 300) }
            change += context.unsupported.map { "- Not done: " + line($0, limit: 300) }
        }
        return "## Statement\n\n\(clean(said))\n\n## Acceptance Criteria\n\n"
            + criteria(operation, otherwise: "Saved as a scenario of UI Studio").joined(separator: "\n") + "\n\n"
            + "## UI Studio context change\n\n" + (change + details(operation, facts: facts)).joined(separator: "\n") + "\n"
            + picturesList(facts)
    }

    /// Each check as a criterion, checked when it passed; a failed check says why.
    func criteria(_ operation: StudioOperation, otherwise: String) -> [String] {
        guard !operation.checks.isEmpty else { return ["- [x] " + otherwise] }
        return operation.checks.map { check in
            "- [\(check.passed ? "x" : " ")] " + line(check.name, limit: 200)
                + (check.passed || check.detail.isEmpty ? "" : " (failed: " + line(check.detail, limit: 300) + ")")
        }
    }

    func details(_ operation: StudioOperation, facts: Facts) -> [String] {
        var lines = ["- Request: " + clean(operation.request).replacingOccurrences(of: "\n", with: " ")]
        if !operation.selection.isEmpty { lines.append("- Element: " + code(operation.selection)) }
        if operation.kind == .edit {
            lines.append("- Scope: " + operation.scope.title + (operation.scopeNote.isEmpty ? "" : " — " + line(operation.scopeNote, limit: 300)))
        }
        if !operation.files.isEmpty { lines.append("- Files: " + operation.files.map { code($0.path) }.joined(separator: ", ")) }
        if !facts.scenario.isEmpty { lines.append("- Scenario: " + line(facts.scenario, limit: 200)) }
        if let base = operation.baseRevision {
            lines.append("- Code revision: " + base.label + (operation.finalRevision.map { " → " + $0.label } ?? ""))
        }
        if let kind = operation.changeKind {
            let reason = line(operation.changeReason ?? "", limit: 300)
            lines.append("- Kind: " + kind.rawValue + (reason.isEmpty ? "" : " — " + reason))
        }
        if let moved = facts.movedFrom { lines.append("- Moved from \(moved), switched in UI Studio on \(date)") }
        lines.append("- UI Studio operation: \(operation.id)")
        return lines
    }

    private func picturesList(_ facts: Facts) -> String {
        guard !facts.pictures.isEmpty else { return "" }
        return "\n## Pictures\n\n" + facts.pictures.map { "- \($0.label): \($0.source)" + ($0.file.isEmpty ? "" : " (`\($0.file)`)") }
            .joined(separator: "\n") + "\n"
    }

    /// The patch section of a requirement; empty without a patch.
    func codeChanges(_ operation: StudioOperation) -> String {
        let patch = fencedPatch(operation)
        return patch.isEmpty ? "" : "\n## Code changes\n\n\(patch)\n"
    }

    /// The redacted patch in a fence longer than any backtick run in it, cut at `patchLimit`.
    func fencedPatch(_ operation: StudioOperation) -> String {
        guard !operation.patch.isEmpty else { return "" }
        var patch = clean(operation.patch)
        if patch.count > Self.patchLimit { patch = String(patch.prefix(Self.patchLimit)) + "\n… (cut: UI Studio's History has the whole patch)" }
        let fence = Self.fence(for: patch)
        return "\(fence)diff\n\(patch)\n\(fence)"
    }

    static func fence(for text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    // MARK: Bug

    /// A repair as a fixed bug report linked to the conversation's feature: what was broken is the actual behaviour, the
    /// request the expected one, the fix with its checks and patch, and the pictures linked from `folder`, the bug
    /// reports' folder relative to the project root.
    func bugDraft(_ operation: StudioOperation, feature: String, facts: Facts, reporter: String, folder: String) -> BugReportDraft {
        let request = clean(operation.request)
        let broken = clean(operation.changeReason ?? "")
        let titled = line(broken.isEmpty ? operation.request : broken, limit: 120)
        let title = titled.isEmpty ? "Interface repair" : titled
        let summary = clean(operation.summary)
        var steps: [String] = []
        if !facts.scenario.isEmpty { steps.append("Open the scenario \(line(facts.scenario, limit: 200)) in MarkView UI Studio") }
        if !operation.selection.isEmpty { steps.append("Look at " + code(operation.selection)) }
        var environment = ["MarkView UI Studio"]
        if !facts.scenario.isEmpty { environment.append("scenario " + line(facts.scenario, limit: 200)) }
        if let base = operation.baseRevision { environment.append("code revision " + base.label) }
        let repaired = "Repaired in MarkView UI Studio on \(date)" + (summary.isEmpty ? "." : ": " + summary)
        let fix = (summary.isEmpty ? [] : [summary, ""]) + [details(operation, facts: facts).joined(separator: "\n"), "",
                                                            criteria(operation, otherwise: "Applied to the project's sources").joined(separator: "\n")]
        let pictures = facts.pictures.filter { !$0.file.isEmpty }.map { picture in
            "![\(picture.label) (\(picture.source))](\(Self.link(to: picture.file, from: folder)))"
        }
        var sections: [(String, String)] = [
            ("Summary", (broken.isEmpty ? request : broken) + "\n\n" + repaired),
            ("Steps to reproduce", steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")),
            ("Expected", request),
            ("Actual", broken.isEmpty ? "As the before picture shows." : broken),
            ("Environment", environment.joined(separator: " · ")),
            ("Fix", fix.joined(separator: "\n")),
            ("Code changes", fencedPatch(operation)),
            ("Pictures", pictures.joined(separator: "\n\n")),
        ]
        sections.removeAll { $0.1.isEmpty }
        let body = "# \(title)\n\n" + sections.map { "## \($0.0)\n\n\($0.1)" }.joined(separator: "\n\n")
        return BugReportDraft(title: title, body: body, status: "fixed", severity: "medium", reporter: reporter,
                              provenance: Self.provenance, fields: [(key: "feature", value: feature)])
    }

    /// `file` as a relative link from a record in `folder`; both are relative to the project root.
    static func link(to file: String, from folder: String) -> String {
        let from = folder.split(separator: "/").map(String.init)
        let to = file.split(separator: "/").map(String.init)
        var common = 0
        while common < from.count, common < to.count - 1, from[common] == to[common] { common += 1 }
        let parts = Array(repeating: "..", count: from.count - common) + to[common...]
        return parts.joined(separator: "/").replacingOccurrences(of: " ", with: "%20")
    }

    // MARK: Notes

    /// What Undo appends to the record it marks reverted.
    func revertNote(isBug: Bool, context: Bool = false) -> String {
        if isBug {
            return "\n## Reverted\n\nThe fix was undone in MarkView UI Studio on \(date), so the problem may be back. The report is kept for the record.\n"
        }
        if context {
            return "\n## Reverted\n\nUndo in MarkView UI Studio returned to the scenario this one was made from on \(date); the new scenario "
                + "stays saved. The requirement is kept for the record.\n"
        }
        return "\n## Reverted\n\nThe change was undone in MarkView UI Studio on \(date). The requirement is kept for the record.\n"
    }

    /// What a switch appends to the record it replaces.
    func movedNote(to tracking: StudioOperation.Tracking) -> String {
        "\n## Moved\n\nRecorded as \(tracking.id)" + (tracking.isBug ? "" : " of \(tracking.feature)")
            + " instead, switched in MarkView UI Studio on \(date).\n"
    }

    /// Where a change is recorded, as its turn shows it.
    static func label(_ tracking: StudioOperation.Tracking, reverted: Bool) -> String {
        (tracking.isBug ? "Tracked as \(tracking.id), linked to \(tracking.feature)" : "Tracked as \(tracking.id) of \(tracking.feature)")
            + (reverted ? " · marked reverted" : "")
    }
}
