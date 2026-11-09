import Foundation

/// The delivery-evidence log of this Mac: one JSON-lines file in the app's Application Support folder, shared by every window. It
/// holds what GitHub and git showed about a feature's delivery (see EvidenceTimings.swift), never a change of status - the workflow
/// journal is the one record of those. Lines are only appended; the one way to remove any is `deleteProject`, which the person
/// confirms (feature cycle-time-as-a-view-over-the-workflow, DEC-001).
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

    /// A feature's evidence, oldest first. The log keeps the lines of deleted features too; a feature that reuses a slug is told
    /// apart by the time its own journal begins (`EvidenceTimings.timeline(since:)`).
    func events(project: String, feature: String) -> [LifecycleEvent] {
        events.filter { $0.project == project && $0.feature == feature }.sorted { $0.timestamp < $1.timestamp }
    }

    /// Lines that do not decode (damaged, or a stage that no longer exists), and lines that are not evidence (the retired observer,
    /// manual marks), are skipped.
    nonisolated private static func read(_ url: URL) -> [LifecycleEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(LifecycleEvent.self, from: Data($0.utf8)) }.filter(\.isEvidence)
    }

    // MARK: Recording

    /// Add an evidence line. The time is the moment the thing happened where it is known (GitHub's merge time, the click that handed
    /// a feature to the AI), never later than now.
    @discardableResult
    func record(_ stage: EvidenceStage, project: String, feature: String, actor: String,
                model: String? = nil, note: String? = nil, at time: Date? = nil) -> LifecycleEvent? {
        guard !project.isEmpty, !feature.isEmpty else { return nil }
        func cleaned(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let event = LifecycleEvent(id: UUID(), project: project, feature: feature, stage: stage, timestamp: min(time ?? Date(), Date()),
                                   actor: actor, source: .automatic, model: cleaned(model), note: cleaned(note).map { String($0.prefix(500)) })
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
                let message = "Could not save the delivery evidence: \(error.localizedDescription)"
                Task { @MainActor in LifecycleLog.shared.lastError = message }
            }
        }
        return event
    }

    /// Removes every line of one project from this Mac's log (REQ-002): the file is rewritten without them, on the write queue so
    /// that it cannot cross an append. Other projects' lines are kept as written; the workflow journal is not touched.
    func deleteProject(_ project: String) {
        guard !project.isEmpty else { return }
        events.removeAll { $0.project == project }
        let url = url
        queue.async {
            do {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let kept = text.split(separator: "\n").filter { line in
                    guard let event = try? decoder.decode(LifecycleEvent.self, from: Data(line.utf8)) else { return true }
                    return event.project != project
                }
                try (kept.map(String.init).joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let message = "Could not delete the delivery evidence: \(error.localizedDescription)"
                Task { @MainActor in LifecycleLog.shared.lastError = message }
            }
        }
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

/// AI model names used on this Mac: the spelling already seen is reused, so one model is one name in the evidence.
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
