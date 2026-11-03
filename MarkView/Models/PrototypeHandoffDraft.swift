import Foundation

/// The hand-off as a draft of a MarkView feature (feature "Prototype and code stay in step", DEC-010, REQ-016 to REQ-018).
///
/// `PrototypeHandoff.Changes` says which screens and components of a prototype differ from its sync baseline. The draft adds what a
/// person needs in order to act on that: for each changed unit a short list of what the code must do, a picture of the unit before and
/// after, and the text of the feature those make. Everything here is plain data and text built from it; the pictures come from
/// `PrototypeScreenshots`, the descriptions from one assistant run per unit (`describeSystem`, `describePrompt`), and writing the feature
/// is `PrototypeFeatureWriter`'s job. The person edits the draft before anything is written.
extension PrototypeHandoff {
    // MARK: - The draft

    /// One picture of a unit.
    enum Shot: Equatable, Sendable {
        /// Not taken yet.
        case pending
        /// Taken: the absolute path of the PNG in the hand-off's scratch folder (outside the project until a feature is created).
        case taken(String)
        /// Not taken, and why (a new unit has no "before", a page that failed to load, a version without files).
        case skipped(String)

        var path: String? { if case .taken(let path) = self { return path } else { return nil } }
    }

    struct Unit: Equatable, Identifiable, Sendable {
        /// The baseline unit: a screen id, a component's source path or "shell".
        var id: String
        var name: String
        var kind: PrototypeBaseline.Unit.Kind
        /// Prototype files changed since the baseline.
        var files: [String]
        /// Source components the changed files reproduce.
        var components: [String]
        /// Source files of this unit that also changed in the code since the baseline: the conflict to reconcile.
        var alsoChangedInCode: [String]
        /// What the code must do to match the prototype, one change per line; the person edits it.
        var changes: [String]
        /// True when an assistant wrote `changes`, false for the fallback made from the review requests.
        var described: Bool
        var before: Shot = .pending
        var after: Shot = .pending
    }

    struct Draft: Equatable, Sendable {
        var title: String
        var prototypeTitle: String
        var prototypeSlug: String
        /// The version the pictures and the files of "after" come from.
        var version: Int
        var baselineVersion: Int
        var units: [Unit]
        /// The review requests since the baseline, oldest first.
        var requests: [PrototypeFiles.Entry]
        var isEmpty: Bool { units.isEmpty }
    }

    /// The draft of `changes`: every changed unit with the fallback description, no pictures yet. nil when there is nothing to hand off.
    static func draft(prototypeTitle: String, slug: String, version: Int, changes: Changes) -> Draft? {
        guard let baseline = changes.baselineVersion, !changes.items.isEmpty else { return nil }
        let requests = changes.history
        let units = changes.items.map { item in
            Unit(id: item.id, name: item.name, kind: item.kind, files: item.files, components: item.components,
                 alsoChangedInCode: item.alsoChangedInCode, changes: fallbackChanges(item, requests: requests), described: false)
        }
        return Draft(title: "Match the code to the \(prototypeTitle) prototype", prototypeTitle: prototypeTitle, prototypeSlug: slug,
                     version: version, baselineVersion: baseline, units: units, requests: requests)
    }

    /// What to say about a unit when no assistant described it: the files that changed and, because the requests cannot be told apart
    /// by unit, every review request since the baseline.
    static func fallbackChanges(_ item: Item, requests: [PrototypeFiles.Entry]) -> [String] {
        var lines = ["Make \(item.name) in the application match the prototype (changed prototype files: \(item.files.joined(separator: ", ")))."]
        for request in requests {
            lines.append("Requested in the prototype (v\(request.version)): \(request.instruction)" +
                         (request.summary.isEmpty ? "" : " Result: \(request.summary)"))
        }
        return lines
    }

    // MARK: - What to render

    /// What `PrototypeScreenshots` must show for a unit: a screen of the plan, an isolated component page, or (nil, nil) for the first
    /// screen, which is how a change of the shell shows. `componentPage` is the isolated page the manifest records for a component.
    static func shotTarget(of unit: Unit, componentPage: String?) -> (screen: String?, page: String?) {
        switch unit.kind {
        case .screen: return (unit.id, nil)
        case .component: return (nil, componentPage)
        case .foundation: return (nil, nil)
        }
    }

    /// The file name of a unit's picture: stable, safe for any unit id, and apart for before and after.
    static func shotFileName(unitID: String, side: String) -> String {
        let safe = unitID.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let squeezed = safe.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let stem = String(squeezed.prefix(60))
        return "\(stem.isEmpty ? "unit" : stem)-\(side).png"
    }

    // MARK: - The feature

    /// The idea of the feature: where it comes from and what to do with it.
    static func featureIdea(_ draft: Draft) -> String {
        var out = "The \"\(draft.prototypeTitle)\" prototype (v\(draft.version)) was changed after it was last synced with the code (v\(draft.baselineVersion)). "
        out += "This feature carries those changes into the application: each requirement is one screen or component, with a picture of it "
        out += "before and after. The prototype is a reconstruction with simulated data, so implement the intent in the application's own "
        out += "components, styles and conventions; do not copy the prototype's markup. When the change is merged, run \"Sync from code\" in "
        out += "Prototype Studio to redraw the prototype from the new code."
        if !draft.requests.isEmpty {
            out += " The requests behind the changes: " + draft.requests.map { "v\($0.version) \"\($0.instruction)\"" }.joined(separator: "; ") + "."
        }
        return out
    }

    static func requirementTitle(_ unit: Unit) -> String {
        switch unit.kind {
        case .screen: return "\(unit.name) matches the prototype"
        case .component: return "\(unit.name) component matches the prototype"
        case .foundation: return "The application shell matches the prototype"
        }
    }

    static func requirementStatement(_ unit: Unit, draft: Draft) -> String {
        var out = "The application shall show \(unit.kind == .foundation ? "its shell" : unit.name) as the \"\(draft.prototypeTitle)\" prototype v\(draft.version) does"
        if !unit.components.isEmpty {
            out += ", in the source \(unit.components.count == 1 ? "component" : "components") " + unit.components.map { "`\($0)`" }.joined(separator: ", ")
        }
        return out + "."
    }

    /// The acceptance criteria of a unit: its changes, then the picture check, then the conflict, if any.
    static func requirementCriteria(_ unit: Unit) -> [String] {
        var out = unit.changes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if unit.after.path != nil { out.append("The result looks like the \"after\" picture of \(unit.name) (same layout, labels and controls).") }
        if !unit.alsoChangedInCode.isEmpty {
            out.append("The source files " + unit.alsoChangedInCode.map { "`\($0)`" }.joined(separator: ", ")
                       + " also changed in the code since the sync; reconcile the two and keep the newer code work.")
        }
        return out
    }

    // MARK: - The brief with the draft

    /// The pictures and the changes of `unit` as lines of a brief.
    static func briefLines(_ unit: Unit) -> String {
        var out = ""
        for line in unit.changes where !line.trimmingCharacters(in: .whitespaces).isEmpty { out += "  - \(line)\n" }
        let shots = [("before", unit.before), ("after", unit.after)].compactMap { name, shot in shot.path.map { "\(name): `\($0)`" } }
        if !shots.isEmpty { out += "  - Pictures: " + shots.joined(separator: ", ") + "\n" }
        return out
    }

    // MARK: - The assistant's description of one unit

    static let describeSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "changes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "where": ["type": "string", "description": "The control, section or area of the screen, as the person sees it."],
                        "what": ["type": "string", "description": "What is different in the prototype and what the application must do to match it."],
                        "check": ["type": "string", "description": "How to see that it is right, in one sentence."]
                    ],
                    "required": ["where", "what", "check"],
                    "additionalProperties": false
                ]
            ]
        ],
        "required": ["changes"],
        "additionalProperties": false
    ]

    static let describeSystem = """
    You compare two versions of one screen or component of a web prototype and say what the real application must change to match the newer \
    one. The prototype is a reconstruction of an application made of plain HTML and JavaScript with simulated data; you describe the \
    interface, never the prototype's markup. Say what a person sees and does: a column added, a button moved, a label renamed, a section \
    removed, a state that behaves differently. Skip what did not change. One entry per visible difference, in the order a person meets \
    them on the screen. `where` names the control or area, `what` says the difference and what the application must do, `check` says how to \
    see it is right. Do not describe styling details that the application's own design system already decides. If nothing visible differs, \
    answer with an empty `changes` list. Write in English. Answer only with the JSON object.
    """

    /// The prompt for one unit. The files and pictures are named by project-relative paths the assistant can read; `diff` is the line
    /// difference of the unit's files, so it can start from what changed.
    static func describePrompt(unit: Unit, draft: Draft, beforeFiles: [String], afterFiles: [String], diff: String) -> String {
        var out = "Prototype: \"\(draft.prototypeTitle)\". \(unit.kind == .foundation ? "The shell (the page frame every screen sits in)" : unit.name) "
        out += "changed between v\(draft.baselineVersion) (the last sync with the code) and v\(draft.version).\n\n"
        if !unit.components.isEmpty { out += "It reproduces the source component(s): \(unit.components.joined(separator: ", ")).\n\n" }
        if !draft.requests.isEmpty {
            out += "What the reviewer asked for since then:\n"
            for request in draft.requests { out += "- v\(request.version): \(request.instruction)\n" }
            out += "\n"
        }
        out += "Files before: " + (beforeFiles.isEmpty ? "none (the unit is new)" : beforeFiles.map { "`\($0)`" }.joined(separator: ", ")) + "\n"
        out += "Files after: " + (afterFiles.isEmpty ? "none (the unit was removed)" : afterFiles.map { "`\($0)`" }.joined(separator: ", ")) + "\n"
        if let before = unit.before.path { out += "Picture before: `\(before)`\n" }
        if let after = unit.after.path { out += "Picture after: `\(after)`\n" }
        out += "\nLine difference (- removed, + added):\n```diff\n\(diff.isEmpty ? "(no textual difference)" : diff)\n```\n"
        out += "\nRead the files and look at the pictures when the difference is not clear from the lines. Answer with the JSON object."
        return out
    }

    /// The change lines of an answer: "Where: what. Check: check." for each entry; nil when the answer is not the expected object.
    static func parseDescription(_ structured: Any?) -> [String]? {
        guard let object = structured as? [String: Any], let items = object["changes"] as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            let place = (item["where"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let what = (item["what"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let check = (item["check"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !what.isEmpty else { return nil }
            return (place.isEmpty ? "" : "\(place): ") + what + (check.isEmpty ? "" : " Check: \(check)")
        }
    }

    // MARK: - The plan for writing the feature

    /// Everything that is written when the person creates the feature, decided here as plain data. `PrototypeFeatureWriter` only applies
    /// it to the feature store, so what is written is checked without one.
    struct FeaturePlan: Equatable, Sendable {
        struct Picture: Equatable, Sendable {
            var unitID: String
            /// "before" or "after".
            var side: String
            var title: String
            /// The PNG in the scratch folder, copied into the feature as a source.
            var file: String
        }

        struct Requirement: Equatable, Sendable {
            var unitID: String
            var title: String
            var statement: String
            /// Never empty: a requirement needs at least one testable criterion.
            var criteria: [String]
        }

        var title: String
        var idea: String
        /// The body of the feature's overview.
        var overview: String
        var provenance: String
        var requirements: [Requirement]
        var pictures: [Picture]
    }

    static func featurePlan(_ draft: Draft) -> FeaturePlan {
        var requirements: [FeaturePlan.Requirement] = []
        var pictures: [FeaturePlan.Picture] = []
        for unit in draft.units {
            var criteria = requirementCriteria(unit)
            if criteria.isEmpty { criteria = ["\(unit.kind == .foundation ? "The application shell" : unit.name) in the application matches the prototype (v\(draft.version))."] }
            requirements.append(.init(unitID: unit.id, title: requirementTitle(unit), statement: requirementStatement(unit, draft: draft), criteria: criteria))
            for (side, shot) in [("before", unit.before), ("after", unit.after)] {
                if let file = shot.path { pictures.append(.init(unitID: unit.id, side: side, title: "\(unit.name) \(side) (prototype v\(side == "before" ? draft.baselineVersion : draft.version))", file: file)) }
            }
        }
        let idea = featureIdea(draft)
        return FeaturePlan(title: draft.title, idea: idea, overview: featureOverview(draft, idea: idea),
                           provenance: "Created from prototype \(draft.prototypeSlug) v\(draft.version)",
                           requirements: requirements, pictures: pictures)
    }

    static func featureOverview(_ draft: Draft, idea: String) -> String {
        var out = "# \(draft.title)\n\n## Idea\n\n\(idea)\n\n## Problem\n\n"
        out += "The prototype shows changes that the application does not have yet. Each changed screen or component below is one requirement.\n\n## Scope\n\n"
        for unit in draft.units {
            out += "- \(unit.name) (\(unit.kind == .foundation ? "shell" : unit.kind.rawValue))"
            if !unit.alsoChangedInCode.isEmpty { out += ": also changed in the code since the sync, reconcile" }
            out += "\n"
        }
        out += "\nNot in scope: the prototype's simulated data and any screen or component that did not change.\n"
        return out
    }

    /// The "Screenshots" section of a requirement: each picture embedded from where the feature keeps it.
    static func screenshotsSection(_ items: [(title: String, link: String)]) -> String {
        guard !items.isEmpty else { return "" }
        return "\n## Screenshots\n\n" + items.map { "**\($0.title)**\n\n![\($0.title)](\($0.link))" }.joined(separator: "\n\n") + "\n"
    }

    // MARK: - The files of a unit

    /// The difference of every file of a unit between two versions, each under its path; `before` and `after` read a file's text by its
    /// path in the site (nil when the version has no such file).
    static func unitDiff(files: [String], before: (String) -> String?, after: (String) -> String?, limit: Int = 24_000) -> String {
        var out = ""
        for file in files.sorted() {
            let old = before(file), new = after(file)
            let body: String
            switch (old, new) {
            case (nil, nil): continue
            case (nil, let new?): body = "(new file)\n" + lineDiff(before: "", after: new, limit: limit / max(1, files.count))
            case (let old?, nil): body = "(removed)\n" + lineDiff(before: old, after: "", limit: limit / max(1, files.count))
            case (let old?, let new?): body = lineDiff(before: old, after: new, limit: limit / max(1, files.count))
            }
            guard !body.isEmpty else { continue }
            out += "--- \(file)\n\(body)"
            if out.count > limit { return String(out.prefix(limit)) + "\n… (cut)" }
        }
        return out
    }

    // MARK: - Line difference

    /// The lines that differ between two texts, as `- removed` and `+ added` with `context` unchanged lines around each change, cut to `limit`
    /// characters. Empty when the texts are equal.
    static func lineDiff(before: String, after: String, context: Int = 2, limit: Int = 12_000) -> String {
        // No text is no lines, not one empty line: a new or removed file differs by its own lines only.
        let old = before.isEmpty ? [] : before.components(separatedBy: "\n"), new = after.isEmpty ? [] : after.components(separatedBy: "\n")
        let difference = new.difference(from: old)
        guard !difference.isEmpty else { return "" }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Walk both sequences together: a line is kept, removed (old only) or added (new only).
        var rows: [(mark: Character, text: String)] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) { rows.append(("-", old[i])); i += 1 }
            else if j < new.count, inserted.contains(j) { rows.append(("+", new[j])); j += 1 }
            else { if j < new.count { rows.append((" ", new[j])) }; i += 1; j += 1 }
        }
        var keep = [Bool](repeating: false, count: rows.count)
        for (index, row) in rows.enumerated() where row.mark != " " {
            for near in max(0, index - context)...min(rows.count - 1, index + context) { keep[near] = true }
        }
        var out = "", gap = false
        for (index, row) in rows.enumerated() {
            if keep[index] {
                if gap { out += "…\n"; gap = false }
                out += "\(row.mark) \(row.text)\n"
                if out.count > limit { return String(out.prefix(limit)) + "\n… (cut)" }
            } else { gap = true }
        }
        return out
    }
}
