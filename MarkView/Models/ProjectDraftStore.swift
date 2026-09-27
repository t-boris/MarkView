import Foundation

/// Unfinished new projects (DEC-015): `~/Library/Application Support/MarkView/ProjectDrafts/<id>/`
/// holds `draft.json` and `workspace/`, the specification being clarified. Shared by every
/// window; the welcome screen lists them for Resume and Discard.
@MainActor
final class ProjectDraftStore: ObservableObject {
    static let shared = ProjectDraftStore()

    @Published private(set) var drafts: [ProjectDraft] = []

    private let folder: URL

    init(folder: URL = ProjectDraftStore.defaultFolder) {
        self.folder = folder
        reload()
    }

    /// A copy with another bundle ID (a test build) keeps its own drafts, as its window sessions.
    nonisolated static var defaultFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "com.markview.MarkView"
        let directory = bundleID == "com.markview.MarkView" ? "MarkView" : "MarkView-" + bundleID
        return support.appendingPathComponent(directory).appendingPathComponent("ProjectDrafts", isDirectory: true)
    }

    func directory(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// The draft's specification workspace (a FeatureStore root).
    func workspace(_ id: UUID) -> URL { directory(id).appendingPathComponent("workspace", isDirectory: true) }

    func draft(_ id: UUID) -> ProjectDraft? { drafts.first { $0.id == id } }

    /// Read every draft again (off the main thread).
    func reload() {
        let folder = folder
        Task {
            let loaded = await Task.detached { Self.load(folder) }.value
            drafts = loaded
        }
    }

    nonisolated private static func load(_ folder: URL) -> [ProjectDraft] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("draft.json")) else { return nil }
            return try? decoder.decode(ProjectDraft.self, from: data)
        }
        .sorted { $0.updated > $1.updated }
    }

    /// Write the record (atomically, off the main thread) and show it at once.
    func save(_ draft: ProjectDraft) async throws {
        var draft = draft
        draft.updated = Date()
        if let index = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[index] = draft } else { drafts.insert(draft, at: 0) }
        let url = directory(draft.id).appendingPathComponent("draft.json")
        let workspace = workspace(draft.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(draft)
        try await Task.detached {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }.value
    }

    /// Remove a draft with its workspace: Discard, or after its project was created.
    func remove(_ id: UUID) async {
        drafts.removeAll { $0.id == id }
        let dir = directory(id)
        await Task.detached { try? FileManager.default.removeItem(at: dir) }.value
    }
}
