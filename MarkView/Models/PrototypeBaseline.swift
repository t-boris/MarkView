import CryptoKit
import Foundation

/// What a prototype made from code remembers about the code it was built from (feature "Prototype and code stay in step", REQ-009, REQ-014).
///
/// At every build and sync a baseline is saved next to the version: a fingerprint of each source file of the reconstruction scope, and for each
/// unit of the prototype (the shell, a screen, a source component) the source files it was built from and the fingerprints of its prototype
/// files. Comparing the baseline with the code and the prototype as they are now says, without an assistant run, whether each unit is in sync,
/// whether the code changed, whether it was edited in Studio, or both. Nothing here reads source text beyond hashing it.
enum PrototypeBaseline {
    // MARK: - Model

    struct Unit: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case foundation, screen, component }
        /// A screen id, the component's source path, or "shell".
        var id: String
        var kind: Kind
        /// What the reviewer reads: a screen name, a component label, "Shell".
        var name: String
        /// Existing project-relative source files this unit was built from.
        var sources: [String]
        /// Prototype files (relative to `site/`) that make the unit, with their fingerprints at the sync.
        var files: [String: String]
        /// The mapping may miss a dependency: the plan named a source that does not exist, or none at all.
        var incomplete = false
    }

    struct Record: Codable, Equatable, Sendable {
        /// The version whose build or sync wrote the fingerprints of the prototype files.
        var syncedVersion: Int
        /// Every file of the reconstruction scope at that moment and every source a unit names, with its fingerprint.
        var scope: [String: String]
        var units: [Unit]
        /// The plan of the build (JSON as the writers saw it), so a unit can be rebuilt without planning the project again (REQ-015).
        var plan: String
        /// The original stylesheets the build copied (project-relative), for a sync that only has to copy them again.
        var styles: [String]
    }

    // MARK: - Fingerprints

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The fingerprint of each readable file of `paths` (project-relative); a missing file is left out.
    static func fingerprints(root: URL, paths: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for path in Set(paths) {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(path)) else { continue }
            out[path] = sha256(data)
        }
        return out
    }

    /// The fingerprint of each text file of the prototype's `site/` except the copied originals and the files MarkView owns. index.html
    /// is hashed as its author wrote it, without the link to the page structure MarkView adds (BUG-060), so linking the structure is
    /// not an edit of the shell.
    static func siteFingerprints(site: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: PrototypeFiles.read(site: site).map { file in
            let authored = file.path == "index.html" ? PrototypeShellStructure.authored(file.content) : file.content
            return (file.path, sha256(Data(authored.utf8)))
        })
    }

    // MARK: - Making a record

    /// The prototype files of a screen unit.
    static func screenFile(_ id: String) -> String { "screens/\(id).js" }
    static let shellFiles = ["index.html", "app.js", "data.js", "styles.css"]

    /// The baseline of a finished build or sync. `screens` are the plan's screens that were written, with the files they were built from; `components` the linked source
    /// components; `scope` the fingerprints of the scope's files; `site` the fingerprints of the prototype now. A named source that is
    /// not a file under `root` is dropped and the unit is marked incomplete (REQ-009).
    static func make(version: Int, plan: String, styles: [String], screens: [(id: String, name: String, sources: [String])],
                     components: [PrototypeFiles.Component], scope: [String: String], site: [String: String],
                     sourceExists: (String) -> Bool) -> Record {
        func owned(_ paths: [String]) -> (sources: [String], incomplete: Bool) {
            var kept: [String] = []
            var dropped = false
            for path in paths {
                if sourceExists(path) { if !kept.contains(path) { kept.append(path) } } else { dropped = true }
            }
            return (kept, dropped || kept.isEmpty)
        }
        func files(_ paths: [String]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: paths.compactMap { path in site[path].map { (path, $0) } })
        }
        var units: [Unit] = []
        let shellSources = owned(styles)
        units.append(Unit(id: "shell", kind: .foundation, name: "Shell", sources: shellSources.sources, files: files(shellFiles),
                          incomplete: false))
        for screen in screens {
            let mapped = owned(screen.sources)
            units.append(Unit(id: screen.id, kind: .screen, name: screen.name, sources: mapped.sources,
                              files: files([screenFile(screen.id)]), incomplete: mapped.incomplete))
        }
        for component in components {
            let mapped = owned([component.path])
            units.append(Unit(id: component.path, kind: .component, name: component.label, sources: mapped.sources,
                              files: files(component.page.map { [$0] } ?? []), incomplete: mapped.incomplete))
        }
        var all = scope
        for unit in units { for path in unit.sources where all[path] == nil { all[path] = "" } }
        return Record(syncedVersion: version, scope: all, units: units, plan: plan, styles: styles)
    }

    // MARK: - Comparing

    struct Diff: Equatable {
        var changed: [String] = []
        var added: [String] = []
        var removed: [String] = []
        var isEmpty: Bool { changed.isEmpty && added.isEmpty && removed.isEmpty }
    }

    /// Files of `current` against `baseline`, sorted. An empty baseline fingerprint is "named but unreadable at the sync".
    static func diff(baseline: [String: String], current: [String: String]) -> Diff {
        var out = Diff()
        for (path, hash) in baseline {
            let now = current[path]
            if hash.isEmpty { if now != nil { out.added.append(path) } }
            else if let now { if now != hash { out.changed.append(path) } }
            else { out.removed.append(path) }
        }
        for path in current.keys where baseline[path] == nil { out.added.append(path) }
        out.changed.sort(); out.added.sort(); out.removed.sort()
        return out
    }

    enum State: String, Equatable, Sendable, CaseIterable {
        case inSync, codeChanged, prototypeEdited, bothChanged, unknown

        var title: String {
            switch self {
            case .inSync: return "In sync"
            case .codeChanged: return "Code changed"
            case .prototypeEdited: return "Prototype edited"
            case .bothChanged: return "Both changed"
            case .unknown: return "Unknown"
            }
        }

        /// What the state means, in words (the reviewer must not have to guess it from a color).
        var meaning: String {
            switch self {
            case .inSync: return "Its source files and its prototype files are as they were at the last sync."
            case .codeChanged: return "A source file it was built from changed after the last sync; the prototype may be out of date."
            case .prototypeEdited: return "Its prototype files were edited in Studio after the last sync; the code does not have these changes."
            case .bothChanged: return "Both the code and the prototype changed after the last sync; a sync would overwrite the prototype edits."
            case .unknown: return "It cannot be told: the prototype has no baseline, or the sources of this unit are not fully known."
            }
        }
    }

    struct UnitStatus: Equatable, Sendable {
        var unit: Unit
        var state: State
        /// Source files of the unit that changed or were removed since the sync.
        var changedSources: [String]
        /// Prototype files of the unit that differ from the sync.
        var editedFiles: [String]

        /// One line: the state and the files behind it.
        var summary: String {
            var parts = [state.title]
            if !changedSources.isEmpty { parts.append("code: " + PrototypeBaseline.list(changedSources)) }
            if !editedFiles.isEmpty { parts.append("prototype: " + PrototypeBaseline.list(editedFiles)) }
            return parts.joined(separator: " · ")
        }
    }

    struct Status: Equatable, Sendable {
        /// nil when the prototype has no baseline (saved before this feature, or a requirements prototype).
        var baselineVersion: Int?
        var units: [UnitStatus]
        /// Changed or removed scope files that no unit claims: the prototype may depend on them, the baseline cannot say.
        var unclaimed: [String]
        /// Scope files that did not exist at the sync.
        var added: [String]
        /// Scope files that existed at the sync and are gone now.
        var removed: [String] = []

        var counts: [State: Int] { units.reduce(into: [:]) { $0[$1.state, default: 0] += 1 } }
        var hasBaseline: Bool { baselineVersion != nil }

        /// "9 in sync, 2 code changed, 1 prototype edited"; the reason when there is no baseline.
        var summary: String {
            guard hasBaseline else { return "No baseline: this prototype was saved before syncs were remembered. Sync from code once to start tracking." }
            let counts = self.counts
            let line = State.allCases.compactMap { state -> String? in
                guard let n = counts[state], n > 0 else { return nil }
                return "\(n) \(state.title.lowercased())"
            }.joined(separator: ", ")
            return line.isEmpty ? "Nothing to compare." : line
        }

        /// Units whose sources changed: what an incremental sync rebuilds.
        var toRebuild: [UnitStatus] { units.filter { $0.state == .codeChanged || $0.state == .bothChanged } }
        /// Units that changed on both sides: a sync would overwrite Studio edits (REQ-011).
        var conflicts: [UnitStatus] { units.filter { $0.state == .bothChanged } }
        /// Nothing changed in the code that the prototype was built from.
        var codeUnchanged: Bool { hasBaseline && toRebuild.isEmpty && unclaimed.isEmpty && added.isEmpty }
    }

    /// The match status of every unit. `scope` is the fingerprints of the scope's files now (the baseline's files and the ones the
    /// inventory lists today), `site` the fingerprints of the prototype's files now.
    static func status(record: Record?, scope: [String: String], site: [String: String]) -> Status {
        guard let record else { return Status(baselineVersion: nil, units: [], unclaimed: [], added: []) }
        let drift = diff(baseline: record.scope, current: scope)
        let changed = Set(drift.changed + drift.removed)
        var claimed = Set<String>()
        var units: [UnitStatus] = []
        for unit in record.units {
            claimed.formUnion(unit.sources)
            let code = unit.sources.filter { changed.contains($0) }
            let edited = unit.files.filter { site[$0.key] != $0.value }.map(\.key).sorted()
            // A unit that lost its prototype file entirely (a component page) counts as edited; one that never had a page cannot.
            let state: State
            switch (!code.isEmpty, !edited.isEmpty) {
            case (true, true): state = .bothChanged
            case (true, false): state = .codeChanged
            case (false, true): state = .prototypeEdited
            case (false, false): state = unit.incomplete ? .unknown : .inSync
            }
            units.append(UnitStatus(unit: unit, state: state, changedSources: code, editedFiles: edited))
        }
        let unclaimed = drift.changed.filter { !claimed.contains($0) } + drift.removed.filter { !claimed.contains($0) }
        return Status(baselineVersion: record.syncedVersion, units: units, unclaimed: unclaimed.sorted(), added: drift.added, removed: drift.removed)
    }

    // MARK: - The plan of a sync (REQ-010, REQ-011, REQ-015)

    struct SyncPlan: Equatable, Sendable {
        enum Mode: Equatable, Sendable {
            /// No file the prototype was built from changed: no run, no new version.
            case nothing
            /// Only the listed units are rebuilt.
            case incremental
            /// The safe wider action; `reasons` say why.
            case full
        }

        var mode: Mode
        /// Screens and components an incremental sync rebuilds, with the files that changed.
        var units: [UnitStatus] = []
        /// Why the sync has to be a full rebuild; names the files or units (REQ-011).
        var reasons: [String] = []
        /// A global stylesheet changed: it is copied again, which needs no assistant.
        var restyle = false
        /// Things the person should know before starting, none of which stops the sync.
        var notes: [String] = []

        /// Units where a rebuild replaces Studio edits (REQ-011).
        var overwrites: [UnitStatus] { units.filter { $0.state == .bothChanged } }
        /// The changed source files the assistant is pointed at.
        var changedSources: [String] { Array(Set(units.flatMap(\.changedSources))).sorted() }
        /// An incremental sync with nothing to rebuild still copies the stylesheets again.
        var isEmptyIncremental: Bool { mode == .incremental && units.isEmpty && !restyle }
    }

    /// What a sync does for `status`. A file used by many screens, a unit whose sources are all gone and a prototype without a
    /// baseline get a full rebuild with the reason; otherwise only the units whose sources changed are rebuilt.
    static func syncPlan(status: Status, record: Record?) -> SyncPlan {
        guard let record, status.hasBaseline else {
            return SyncPlan(mode: .full, reasons: ["There is no baseline to compare with: this prototype was saved before syncs were remembered, so every unit is rebuilt once and the baseline starts from this sync."])
        }
        let screens = record.units.filter { $0.kind == .screen }
        let removed = Set(status.removed)
        let rebuild = status.toRebuild.filter { $0.unit.kind != .foundation }
        let restyle = status.units.contains { $0.unit.kind == .foundation && ($0.state == .codeChanged || $0.state == .bothChanged) }
        var reasons: [String] = []
        for item in rebuild where !item.unit.sources.isEmpty && item.unit.sources.allSatisfy({ removed.contains($0) }) {
            reasons.append("All source files of \"\(item.unit.name)\" were removed (\(list(item.unit.sources))), so it cannot be rebuilt on its own.")
        }
        let threshold = max(3, (screens.count + 1) / 2)
        for file in Set(rebuild.flatMap(\.changedSources)).sorted() {
            let users = screens.filter { $0.sources.contains(file) }
            if users.count >= threshold {
                reasons.append("\(file) changed and \(users.count) of \(screens.count) screens are built from it, so the units that depend on it cannot be told apart.")
            }
        }
        var notes: [String] = []
        if !status.unclaimed.isEmpty {
            notes.append("Changed files that no unit lists, so the prototype may or may not depend on them: " + list(status.unclaimed, limit: 6) + ".")
        }
        if !status.added.isEmpty {
            notes.append("New source files that are not part of the prototype yet: " + list(status.added, limit: 6) + ". \"Rebuild everything\" includes them.")
        }
        if !reasons.isEmpty { return SyncPlan(mode: .full, units: rebuild, reasons: reasons, restyle: restyle, notes: notes) }
        if rebuild.isEmpty && !restyle { return SyncPlan(mode: .nothing, notes: notes) }
        return SyncPlan(mode: .incremental, units: rebuild, restyle: restyle, notes: notes)
    }

    /// The baseline after an incremental sync (REQ-009, REQ-010). `rewritten` are the units whose prototype files the assistant wrote
    /// now: their file fingerprints move. `refreshed` are the units that are current with the code again (the rewritten ones, and the
    /// shell when its stylesheets were copied again): a source file moves to its current fingerprint only when every unit that lists
    /// it is refreshed. Everything else stays as it was, so a unit that failed to rebuild still shows "code changed", a Studio edit that
    /// was not overwritten still shows, and a changed file no unit lists is still reported.
    static func advanced(_ record: Record, version: Int, rewritten: Set<String>, refreshed: Set<String>,
                         scope: [String: String], site: [String: String]) -> Record {
        var next = record
        next.syncedVersion = version
        var claimants: [String: [String]] = [:]
        for unit in record.units { for path in unit.sources { claimants[path, default: []].append(unit.id) } }
        var all = record.scope
        for (path, ids) in claimants where ids.allSatisfy(refreshed.contains) { all[path] = scope[path] ?? "" }
        next.scope = all
        next.units = record.units.map { unit in
            guard rewritten.contains(unit.id) else { return unit }
            var copy = unit
            let paths = Set(unit.files.keys).union(defaultFiles(of: unit))
            copy.files = Dictionary(uniqueKeysWithValues: paths.compactMap { path in site[path].map { (path, $0) } })
            return copy
        }
        return next
    }

    /// The prototype files a unit owns when it had none recorded (a component whose page the sync wrote now).
    static func defaultFiles(of unit: Unit) -> [String] {
        switch unit.kind {
        case .screen: return [screenFile(unit.id)]
        case .foundation: return shellFiles
        case .component: return [PrototypeFiles.componentPage(for: unit.id)]
        }
    }

    /// "a.js, b.js and 3 more".
    static func list(_ paths: [String], limit: Int = 3) -> String {
        guard paths.count > limit else { return paths.joined(separator: ", ") }
        return paths.prefix(limit).joined(separator: ", ") + " and \(paths.count - limit) more"
    }

    // MARK: - Storage

    /// `baselines/v<N>.json` next to the version it belongs to; committed with the project, source text never stored (REQ-009).
    static func url(of folder: URL, version: Int) -> URL {
        folder.appendingPathComponent("baselines/v\(version).json")
    }

    static func load(folder: URL, version: Int) -> Record? {
        guard let data = try? Data(contentsOf: url(of: folder, version: version)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func save(_ record: Record, folder: URL, version: Int) throws {
        let target = url(of: folder, version: version)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: target, options: .atomic)
    }

    /// A review edit makes a new version with the same sources: its baseline is the earlier one, unchanged (REQ-009).
    static func carryForward(folder: URL, from version: Int, to next: Int) {
        guard let record = load(folder: folder, version: version) else { return }
        try? save(record, folder: folder, version: next)
    }
}
