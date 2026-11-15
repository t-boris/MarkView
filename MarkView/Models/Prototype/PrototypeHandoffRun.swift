import Foundation

/// One hand-off of a prototype from code to the code, from the draft to the created feature (feature "Prototype and code stay in step",
/// REQ-016 to REQ-018).
///
/// The run owns the draft the person edits and the work that fills it in: a screenshot of every changed screen before and after
/// (`PrototypeScreenshots`, no assistant) and one short description of what the code must change per unit (`PrototypeAI.describeChange`,
/// bounded in number and in parallelism). Both are best effort: a picture or a description that fails leaves a visible note and the
/// fallback text, and never stops the feature from being created. Everything it makes lives in a scratch folder outside the project until
/// the person presses "Create feature", which copies the pictures into the feature and removes the folder. Closing the run stops its work.
@MainActor
final class PrototypeHandoffRun: ObservableObject {
    struct Context {
        var root: URL
        var folder: URL
        var slug: String
        var title: String
        var version: Int
        var components: [PrototypeFiles.Component]
        var theme: PrototypeScreenshots.Theme?
        var changes: PrototypeHandoff.Changes
        /// The reference an agent can use to find the prototype, and the site folder relative to the project, for the brief.
        var reference: String
        var siteRelative: String
    }

    struct Progress: Equatable {
        var running = false
        var shotsDone = 0
        var shotsTotal = 0
        var describedDone = 0
        var describedTotal = 0
        /// What did not work, in words, oldest first.
        var notes: [String] = []
    }

    /// The most units that are described by the assistant in one hand-off; the rest keep the text made from the review requests.
    static let maxDescribed = 12
    private static let parallelDescriptions = 3

    @Published private(set) var draft: PrototypeHandoff.Draft?
    @Published private(set) var progress = Progress()
    @Published private(set) var creating = false
    @Published private(set) var createFailure: String?
    @Published private(set) var created: PrototypeFeatureWriter.Created?

    let context: Context
    private let record: PrototypeAI.Record
    private let scratch: URL
    /// Units whose text the person edited: a later description never replaces it.
    private var edited: Set<String> = []
    private var task: Task<Void, Never>?
    private var started = false

    init(context: Context, record: @escaping PrototypeAI.Record) {
        self.context = context
        self.record = record
        self.scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MarkView-handoff-" + UUID().uuidString, isDirectory: true)
        self.draft = PrototypeHandoff.draft(prototypeTitle: context.title, slug: context.slug, version: context.version, changes: context.changes)
    }

    // MARK: - The person's edits

    func setTitle(_ title: String) { draft?.title = title }

    /// The text of a unit, one change per line.
    func setChanges(_ text: String, of unitID: String) {
        edited.insert(unitID)
        update(unitID) {
            $0.changes = text.components(separatedBy: "\n")
            $0.described = false
        }
    }

    /// The brief for an agent, from the draft as it stands.
    func brief() -> String {
        PrototypeHandoff.brief(title: context.title, reference: context.reference, version: context.version,
                               siteRelative: context.siteRelative, changes: context.changes, draft: draft)
    }

    // MARK: - Filling the draft in

    /// Takes the pictures and asks for the descriptions. Does nothing when it already ran or runs.
    func start() {
        guard !started, draft != nil else { return }
        started = true
        task = Task { [self] in await work() }
    }

    /// Stops the pictures and descriptions that are still to come; what is done stays.
    func stop() { task?.cancel() }

    /// Stops the work and removes the scratch folder; the run is not used afterwards.
    func close() {
        task?.cancel()
        let folder = scratch
        Task.detached { try? FileManager.default.removeItem(at: folder) }
    }

    private func work() async {
        guard let units = draft?.units, !units.isEmpty else { return }
        progress = Progress(running: true, shotsTotal: units.count * 2, describedTotal: min(units.count, Self.maxDescribed))
        defer { progress.running = false; task = nil }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let renderer = PrototypeScreenshots()
        let versionSite = PrototypeFiles.versionFolder(of: context.folder, draft?.baselineVersion ?? 0)
        let liveSite = PrototypeFiles.site(of: context.folder)
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for (index, unit) in units.enumerated() {
                if Task.isCancelled { break }
                await takeShots(of: unit, renderer: renderer, versionSite: versionSite, liveSite: liveSite)
                guard index < Self.maxDescribed, !Task.isCancelled else { continue }
                if running >= Self.parallelDescriptions { await group.next(); running -= 1 }
                group.addTask { @MainActor [self] in await describe(unit.id, versionSite: versionSite, liveSite: liveSite) }
                running += 1
            }
        }
        if let draft, draft.units.count > Self.maxDescribed {
            note("Only the first \(Self.maxDescribed) of \(draft.units.count) units were described by the assistant; the others keep the text made from the review requests.")
        }
    }

    private func takeShots(of unit: PrototypeHandoff.Unit, renderer: PrototypeScreenshots, versionSite: URL, liveSite: URL) async {
        let page = context.components.first { $0.path == unit.id }?.page
        if unit.kind == .component, page == nil {
            update(unit.id) { $0.before = .skipped("the component has no isolated view"); $0.after = .skipped("the component has no isolated view") }
            progress.shotsDone += 2
            return
        }
        let target = PrototypeHandoff.shotTarget(of: unit, componentPage: page)
        for (side, site) in [("before", versionSite), ("after", liveSite)] {
            if Task.isCancelled { return }
            let shot: PrototypeHandoff.Shot
            do {
                let png = try await renderer.capture(.init(site: site, screen: target.screen, page: target.page), theme: context.theme)
                let file = scratch.appendingPathComponent(PrototypeHandoff.shotFileName(unitID: unit.id, side: side))
                try png.write(to: file)
                shot = .taken(file.path)
            } catch let failure as PrototypeScreenshots.Failure {
                switch failure {
                case .noScreen: shot = .skipped(side == "before" ? "new in the prototype" : "removed from the prototype")
                default:
                    shot = .skipped(failure.localizedDescription)
                    note("\(unit.name) \(side): \(failure.localizedDescription)")
                }
            } catch {
                shot = .skipped(error.localizedDescription)
                note("\(unit.name) \(side): \(error.localizedDescription)")
            }
            update(unit.id) { if side == "before" { $0.before = shot } else { $0.after = shot } }
            progress.shotsDone += 1
        }
    }

    private func describe(_ unitID: String, versionSite: URL, liveSite: URL) async {
        defer { progress.describedDone += 1 }
        guard let draft, let unit = draft.units.first(where: { $0.id == unitID }) else { return }
        let files = unit.files
        let diff = await Task.detached {
            PrototypeHandoff.unitDiff(files: files,
                                      before: { try? String(contentsOf: versionSite.appendingPathComponent($0), encoding: .utf8) },
                                      after: { try? String(contentsOf: liveSite.appendingPathComponent($0), encoding: .utf8) })
        }.value
        do {
            let lines = try await PrototypeAI.describeChange(root: context.root, scratch: scratch, versionSite: versionSite, liveSite: liveSite,
                                                             unit: unit, draft: draft, diff: diff, record: record)
            guard !edited.contains(unitID) else { return }
            if lines.isEmpty {
                note("\(unit.name): the assistant saw no visible difference, so the text made from the review requests stays.")
            } else {
                update(unitID) { $0.changes = lines; $0.described = true }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            note("\(unit.name): no description from the assistant (\(error.localizedDescription)); the review requests are used instead.")
        }
    }

    // MARK: - Creating the feature

    /// Writes the feature into the open project. The pictures are copied from the scratch folder, which is removed afterwards.
    @discardableResult
    func create(into store: FeatureStore) async -> PrototypeFeatureWriter.Created? {
        guard let draft, !creating, !progress.running else { return nil }
        creating = true
        createFailure = nil
        defer { creating = false }
        do {
            let result = try await PrototypeFeatureWriter.write(PrototypeHandoff.featurePlan(draft), into: store)
            created = result
            close()
            return result
        } catch {
            createFailure = error.localizedDescription
            return nil
        }
    }

    // MARK: - Private

    private func update(_ unitID: String, _ change: (inout PrototypeHandoff.Unit) -> Void) {
        guard var current = draft, let index = current.units.firstIndex(where: { $0.id == unitID }) else { return }
        change(&current.units[index])
        draft = current
    }

    private func note(_ text: String) {
        if !progress.notes.contains(text) { progress.notes.append(text) }
    }
}
