import Foundation

/// The lifecycle event log of this Mac (DEC-001): one append-only JSON-lines file in the app's
/// Application Support folder, shared by every window. Events can only be added — there is no
/// way to edit, void or delete one (DEC-005).
@MainActor
final class LifecycleLog: ObservableObject {
    static let shared = LifecycleLog()

    @Published private(set) var events: [LifecycleEvent] = []
    @Published private(set) var lastError: String?

    private let url: URL
    /// File writes, in order, off the main thread.
    private let queue = DispatchQueue(label: "markview.lifecycle-log")
    /// Per project path, the one feature store that records automatic events (several windows
    /// may show the same folder; each transition must be recorded once).
    private var observers: [String: WeakObserver] = [:]

    private struct WeakObserver { weak var store: FeatureStore? }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = support.appendingPathComponent("MarkView", isDirectory: true).appendingPathComponent("lifecycle-events.jsonl")
        let url = url
        // On the write queue, before any write: the file read holds none of the events
        // recorded meanwhile, which stay after the older ones.
        queue.async {
            let loaded = Self.read(url)
            Task { @MainActor in LifecycleLog.shared.events = loaded + LifecycleLog.shared.events }
        }
    }

    // MARK: Reading

    func events(project: String) -> [LifecycleEvent] {
        events.filter { $0.project == project }
    }

    /// A feature's events, oldest first.
    func events(project: String, feature: String) -> [LifecycleEvent] {
        events.filter { $0.project == project && $0.feature == feature }.sorted { $0.timestamp < $1.timestamp }
    }

    /// Lines that do not decode (damaged, or a stage that does not exist) are skipped.
    nonisolated private static func read(_ url: URL) -> [LifecycleEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(LifecycleEvent.self, from: Data($0.utf8)) }
    }

    // MARK: Recording

    /// Add an event stamped now. Manual marks of automatic stages are refused (DEC-013).
    @discardableResult
    func record(_ stage: LifecycleStage, project: String, feature: String, actor: String,
                source: LifecycleSource, model: String? = nil, note: String? = nil) -> LifecycleEvent? {
        guard !project.isEmpty, !feature.isEmpty, source == .automatic || !stage.isAutomatic else { return nil }
        func cleaned(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let event = LifecycleEvent(id: UUID(), project: project, feature: feature, stage: stage, timestamp: Date(),
                                   actor: actor, source: source, model: cleaned(model),
                                   note: cleaned(note).map { String($0.prefix(LifecycleEvent.noteLimit)) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(event) else { return nil }
        events.append(event)
        let url = url
        queue.async {
            do {
                try Self.append(data + Data("\n".utf8), to: url)
            } catch {
                let message = "Could not save the lifecycle event: \(error.localizedDescription)"
                Task { @MainActor in LifecycleLog.shared.lastError = message }
            }
        }
        return event
    }

    nonisolated private static func append(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            try data.write(to: url, options: .withoutOverwriting)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func clearError() { lastError = nil }

    // MARK: Observers

    /// Should `store` record the automatic events of `project`? The first live store to ask does.
    func claim(_ project: String, by store: FeatureStore) -> Bool {
        if let owner = observers[project]?.store, owner !== store { return false }
        observers[project] = WeakObserver(store: store)
        return true
    }

    func release(_ project: String, by store: FeatureStore) {
        if observers[project]?.store === store { observers[project] = nil }
    }
}

/// AI model names used on this Mac, for the model field of manual marks (DEC-011).
enum LifecycleModels {
    private static let key = "lifecycle.models"

    /// Most recently used first.
    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    /// The spelling already known for `name` (case-insensitive), or `name` trimmed.
    static func canonical(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
    }

    /// Remember a model; returns the name to store.
    @discardableResult
    static func use(_ name: String) -> String {
        let name = canonical(name)
        guard !name.isEmpty else { return name }
        UserDefaults.standard.set([name] + all.filter { $0.caseInsensitiveCompare(name) != .orderedSame }, forKey: key)
        return name
    }
}
