import Combine
import Foundation

// The themes the app can draw (architecture review AR-32, DEC-003): the ones that ship in `Resources/Themes/` and the ones a person put in
// `~/Library/Application Support/MarkView/themes/`. `ThemeLibrary` is the pure part (read two folders, validate, look up); `ThemeCatalog`
// is the one shared, observable copy the windows and the picker read. A file that cannot be used is never skipped silently: it is listed
// with its reason in `ThemeLibrary.ignored`, and the picker shows that list. The app never writes, rewrites or deletes a theme file.
// Foundation and Combine only, so `tools/tests/theme-model-tests.sh` compiles it without the app.

// MARK: - Library

struct ThemeLibrary: Equatable, Sendable {
    /// A file in a themes folder that is not a usable theme, and why.
    struct Ignored: Equatable, Identifiable, Sendable {
        let file: String
        let reason: String
        var id: String { file }
    }

    /// One row of the picker.
    struct Choice: Equatable, Identifiable, Sendable {
        let theme: AppTheme
        let name: String
        let summary: String
        var id: String { theme.id }
    }

    /// What `resolve` found. `missing` is the stored id that no theme answers to, when the definition is the Classic Dark that stands in.
    struct Resolution: Equatable, Sendable {
        let definition: ThemeDefinition
        let missing: String?
    }

    /// At most this many files of the person's folder are read; a folder with more is reported, not partly guessed at.
    static let userFileLimit = 64
    static let systemName = "System"
    static let systemSummary = "Follows the macOS appearance"

    /// The usable themes in picker order (`order`, then name).
    let themes: [ThemeDefinition]
    let ignored: [Ignored]

    func definition(_ id: String) -> ThemeDefinition? { themes.first { $0.id == id } }

    /// The definition to draw for `theme`: System becomes Classic Dark or Classic Light; an id nobody has becomes Classic Dark and is
    /// named in `missing` so the caller can say so once.
    func resolve(_ theme: AppTheme, systemIsDark: Bool) -> Resolution {
        if theme.isSystem { return Resolution(definition: classic(dark: systemIsDark), missing: nil) }
        if let found = definition(theme.id) { return Resolution(definition: found, missing: nil) }
        return Resolution(definition: classic(dark: true), missing: theme.id)
    }

    private func classic(dark: Bool) -> ThemeDefinition {
        let id = (dark ? AppTheme.classicDark : AppTheme.classicLight).id
        guard let found = definition(id) else {
            // The two Classic themes are the look before themes and what every unknown id falls back to; a bundle without them is broken.
            preconditionFailure("The built-in theme \"\(id)\" is missing from the app's Themes folder. Problems: \(ignored.map { "\($0.file): \($0.reason)" })")
        }
        return found
    }

    /// The picker's rows: the active theme first while it is one that is listed only then (Classic), System, and the listed themes.
    func choices(current: AppTheme) -> [Choice] {
        var rows: [Choice] = []
        if let active = definition(current.id), active.picker == .whileActive {
            rows.append(Choice(theme: current, name: active.name, summary: active.summary))
        }
        rows.append(Choice(theme: .system, name: Self.systemName, summary: Self.systemSummary))
        rows += themes.filter { $0.picker == .listed }.map { Choice(theme: AppTheme($0.id), name: $0.name, summary: $0.summary) }
        return rows
    }

    /// The name shown for `theme` in the picker and its help texts.
    func name(of theme: AppTheme) -> String {
        theme.isSystem ? Self.systemName : (definition(theme.id)?.name ?? theme.id)
    }

    // MARK: Reading

    /// Reads the bundled themes and the person's. Does file work: call it off the main thread (the catalog does).
    static func load(builtInFolder: URL?, userFolder: URL?) -> ThemeLibrary {
        var themes: [ThemeDefinition] = []
        var ignored: [Ignored] = []
        if let builtInFolder {
            let result = read(builtInFolder, source: { _ in .builtIn }, limit: nil, taken: [])
            themes += result.themes
            ignored += result.ignored
        } else {
            ignored.append(Ignored(file: "Themes", reason: "the app has no folder of built-in themes"))
        }
        if let userFolder {
            let result = read(userFolder, source: { .user(file: $0) }, limit: userFileLimit, taken: Set(themes.map(\.id)))
            themes += result.themes
            ignored += result.ignored
        }
        themes.sort { ($0.order, $0.name.lowercased(), $0.id) < ($1.order, $1.name.lowercased(), $1.id) }
        return ThemeLibrary(themes: themes, ignored: ignored)
    }

    private static func read(_ folder: URL, source: (String) -> ThemeDefinition.Source, limit: Int?,
                             taken: Set<String>) -> (themes: [ThemeDefinition], ignored: [Ignored]) {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: folder.path, isDirectory: &isFolder) else { return ([], []) }
        guard isFolder.boolValue, let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                                                 options: [.skipsHiddenFiles]) else {
            return ([], [Ignored(file: folder.lastPathComponent, reason: "the folder cannot be read")])
        }
        var themes: [ThemeDefinition] = []
        var ignored: [Ignored] = []
        var seen = taken
        let files = entries.filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for (index, url) in files.enumerated() {
            let file = url.lastPathComponent
            if let limit, index >= limit {
                ignored.append(Ignored(file: file, reason: "more than \(limit) theme files; only the first \(limit) are read"))
                continue
            }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > ThemeDefinition.maxFileSize {
                ignored.append(Ignored(file: file, reason: "the file is larger than \(ThemeDefinition.maxFileSize / 1024) KB"))
                continue
            }
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                ignored.append(Ignored(file: file, reason: "the file cannot be read: \(error.localizedDescription)"))
                continue
            }
            let id = url.deletingPathExtension().lastPathComponent
            switch ThemeDefinition.parse(data, id: id, source: source(file)) {
            case .success(let theme):
                if seen.contains(theme.id) {
                    ignored.append(Ignored(file: file, reason: "\"\(theme.id)\" is the id of a built-in theme or of another file"))
                } else {
                    seen.insert(theme.id)
                    themes.append(theme)
                }
            case .failure(let problem):
                ignored.append(Ignored(file: file, reason: problem.reason))
            }
        }
        return (themes, ignored)
    }
}

// MARK: - Catalog

/// The themes of this run of the app, shared by every window. The bundled themes are read when it is first needed (they are the
/// window's first paint); the person's folder is read again each time the picker opens, off the main thread.
@MainActor
final class ThemeCatalog: ObservableObject {
    static let shared = ThemeCatalog()

    /// `<app>/Contents/Resources/Themes` (a folder beside the executable when it is not an app, as the checks run it).
    nonisolated static var bundledFolder: URL? { Bundle.main.resourceURL?.appendingPathComponent("Themes", isDirectory: true) }

    /// `~/Library/Application Support/MarkView/themes`: where a person's own theme files go.
    nonisolated static var userFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkView/themes", isDirectory: true)
    }

    @Published private(set) var library: ThemeLibrary
    /// Stored theme ids that no theme has now; each is shown as Classic Dark and named in the picker until the theme is back.
    @Published private(set) var missing: [String] = []

    private let builtInFolder: URL?
    private let customFolder: URL?
    private var logged = Set<String>()

    init(builtInFolder: URL? = ThemeCatalog.bundledFolder, userFolder: URL? = ThemeCatalog.userFolder) {
        self.builtInFolder = builtInFolder
        self.customFolder = userFolder
        library = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: userFolder)
        for problem in library.ignored { NSLog("[themes] ignored %@: %@", problem.file, problem.reason) }
    }

    /// The definition to draw for `theme`. A stored id nobody has is shown as Classic Dark and reported once (log and picker).
    /// Never call this while a view body is being evaluated: it may publish `missing`.
    func resolve(_ theme: AppTheme, systemIsDark: Bool) -> ThemeDefinition {
        let resolution = library.resolve(theme, systemIsDark: systemIsDark)
        if let id = resolution.missing, !missing.contains(id) {
            missing.append(id)
            if logged.insert(id).inserted { NSLog("[themes] theme \"%@\" was not found; Classic Dark is shown instead", id) }
        }
        return resolution.definition
    }

    /// Reads both folders again, so a theme file added while the app runs can be chosen. The picker calls it when it opens.
    func reload() async {
        let built = builtInFolder, custom = customFolder
        let fresh = await Task.detached(priority: .utility) { ThemeLibrary.load(builtInFolder: built, userFolder: custom) }.value
        guard fresh != library else { return }
        for problem in fresh.ignored where !library.ignored.contains(problem) { NSLog("[themes] ignored %@: %@", problem.file, problem.reason) }
        library = fresh
        missing = missing.filter { fresh.definition($0) == nil }
    }
}
