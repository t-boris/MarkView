// What the real assistant runner (CLICompletion) needs from the rest of the app, and the feature store UI Studio exports to, as
// small stand-ins, so that tools/tests/ui-studio-live-run.sh can run a real UI Studio session outside the app.
import Foundation

enum FeatureObjectKind: String { case source, requirement }

struct FeatureObject {
    let id: String
    let url: URL
    static func requirementBody(statement: String, criteria: [String]) -> String {
        "## Statement\n\n\(statement)\n\n## Acceptance Criteria\n\n" + criteria.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n"
    }
}

/// Records features and objects in memory; source files get a real folder so pictures can be copied next to them.
@MainActor
final class FeatureStore {
    struct Written {
        var slug: String
        var kind: FeatureObjectKind
        var id: String
        var title: String
        var front: FrontMatter
        var body: String
    }

    var lastError: String?
    let folder: URL
    private(set) var overviews: [String: (front: FrontMatter, body: String)] = [:]
    private(set) var objects: [Written] = []
    /// Every status step and hand-off the session asked the lifecycle for, in order ("feature slug → draft by system UI Studio").
    private(set) var moves: [String] = []
    /// Bug statuses the lifecycle would have written.
    private(set) var bugStatuses: [String: String] = [:]

    init(folder: URL) { self.folder = folder }

    var lifecycleActor: String { "Tester" }

    func bugStatus(role: LifecycleRole) -> String? {
        switch role {
        case .notStarted: return "open"
        case .active: return "fixing"
        case .completed: return "fixed"
        case .cancelled: return "closed"
        }
    }

    func bugClosingStatus(_ key: String) -> String? { "closed" }

    @discardableResult
    func moveFeature(_ slug: String, to status: String, by actor: LifecycleActor, reason: String? = nil, surface: Bool = true) -> ApplyResult {
        moves.append("feature \(slug) → \(status) by \(actor.kind.rawValue) \(actor.name)")
        updateFeature(slug) { front, _ in front.set("status", status) }
        return .unchanged
    }

    @discardableResult
    func moveBug(_ key: String, to status: String, by actor: LifecycleActor, reason: String? = nil,
                 evidence: LifecycleEvidence = .none, surface: Bool = true) -> ApplyResult {
        moves.append("bug \(key) → \(status) by \(actor.kind.rawValue) \(actor.name)")
        bugStatuses[key] = status
        // The real service writes the status line of the report; so does this one.
        guard let url = bugFiles.first(where: { $0.lastPathComponent.uppercased().hasPrefix(key.uppercased()) }) else {
            return .failed("\(key) has no file.")
        }
        return updateBug(url) { front, _ in front.set("status", status) } ? .unchanged : .failed("\(key) could not be written.")
    }

    /// The hand-off is the start evidence: the feature goes to implementing.
    func markImplementing(_ slug: String, handoff tool: String) {
        moves.append("feature \(slug) → implementing by hand-off \(tool)")
        updateFeature(slug) { front, _ in front.set("status", "implementing") }
    }

    func createFeature(title: String, idea: String) -> String? {
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
        var front = FrontMatter()
        front.set("title", title)
        overviews[slug] = (front, idea)
        return slug
    }

    func updateFeature(_ slug: String, _ change: (inout FrontMatter, inout String) -> Void) {
        guard var overview = overviews[slug] else { return }
        change(&overview.front, &overview.body)
        overviews[slug] = overview
    }

    @discardableResult
    func create(_ kind: FeatureObjectKind, in slug: String, title: String, fields: [(String, YAMLValue)] = [],
                body: String, provenance: String) -> FeatureObject? {
        let prefix = kind == .source ? "SRC" : "REQ"
        let id = String(format: "%@-%03d", prefix, objects.filter { $0.kind == kind && $0.slug == slug }.count + 1)
        var front = FrontMatter()
        for (key, value) in fields { front[key] = value }
        front.set("provenance", provenance)
        objects.append(Written(slug: slug, kind: kind, id: id, title: title, front: front, body: body))
        let directory = folder.appendingPathComponent(slug).appendingPathComponent(kind.rawValue)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FeatureObject(id: id, url: directory.appendingPathComponent(id + ".md"))
    }

    func update(_ id: String, in slug: String, _ change: (inout FrontMatter, inout String) -> Void) {
        guard let index = objects.firstIndex(where: { $0.slug == slug && $0.id == id }) else { return }
        var object = objects[index]
        change(&object.front, &object.body)
        objects[index] = object
    }

    func deleteObjects(_ slug: String, ids: Set<String>) -> Int {
        let before = objects.count
        objects.removeAll { $0.slug == slug && ids.contains($0.id) }
        return before - objects.count
    }

    func reloadSync(_ slug: String? = nil) {}

    func feature(_ slug: String) -> String? { overviews[slug] == nil ? nil : slug }

    // Bug reports (REQ-012): written by the app's BugReportWriter into a real docs/bugs folder next to the features,
    // numbered like FeatureAssistant.nextNumbered, and rewritten like the real store does.
    let defaultOwner = "Test Person"
    var bugsFolder: URL? { folder.deletingLastPathComponent().appendingPathComponent("bugs", isDirectory: true) }

    var bugFiles: [URL] {
        guard let bugsFolder else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: bugsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func createBug(_ draft: BugReportDraft) throws -> (id: String, url: URL) {
        guard let bugsFolder else { throw BugReportWriter.Failure(message: "No project folder.") }
        let id = String(format: "BUG-%03d", bugFiles.count + 1)
        let slug = draft.title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let url = try BugReportWriter.write(draft, id: id, slug: String(slug), created: "2026-11-04", in: bugsFolder)
        return (id, url)
    }

    @discardableResult
    func updateBug(_ url: URL, _ change: (inout FrontMatter, inout String) -> Void) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var (front, body) = FrontMatter.split(text)
        change(&front, &body)
        return (try? front.join(body: body).write(to: url, atomically: true, encoding: .utf8)) != nil
    }
}
