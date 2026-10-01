import Foundation
import CoreGraphics

/// Separate identities preserve two windows even when they show the same folder.
struct WorkspaceWindowState: Codable, Identifiable {
    var id: UUID
    var folder: URL?
    var tabs: [WorkspaceTabState] = []
    var activeTabIndex: Int = -1
    var panels: WorkspacePanelState?
    var frame: CGRect?
    var minimized = false
}

struct WorkspacePanelState: Codable {
    var workspaceArea: String? = nil
    var workSection: String? = nil
    var navigator: String
    var left: String
    var feature: String
    var git: String
    var stage: String
    var showFiles: Bool
    var showNavigator: Bool
    var contentsVisible: Bool? = nil
    var terminalVisible: Bool? = nil
    var showCenter: Bool? = nil
}

struct WorkspaceDraft: Codable {
    var content: String
    var original: String
}

enum WorkspaceTabState: Codable {
    case file(url: URL, draft: WorkspaceDraft?, notes: Bool, scroll: Double)
    case image(URL)
    case github(GitHubItem)
    case architecture(String)
    case terminal(URL)
    case browser(URL)
}

struct WindowSessionArchive: Codable {
    var version = 1
    var windows: [WorkspaceWindowState]
}

/// All archive IO is serialized off the main thread; quitting awaits the last write.
actor WindowSessionStorage {
    let url: URL
    private var latestRevision = -1

    init(url: URL) { self.url = url }

    func load() -> WindowSessionArchive? {
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(WindowSessionArchive.self, from: data),
              archive.version == 1 else { return nil }
        // URLs in this local archive must never turn into external open requests.
        guard archive.windows.allSatisfy({ state in
            state.folder == nil || state.folder!.isFileURL
        }) else { return nil }
        var seen = Set<UUID>()
        return WindowSessionArchive(windows: archive.windows.filter { seen.insert($0.id).inserted })
    }

    func save(_ archive: WindowSessionArchive, revision: Int) throws {
        guard revision > latestRevision else { return }
        let data = try JSONEncoder().encode(archive)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        // Unsaved editor text is local session data, not a shared project artifact.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        latestRevision = revision
    }
}
