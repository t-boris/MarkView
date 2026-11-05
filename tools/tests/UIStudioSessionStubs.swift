// Stand-ins for the app's assistant runner and feature store, so that tools/tests/ui-studio-session-tests.sh can run a
// real UI Studio session (StudioSession) outside the app: the harness answers as the assistant and records what a
// feature export writes.
import Foundation

enum CLICompletion {
    struct Request {
        let project: URL?
        var prompt: String
        var systemPrompt: String? = nil
        var jsonSchema: [String: Any]? = nil
        var readableFolder: URL? = nil
        var extraReadableFolders: [URL] = []
        var timeout: TimeInterval? = 180
        var model: String? = nil
        var effort: String? = nil
        var allowWeb = false
        var images: [URL] = []
        var label = ""
    }

    struct Result {
        let text: String
        let structured: Any?
        let inputTokens: Int
        let outputTokens: Int
        let costUSD: Double?
    }

    enum Activity: Sendable {
        case read(String), search(String), run(String), webSearch(String), webFetch(String), thinking, writing(Int), answerDelta(String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [Request] = []
    nonisolated(unsafe) static var answer: @Sendable (Request) async throws -> Result = { _ in
        Result(text: "", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
    }

    /// Every request the session made, in order, except the application map's.
    static var requests: [Request] { lock.withLock { log } }

    /// The application map's requests (REQ-014: `ui-studio:map`, `ui-studio:map-group`, `ui-studio:map-refill`), apart from
    /// `requests`, so the checks that count the other calls are not changed by the map every new session makes. Without
    /// `mapAnswer` the inventory finds no endpoint.
    nonisolated(unsafe) private static var mapLog: [Request] = []
    nonisolated(unsafe) static var mapAnswer: (@Sendable (Request) async throws -> Result)? = nil
    static var mapRequests: [Request] { lock.withLock { mapLog } }

    static func run(_ request: Request, onDelta: (@Sendable (String) -> Void)? = nil,
                    onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        if request.label.hasPrefix("ui-studio:map") {
            let answer = lock.withLock { () -> (@Sendable (Request) async throws -> Result)? in
                mapLog.append(request)
                return mapAnswer
            }
            if let answer { return try await answer(request) }
            return Result(text: "", structured: ["services": [], "endpoints": [], "notes": []], inputTokens: 0, outputTokens: 0, costUSD: nil)
        }
        lock.withLock { log.append(request) }
        onActivity?(.thinking)
        return try await answer(request)
    }
}

enum ProjectAgentTools {
    static func requirementBody(statement: String, criteria: [String]) -> String {
        "## Statement\n\n\(statement)\n\n## Acceptance Criteria\n\n" + criteria.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n"
    }
}

enum FeatureObjectKind: String { case source, requirement }

struct FeatureObject {
    let id: String
    let url: URL
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
