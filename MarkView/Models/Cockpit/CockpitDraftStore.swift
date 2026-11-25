import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The Cockpit plan of one feature, prepared from Build and kept until it starts a run (REQ-001, REQ-002): the goal, the checklist the
/// person reviewed, the plan and its approval, and the run it started. Each feature has its own file, so preparing or reviewing one
/// feature's draft never touches another's, nor the runs.
struct CockpitDraft: Codable, Equatable, Identifiable {
    enum Preparation: String, Codable { case preparing, ready, blocked }
    struct Approval: Codable, Equatable {
        var approval: CockpitApproval
        var step: Int
        var productionConfirmed: Bool
        var plan: CockpitPlan
    }

    var feature: CockpitFeatureContext
    var goal: String
    var controls: CockpitControls
    var plan: CockpitPlan?
    var preparation: Preparation
    /// Why the plan could not be prepared; shown with the choice of a direct handoff.
    var blocker: String?
    /// The person approved this exact plan and has not started it yet.
    var approved: Approval?
    /// The run this draft started; the draft stays with it.
    var runID: UUID?
    var updated: Date

    var id: String { feature.slug }
    var slug: String { feature.slug }
}

/// Call on a background executor. A draft that cannot be read throws and is never replaced by an empty one.
enum CockpitDraftStore {
    private static let fileStore = SchemaVersionedStore<CockpitDraft>(dates: .iso8601)
    private static func directory(_ root: URL) -> URL { ProjectPaths.cockpitDraftsFolder(root) }

    /// A feature slug names a folder of docs/features, so it is a single path component; anything else is refused.
    static func url(_ slug: String, root: URL) -> URL? {
        guard !slug.isEmpty, !slug.hasPrefix("."), !slug.contains("/"), !slug.contains(":"), slug.count <= 200 else { return nil }
        return directory(root).appendingPathComponent(slug + ".json")
    }

    static func save(_ draft: CockpitDraft, root: URL) throws {
        guard let target = url(draft.slug, root: root) else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = directory(root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileStore.save(draft, to: target, permissions: 0o600)
    }

    static func load(_ slug: String, root: URL) throws -> CockpitDraft? {
        guard let target = url(slug, root: root) else { return nil }
        switch fileStore.load(from: target) {
        case .missing: return nil
        case let result: return try result.get()
        }
    }

    static func loadAll(root: URL) throws -> [CockpitDraft] {
        let folder = directory(root)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try load($0.deletingPathExtension().lastPathComponent, root: root) }
    }

    static func delete(_ slug: String, root: URL) throws {
        guard let target = url(slug, root: root), FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }
}

/// At most one unfinished run per project (REQ-001, REQ-002). Every Start asks here: a start reserves the project synchronously on
/// the main actor, so two windows of the same project that ask at once cannot both pass, and a saved run that is still running or
/// paused blocks too. The reservation ends with the run.
@MainActor
enum CockpitAdmission {
    struct Blocker: Equatable {
        var runID: UUID?
        var title: String
        var message: String
    }

    /// The project root path and the owner that holds it, with the run's title.
    private static var reservations: [String: (owner: ObjectIdentifier, title: String, runID: UUID?)] = [:]

    private static func key(_ root: URL) -> String { root.standardizedFileURL.resolvingSymlinksInPath().path }

    /// Reserves `root` for `owner`, unless another owner holds it or `saved` has an unfinished run other than `continuing`.
    static func reserve(root: URL, owner: AnyObject, title: String, saved: [CockpitRun], continuing: UUID? = nil) -> Blocker? {
        let id = ObjectIdentifier(owner)
        if let held = reservations[key(root)], held.owner != id {
            return Blocker(runID: held.runID, title: held.title, message: "Another Cockpit run of this project is starting or running: \u{201C}\(held.title)\u{201D}.")
        }
        if let blocking = saved.first(where: { $0.isUnfinished && $0.id != continuing }) {
            return Blocker(runID: blocking.id, title: blocking.plan.displayTitle,
                           message: "The run \u{201C}\(blocking.plan.displayTitle)\u{201D} is not finished. End it or let it finish first.")
        }
        reservations[key(root)] = (id, title, continuing)
        return nil
    }

    /// The run of the reservation is now known.
    static func note(root: URL, owner: AnyObject, runID: UUID) {
        guard let held = reservations[key(root)], held.owner == ObjectIdentifier(owner) else { return }
        reservations[key(root)] = (held.owner, held.title, runID)
    }

    static func release(root: URL, owner: AnyObject) {
        guard reservations[key(root)]?.owner == ObjectIdentifier(owner) else { return }
        reservations[key(root)] = nil
    }

    static func holder(root: URL) -> ObjectIdentifier? { reservations[key(root)]?.owner }
}
