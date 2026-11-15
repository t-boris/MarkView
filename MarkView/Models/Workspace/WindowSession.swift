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

/// A tab as a window session keeps it. The JSON of every case is the one the compiler-generated coding wrote before tool tabs became
/// one case (`{"git":{}}`, `{"image":{"_0":"file:///..."}}`), so sessions saved by any earlier version still load.
enum WorkspaceTabState: Codable {
    case file(url: URL, draft: WorkspaceDraft?, notes: Bool, scroll: Double)
    case image(URL)
    case pdf(URL)
    /// An archive tab; added in 4.19.
    case archive(URL)
    /// The tab of a tool in `ToolRegistry`, saved under the tool's id with an empty body: what the Deployments (4.25), Discussions
    /// (4.51), Workflow (5.45), End-to-End QA (5.55), Git and file-changes cases wrote.
    case tool(ToolID)
    case github(GitHubItem)
    case architecture(String)
    case terminal(URL)
    case browser(URL)
    /// A data file tab (table, Parquet, SQLite, log); added in 4.7.
    case data(URL)

    /// The name a case is saved under, and the names of its fields.
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        /// The key the compiler gives the one unlabeled value of a case.
        static let value = Key("_0")
    }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Key.self)
        guard outer.allKeys.count == 1, let name = outer.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A saved tab has exactly one case"))
        }
        let body = try outer.nestedContainer(keyedBy: Key.self, forKey: name)
        switch name.stringValue {
        case "file":
            self = .file(url: try body.decode(URL.self, forKey: Key("url")), draft: try body.decodeIfPresent(WorkspaceDraft.self, forKey: Key("draft")),
                         notes: try body.decode(Bool.self, forKey: Key("notes")), scroll: try body.decode(Double.self, forKey: Key("scroll")))
        case "image": self = .image(try body.decode(URL.self, forKey: .value))
        case "pdf": self = .pdf(try body.decode(URL.self, forKey: .value))
        case "archive": self = .archive(try body.decode(URL.self, forKey: .value))
        case "github": self = .github(try body.decode(GitHubItem.self, forKey: .value))
        case "architecture": self = .architecture(try body.decode(String.self, forKey: .value))
        case "terminal": self = .terminal(try body.decode(URL.self, forKey: .value))
        case "browser": self = .browser(try body.decode(URL.self, forKey: .value))
        case "data": self = .data(try body.decode(URL.self, forKey: .value))
        // Any other name is a tool; one this version does not have is skipped when the window is restored.
        default: self = .tool(ToolID(rawValue: name.stringValue))
        }
    }

    func encode(to encoder: Encoder) throws {
        var outer = encoder.container(keyedBy: Key.self)
        func single<Value: Encodable>(_ name: String, _ value: Value) throws {
            var body = outer.nestedContainer(keyedBy: Key.self, forKey: Key(name))
            try body.encode(value, forKey: .value)
        }
        switch self {
        case .file(let url, let draft, let notes, let scroll):
            var body = outer.nestedContainer(keyedBy: Key.self, forKey: Key("file"))
            try body.encode(url, forKey: Key("url"))
            try body.encodeIfPresent(draft, forKey: Key("draft"))
            try body.encode(notes, forKey: Key("notes"))
            try body.encode(scroll, forKey: Key("scroll"))
        case .image(let url): try single("image", url)
        case .pdf(let url): try single("pdf", url)
        case .archive(let url): try single("archive", url)
        case .github(let item): try single("github", item)
        case .architecture(let scope): try single("architecture", scope)
        case .terminal(let directory): try single("terminal", directory)
        case .browser(let url): try single("browser", url)
        case .data(let url): try single("data", url)
        case .tool(let id): _ = outer.nestedContainer(keyedBy: Key.self, forKey: Key(id.rawValue))
        }
    }
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
