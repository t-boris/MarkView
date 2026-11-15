import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif
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
    /// The theme of this window and the accent each theme remembers in it; absent in sessions saved before themes.
    var theme: WindowThemeSettings?
    /// What this window shows of itself besides the panels (`WindowUIState`); absent in sessions saved before it existed.
    var uiState: [String: WindowUIValue]?
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
    var agentsVisible: Bool? = nil
    var showCenter: Bool? = nil
    /// This window's welcome-screen background (a `WelcomeBackdrop` raw value); absent in sessions saved before BUG-120.
    var welcomeBackdrop: String? = nil
}

struct WorkspaceDraft: Codable {
    var content: String
    var original: String
}

enum WorkspaceTabState: Codable {
    case file(url: URL, draft: WorkspaceDraft?, notes: Bool, scroll: Double)
    case image(URL)
    case pdf(URL)
    /// An archive tab; added in 4.19.
    case archive(URL)
    /// The Deployments tab; added in 4.25.
    case deployments
    /// The Discussions tab; added in 4.51.
    case discussions
    /// The Workflow tab of the project; added in 5.45.
    case workflow
    case git
    /// The End-to-End QA tab; added in 5.55.
    case qa
    case changeReview
    case github(GitHubItem)
    case architecture(String)
    case terminal(URL)
    case browser(URL)
    /// A data file tab (table, Parquet, SQLite, log); added in 4.7.
    case data(URL)
}

struct WindowSessionArchive: Codable {
    var version = 1
    var windows: [WorkspaceWindowState]
}

/// What `WindowSessionStorage.save` did with an archive.
enum WindowSessionSaveOutcome: Equatable {
    case saved
    /// A later revision was already written, so this one was dropped.
    case superseded
    /// The file on disk was written by a newer MarkView and was left untouched. `announce` is true for the first
    /// refusal of this launch only: the one the user is told about.
    case refused(announce: Bool)
}

/// All archive IO is serialized off the main thread; quitting awaits the last write.
actor WindowSessionStorage {
    let url: URL
    private let store: SchemaVersionedStore<WindowSessionArchive>
    private var latestRevision = -1
    /// The modification date of the file when it was found to be written by a newer MarkView. While the file keeps this
    /// date the verdict stands, so a refused autosave costs a `stat` instead of reading and decoding the whole file.
    private var refusedModification: Date?
    private var refusalAnnounced = false

    init(url: URL) {
        self.url = url
        self.store = SchemaVersionedStore<WindowSessionArchive>(currentSchemaVersion: 1, backupCorruptedOnSave: true)
    }

    func load() -> WindowSessionArchive? {
        let loadedArchive: WindowSessionArchive
        switch store.load(from: url) {
        case .loaded(let archive, _):
            loadedArchive = archive
        case .missing:
            return nil
        case .newerSchema(_, let found):
            NSLog("[WindowSession] Ignoring windowSessions.json: schema version %d is newer than supported (%d).", found, store.currentSchemaVersion)
            return nil
        case .corrupted(_, let detail):
            NSLog("[WindowSession] Could not read windowSessions.json: %@", detail)
            return nil
        }
        guard loadedArchive.version == 1 else {
            NSLog("[WindowSession] Ignoring windowSessions.json: unsupported archive payload version %d.", loadedArchive.version)
            return nil
        }
        // URLs in this local archive must never turn into external open requests.
        guard loadedArchive.windows.allSatisfy({ state in
            state.folder == nil || state.folder!.isFileURL
        }) else { return nil }
        var seen = Set<UUID>()
        return WindowSessionArchive(windows: loadedArchive.windows.filter { seen.insert($0.id).inserted })
    }

    /// Writes `archive` unless the file was written by a newer MarkView (a future `schema` envelope, or a legacy payload
    /// with `version > 1`): that file is left untouched and the refusal is an outcome, not an error. Other failures throw.
    func save(_ archive: WindowSessionArchive, revision: Int) throws -> WindowSessionSaveOutcome {
        guard revision > latestRevision else { return .superseded }
        let stamp = modificationDate()
        if let refusedModification, refusedModification == stamp { return refusal() }
        if writtenByNewerMarkView() {
            refusedModification = stamp
            return refusal()
        }
        do {
            // Keep session data private to the user with atomic 0o600 permissions (`AR-39`, `FU-04`).
            try store.save(archive, to: url, permissions: 0o600)
        } catch SchemaStoreError.newerSchemaVersion {
            refusedModification = modificationDate() // the file was replaced after the check above
            return refusal()
        }
        refusedModification = nil
        latestRevision = revision
        return .saved
    }

    /// The save when MarkView quits. Quitting is never held up by the session file: a refusal or a write error is
    /// logged and the quit goes on; the next launch restores what the last autosave wrote.
    func saveAtQuit(_ archive: WindowSessionArchive, revision: Int) {
        do {
            if case .refused = try save(archive, revision: revision) {
                NSLog("[WindowSession] Not saved at quit: %@ was written by a newer MarkView and is left untouched.", url.lastPathComponent)
            }
        } catch {
            NSLog("[WindowSession] Could not save window sessions at quit: %@", error.localizedDescription)
        }
    }

    private func refusal() -> WindowSessionSaveOutcome {
        defer { refusalAnnounced = true }
        return .refused(announce: !refusalAnnounced)
    }

    private func writtenByNewerMarkView() -> Bool {
        switch store.load(from: url) {
        case .newerSchema: return true
        case .loaded(let existing, _): return existing.version > 1
        case .missing, .corrupted: return false
        }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
