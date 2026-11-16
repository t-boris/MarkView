import Combine
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

// The layout presets the app offers (architecture review AR-33, DEC-002): the ones that ship in `Resources/Layouts/` and the ones a
// person put in `~/Library/Application Support/MarkView/layouts/`. `LayoutLibrary` is the pure part (read two folders, validate, look up);
// `LayoutCatalog` is the one shared, observable copy the menus read. A file that cannot be used is never skipped silently: it is
// logged and listed with its reason in `LayoutLibrary.ignored`, which the Layout menu shows. The app never writes, rewrites or deletes
// a layout file. Foundation, Combine and the TaskBag only, so `tools/tests/layout-preset-tests.sh` compiles it without the app.

// MARK: - Library

struct LayoutLibrary: Equatable, Sendable {
    /// A file in a layouts folder that is not a usable preset, and why.
    struct Ignored: Equatable, Identifiable, Sendable {
        let file: String
        let reason: String
        var id: String { file }
    }

    /// At most this many files of the person's folder are read; a folder with more is reported, not partly guessed at.
    static let userFileLimit = 64

    /// The usable presets: the built-in ones first, then the person's, each group in the order of its file names.
    let presets: [LayoutPreset]
    let ignored: [Ignored]

    /// Reads the bundled presets and the person's. Does file work: call it off the main thread (the catalog does).
    static func load(builtInFolder: URL?, userFolder: URL?, tools: ToolRegistry = .shared) -> LayoutLibrary {
        var presets: [LayoutPreset] = []
        var ignored: [Ignored] = []
        if let builtInFolder {
            let result = read(builtInFolder, limit: nil, taken: [], tools: tools)
            presets += result.presets
            ignored += result.ignored
        } else {
            ignored.append(Ignored(file: "Layouts", reason: "the app has no folder of built-in layouts"))
        }
        if let userFolder {
            let result = read(userFolder, limit: userFileLimit, taken: Set(presets.map(\.id)), tools: tools)
            presets += result.presets
            ignored += result.ignored
        }
        return LayoutLibrary(presets: presets, ignored: ignored)
    }

    private static func read(_ folder: URL, limit: Int?, taken: Set<String>, tools: ToolRegistry) -> (presets: [LayoutPreset], ignored: [Ignored]) {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: folder.path, isDirectory: &isFolder) else { return ([], []) }
        guard isFolder.boolValue, let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                                                 options: [.skipsHiddenFiles]) else {
            return ([], [Ignored(file: folder.lastPathComponent, reason: "the folder cannot be read")])
        }
        var presets: [LayoutPreset] = []
        var ignored: [Ignored] = []
        var seen = taken
        let files = entries.filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for (index, url) in files.enumerated() {
            let file = url.lastPathComponent
            if let limit, index >= limit {
                ignored.append(Ignored(file: file, reason: "more than \(limit) layout files; only the first \(limit) are read"))
                continue
            }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > LayoutPreset.maxFileSize {
                ignored.append(Ignored(file: file, reason: "the file is larger than \(LayoutPreset.maxFileSize / 1024) KB"))
                continue
            }
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                ignored.append(Ignored(file: file, reason: "the file cannot be read: \(error.localizedDescription)"))
                continue
            }
            switch LayoutPreset.parse(data, tools: tools) {
            case .success(let preset):
                if seen.contains(preset.id) {
                    ignored.append(Ignored(file: file, reason: "\"\(preset.id)\" is the id of a built-in layout or of another file"))
                } else {
                    seen.insert(preset.id)
                    presets.append(preset)
                }
            case .failure(let problem):
                ignored.append(Ignored(file: file, reason: problem.reason))
            }
        }
        return (presets, ignored)
    }
}

// MARK: - Catalog

/// The layout presets of this run of the app, shared by every window. The bundled ones are read when the catalog is first needed;
/// the person's folder is read right after that and again whenever "Reload Layouts" is chosen, off the main thread.
@MainActor
final class LayoutCatalog: ObservableObject {
    static let shared = LayoutCatalog()

    /// `<app>/Contents/Resources/Layouts`.
    nonisolated static var bundledFolder: URL? { Bundle.main.resourceURL?.appendingPathComponent("Layouts", isDirectory: true) }

    /// `~/Library/Application Support/MarkView/layouts`: where a person's own layout files go.
    nonisolated static var userFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkView/layouts", isDirectory: true)
    }

    @Published private(set) var library: LayoutLibrary

    private let builtInFolder: URL?
    private let customFolder: URL?
    /// The reads of the person's folder: a new one replaces the one before it (`AR-19`).
    private let tasks = TaskBag()

    init(builtInFolder: URL? = LayoutCatalog.bundledFolder, userFolder: URL? = LayoutCatalog.userFolder) {
        self.builtInFolder = builtInFolder
        self.customFolder = userFolder
        // The bundled folder is a few small files in the app; the person's folder is read off the main thread, right after.
        library = LayoutLibrary.load(builtInFolder: builtInFolder, userFolder: nil)
        log(library.ignored, known: [])
        startReload()
    }

    /// Reads both folders again in the background, so a layout file added while the app runs can be chosen. A read still running is replaced.
    func startReload() {
        tasks.store(Task { [weak self] in await self?.reload() }, for: "reload")
    }

    private func reload() async {
        let built = builtInFolder, custom = customFolder
        let fresh = await Task.detached(priority: .utility) { LayoutLibrary.load(builtInFolder: built, userFolder: custom) }.value
        guard !Task.isCancelled, fresh != library else { return }
        log(fresh.ignored, known: library.ignored)
        library = fresh
    }

    private func log(_ problems: [LayoutLibrary.Ignored], known: [LayoutLibrary.Ignored]) {
        for problem in problems where !known.contains(problem) { AppLog.workspace.error("Ignored layout file \(problem.file): \(problem.reason)") }
    }
}
