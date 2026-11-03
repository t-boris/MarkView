import Foundation

/// What changed in a prototype made from code since its sync baseline, as a brief for an agent that changes the application
/// code (REQ-012) and as the "changes" section an agent reads through `markview_get_prototype` (REQ-013).
///
/// Nothing here writes to the project (DEC-006, DEC-008): the brief and the section are text built from the baseline status, the
/// prototype's files and its review history. Applying the intent to the real code is the agent's work, under the repository's rules.
enum PrototypeHandoff {
    /// One screen, component or the shell whose prototype files differ from the baseline.
    struct Item: Equatable, Sendable {
        var name: String
        var kind: PrototypeBaseline.Unit.Kind
        /// Prototype files (relative to the site) changed since the baseline.
        var files: [String]
        /// Source components these files reproduce: the markers in them, and the unit's own source for a component.
        var components: [String]
        /// Source files of this unit that also changed in the code since the baseline (a conflict, REQ-011).
        var alsoChangedInCode: [String]
    }

    struct Changes: Equatable, Sendable {
        /// nil when the prototype has no baseline.
        var baselineVersion: Int?
        var items: [Item]
        /// The review requests since the baseline, oldest first, without syncs and version restores.
        var history: [PrototypeFiles.Entry]
        /// Source files changed in the code since the baseline, or removed (everything the units list, and the files no unit lists).
        var codeChanged: [String]
        var hasBaseline: Bool { baselineVersion != nil }
        var isEmpty: Bool { items.isEmpty }
    }

    /// `markers` returns the source components a prototype file marks (`PrototypeFiles.componentMarkers` on its text).
    static func changes(status: PrototypeBaseline.Status, history: [PrototypeFiles.Entry], markers: (String) -> [String]) -> Changes {
        guard let version = status.baselineVersion else {
            return Changes(baselineVersion: nil, items: [], history: [], codeChanged: [])
        }
        var items: [Item] = []
        for unit in status.units where !unit.editedFiles.isEmpty {
            var components: [String] = []
            if unit.unit.kind == .component { components.append(unit.unit.id) }
            for file in unit.editedFiles {
                for path in markers(file) where !components.contains(path) { components.append(path) }
            }
            items.append(Item(name: unit.unit.name, kind: unit.unit.kind, files: unit.editedFiles, components: components,
                              alsoChangedInCode: unit.changedSources))
        }
        let requests = history.filter { entry in
            entry.version > version && !entry.instruction.isEmpty
                && !entry.instruction.hasPrefix("Synced") && !entry.instruction.hasPrefix("Go back")
        }
        let units = status.units.flatMap(\.changedSources)
        let changed = Array(Set(units + status.unclaimed)).sorted()
        return Changes(baselineVersion: version, items: items, history: requests, codeChanged: changed)
    }

    static func kindName(_ kind: PrototypeBaseline.Unit.Kind) -> String {
        switch kind {
        case .screen: return "screen"
        case .component: return "component"
        case .foundation: return "shell"
        }
    }

    /// "Trade (screen): screens/trade.js; reproduces src/Trade.tsx".
    static func line(_ item: Item) -> String {
        var line = "\(item.name) (\(kindName(item.kind))): \(item.files.joined(separator: ", "))"
        if !item.components.isEmpty { line += "; reproduces \(item.components.joined(separator: ", "))" }
        return line
    }

    // MARK: - The section of markview_get_prototype (REQ-013)

    /// "Changes since the last sync": one line when nothing changed or there is no baseline. `componentPaths` are the source
    /// components the result names, so the agent learns whether they changed in the code.
    static func section(_ changes: Changes, componentPaths: [String]) -> String {
        guard let version = changes.baselineVersion else {
            return "Changes since the last sync: unknown. This prototype has no sync baseline (it was saved before syncs were remembered), so what changed in it cannot be told."
        }
        var out = ""
        if changes.isEmpty {
            out += "Changes since the last sync (v\(version)): none. The prototype's files are as they were at the last sync."
        } else {
            out += "Changes since the last sync (v\(version)), prototype files changed and the source components they reproduce:\n"
            out += changes.items.map { "- " + line($0) }.joined(separator: "\n")
            if !changes.history.isEmpty {
                out += "\nReview requests since then:\n"
                out += changes.history.map { "- v\($0.version): \($0.instruction) → \($0.summary)" }.joined(separator: "\n")
            }
        }
        let named = Set(componentPaths)
        let moved = changes.codeChanged.filter { named.contains($0) }
        if named.isEmpty {
            out += "\nSource components changed in the code since the last sync: the prototype records no components."
        } else if moved.isEmpty {
            out += "\nSource components named in this result changed in the code since the last sync: none."
        } else {
            out += "\nSource components named in this result that also changed in the code since the last sync: \(moved.joined(separator: ", "))."
        }
        return out
    }

    // MARK: - The brief (REQ-012)

    /// The brief given to an agent that changes the code. The person reads and edits it before anything is sent.
    static func brief(title: String, reference: String, version: Int, siteRelative: String, changes: Changes) -> String {
        var out = "# Apply prototype changes to the application code\n\n"
        out += "Prototype: \"\(title)\", v\(version), reference \(reference)\n"
        out += "Its files are in `\(siteRelative)/`"
        if let synced = changes.baselineVersion { out += "; it was last synced with the code at v\(synced)" }
        out += ".\n\n"
        out += "The prototype is a RECONSTRUCTION of the application with simulated data, made by an assistant from the code. "
        out += "Do not copy its markup, styles or sample data into the application. Work out what each change means for the real "
        out += "interface and implement that intent in the application's own code, with its own components, styles and conventions.\n\n"
        out += "## What changed in the prototype since the last sync\n\n"
        for item in changes.items {
            out += "- **\(item.name)** (\(kindName(item.kind))): prototype files \(item.files.map { "`\($0)`" }.joined(separator: ", "))"
            if !item.components.isEmpty {
                out += "; reproduces the source \(item.components.count == 1 ? "component" : "components") "
                out += item.components.map { "`\($0)`" }.joined(separator: ", ")
            }
            out += "\n"
        }
        if !changes.history.isEmpty {
            out += "\n## The review requests that led to these changes\n\n"
            for entry in changes.history {
                out += "- v\(entry.version): \(entry.instruction)\n  Result: \(entry.summary)\n"
            }
        }
        let conflicts = changes.items.filter { !$0.alsoChangedInCode.isEmpty }
        if !conflicts.isEmpty {
            out += "\n## Also changed in the code since the last sync\n\n"
            out += "These were edited in the prototype and their source files changed too. Reconcile them with the current code, "
            out += "do not overwrite newer code work:\n"
            for item in conflicts { out += "- \(item.name): \(item.alsoChangedInCode.map { "`\($0)`" }.joined(separator: ", "))\n" }
        }
        out += "\n## How to work\n\n"
        out += "- Read the changed prototype files and the source components above before you change anything; ask if a change is unclear.\n"
        out += "- Follow the repository's own rules (its CLAUDE.md or AGENTS.md): a branch of its own, small commits, the project's build and checks, "
        out += "and a pull request. Prototype Studio has written nothing to the project.\n"
        out += "- When the code change is merged, the person runs \"Sync from code\" in Prototype Studio, which rebuilds only the screens and "
        out += "components whose source files changed and moves the baseline.\n"
        return out
    }
}
