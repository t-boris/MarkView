import Foundation

/// File-level rules of Prototype Studio: where a prototype lives, which paths an agent answer may
/// touch, how edits apply, and the version snapshots. Pure Foundation, so `tools/tests/prototype-tests.sh`
/// compiles it on its own.
///
/// A prototype is `<project>/docs/prototypes/<slug>/` with `prototype.json`, the live `site/` and one
/// `versions/vN/` copy of `site/` per accepted change. The folder is part of the project, so a prototype
/// can be committed and shared through the repository (DEC-006); `migrateLegacy` moves prototypes made
/// before that from `.dde/prototypes/`.
enum PrototypeFiles {

    struct File: Equatable {
        var path: String
        var content: String
    }

    /// Replaces the one occurrence of `find` in `path`.
    struct Edit: Equatable {
        var path: String
        var find: String
        var replace: String
    }

    struct Change: Equatable {
        var files: [File] = []
        var edits: [Edit] = []
        var deletes: [String] = []
        var isEmpty: Bool { files.isEmpty && edits.isEmpty && deletes.isEmpty }
    }

    enum Failure: LocalizedError, Equatable {
        case badPath(String)
        case tooLarge(String)
        /// Edits that could not be applied, one message each; nothing was written.
        case edits([String])

        var errorDescription: String? {
            switch self {
            case .badPath(let path): return "The assistant named a path outside the prototype: \(path)"
            case .tooLarge(let path): return "\(path) is too large for a prototype file."
            case .edits(let problems): return problems.joined(separator: "\n")
            }
        }
    }

    struct Entry: Codable, Equatable {
        var version: Int
        var instruction: String
        var summary: String
        var date: Date
    }

    /// How a prototype was made: designed from requirement documents, or reconstructed from the
    /// project's existing web-interface code (Previews from Existing Code).
    enum Mode: String, Codable, Sendable {
        case requirements, code
    }

    struct Manifest: Codable, Equatable {
        var title: String
        var slug: String
        var brief: String
        /// Sources (files or folders), relative to the project root: requirement documents in
        /// `.requirements` mode, the implementation that was reconstructed in `.code` mode. Empty
        /// means the whole project.
        var sources: [String]
        var version = 0
        var approved = false
        var screens: [String] = []
        var assumptions: [String] = []
        var history: [Entry] = []
        var mode = Mode.requirements
        /// Behaviour of the original code that the reconstruction does not reproduce (backend calls,
        /// authentication, Electron preload APIs, native dialogs…). Recorded once, at generation;
        /// review edits never change it (DEC-004).
        var gaps: [String] = []
    }

    /// One message of the review conversation as saved in `conversation.json`; images are file names in `attachments/`.
    struct StoredMessage: Codable, Equatable {
        var role: String
        var text: String
        var images: [String] = []
    }

    /// Text formats only: the agent answers with text, and the export stays reviewable.
    static let allowedExtensions: Set<String> = ["html", "css", "js", "json", "svg", "txt", "md", "csv"]
    static let maxFileBytes = 600_000

    // MARK: - Locations

    /// Where prototypes live, relative to the project root: committed with the project (DEC-006). The
    /// single source of truth for every path producer and consumer, `PrototypeReference` included.
    static let storageFolder = "docs/prototypes"
    /// Where prototypes lived before DEC-006; `migrateLegacy` moves them once, `PrototypeReference` still reads the path.
    static let legacyStorageFolder = ".dde/prototypes"

    static func storage(root: URL) -> URL {
        root.appendingPathComponent(storageFolder, isDirectory: true)
    }

    static func folder(root: URL, slug: String) -> URL {
        storage(root: root).appendingPathComponent(slug, isDirectory: true)
    }
    static func site(of folder: URL) -> URL { folder.appendingPathComponent("site", isDirectory: true) }
    static func versionFolder(of folder: URL, _ version: Int) -> URL {
        folder.appendingPathComponent("versions/v\(version)", isDirectory: true)
    }
    static func manifestURL(of folder: URL) -> URL { folder.appendingPathComponent("prototype.json") }

    /// Where the implementation ZIP of an approved prototype goes, relative to the project root: a derived,
    /// binary artifact that is not review material, so it stays outside the committed `docs/` tree (DEC-006).
    static let exportsFolder = ".dde/exports/prototypes"

    /// `<root>/.dde/exports/prototypes/<slug>-v<version>.zip`.
    static func exportArchive(root: URL, slug: String, version: Int) -> URL {
        root.appendingPathComponent(exportsFolder, isDirectory: true).appendingPathComponent("\(slug)-v\(version).zip")
    }

    /// Lowercase words joined by dashes, unique among the existing prototypes.
    static func slug(for title: String, existing: Set<String>) -> String {
        let base = title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").prefix(6).joined(separator: "-")
        let stem = base.isEmpty ? "prototype" : base
        var candidate = stem, n = 2
        while existing.contains(candidate) { candidate = "\(stem)-\(n)"; n += 1 }
        return candidate
    }

    static func existingSlugs(root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: storage(root: root).path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: manifestURL(of: folder(root: root, slug: $0)).path) }
            .sorted()
    }

    // MARK: - Migration (DEC-006)

    /// What `migrateLegacy` did: the slugs it moved and the ones it left in place.
    struct MigrationReport: Equatable, Sendable {
        var moved: [String] = []
        /// Left in `.dde/prototypes/`: a prototype of the same slug already exists in `docs/prototypes/`.
        var conflicts: [String] = []
        /// Left in place because the move failed; each with the error text.
        var failed: [String] = []

        var isEmpty: Bool { moved.isEmpty && conflicts.isEmpty && failed.isEmpty }

        /// One line for the log.
        var summary: String {
            var parts: [String] = []
            if !moved.isEmpty { parts.append("moved \(moved.joined(separator: ", ")) to \(PrototypeFiles.storageFolder)") }
            if !conflicts.isEmpty { parts.append("left in \(PrototypeFiles.legacyStorageFolder) (slug already in \(PrototypeFiles.storageFolder)): \(conflicts.joined(separator: ", "))") }
            if !failed.isEmpty { parts.append("could not move: \(failed.joined(separator: "; "))") }
            return parts.isEmpty ? "nothing to migrate" : parts.joined(separator: "; ")
        }
    }

    /// Moves every folder of `.dde/prototypes/` to `docs/prototypes/`, once. A folder whose name already
    /// exists at the new place is left where it is and reported; nothing is deleted or rewritten, so the
    /// call is idempotent and safe to repeat on every project open. Pure file-system work; the caller keeps
    /// it off the main thread.
    static func migrateLegacy(root: URL, fileManager: FileManager = .default) -> MigrationReport {
        let legacy = root.appendingPathComponent(legacyStorageFolder, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? fileManager.contentsOfDirectory(atPath: legacy.path) else { return MigrationReport() }
        var report = MigrationReport()
        for name in names.sorted() where !name.hasPrefix(".") {
            let source = legacy.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let target = folder(root: root, slug: name)
            if fileManager.fileExists(atPath: target.path) {
                report.conflicts.append(name)
                continue
            }
            do {
                try fileManager.createDirectory(at: storage(root: root), withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: target)
                report.moved.append(name)
            } catch {
                report.failed.append("\(name): \(error.localizedDescription)")
            }
        }
        return report
    }

    // MARK: - Conversation

    static func conversationURL(of folder: URL) -> URL { folder.appendingPathComponent("conversation.json") }

    static func loadConversation(_ folder: URL) -> [StoredMessage]? {
        guard let data = try? Data(contentsOf: conversationURL(of: folder)) else { return nil }
        return try? JSONDecoder().decode([StoredMessage].self, from: data)
    }

    static func saveConversation(_ messages: [StoredMessage], in folder: URL) {
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: conversationURL(of: folder), options: .atomic)
    }

    // MARK: - Manifest

    static func loadManifest(_ folder: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL(of: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }

    static func saveManifest(_ manifest: Manifest, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL(of: folder), options: .atomic)
    }

    // MARK: - Scope (code mode)

    /// Whether a web app found at `appPath` (project-relative; "" for the root) belongs to the reconstruction
    /// scope `sources` (files or folders relative to the root). Nothing selected means the whole project
    /// (DEC-003); otherwise the app is in scope when it contains a selected source or lies inside a selected
    /// folder. The creator sheet lists the apps in scope and refuses to start when there are none.
    static func isInScope(appPath: String, sources: [String]) -> Bool {
        let app = normalizedRelative(appPath)
        let selected = sources.map(normalizedRelative).filter { !$0.isEmpty }
        guard !selected.isEmpty else { return true }
        return selected.contains { source in contains(folder: app, path: source) || contains(folder: source, path: app) }
    }

    /// `path` is `folder` itself or inside it; the root ("") holds everything.
    private static func contains(folder: String, path: String) -> Bool {
        folder.isEmpty || folder == path || path.hasPrefix(folder + "/")
    }

    /// A project-relative path without surrounding whitespace, a leading `./` or trailing slashes; "." and "/" become "".
    private static func normalizedRelative(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        return path == "." ? "" : path
    }

    // MARK: - Inventory (code mode)

    /// One web-interface file of the reconstruction scope: its project-relative path and size. The
    /// content is never inlined; the assistant reads the files it needs with its own tools.
    struct InventoryEntry: Equatable, Sendable {
        var path: String
        var bytes: Int
    }

    /// The web-interface files under the selected sources, capped so a large project still fits a prompt.
    struct Inventory: Equatable, Sendable {
        var entries: [InventoryEntry] = []
        /// Files past the cap that are not in `entries`.
        var omitted = 0

        var isEmpty: Bool { entries.isEmpty }

        /// One line per file, then the "+N more" marker when the cap was hit.
        var lines: [String] {
            var out = entries.map { "- \($0.path) (\($0.bytes) bytes)" }
            if omitted > 0 { out.append("+\(omitted) more files not listed") }
            return out
        }
    }

    static let inventoryLimit = 400
    /// Files that describe a web interface; everything else (images, backend code, docs) is left out.
    static let inventoryExtensions: Set<String> = ["html", "htm", "css", "scss", "less", "js", "jsx", "ts", "tsx",
                                                   "vue", "svelte", "webmanifest"]
    /// The only `.json` files listed: package and app manifests, which name the framework and the entry points.
    static let inventoryJSONNames: Set<String> = ["package.json", "manifest.json", "app.json", "angular.json",
                                                  "tsconfig.json", "electron-builder.json"]
    private static let inventorySkippedFolders: Set<String> = ["node_modules", "dist", "build", "out", "target", "vendor",
                                                               "coverage", "Pods", "DerivedData", ".git", ".dde"]

    /// Whether a file name belongs in the inventory (web-interface formats; no minified bundles).
    static func isInventoryFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard !lower.hasPrefix("."), !lower.hasSuffix(".min.js"), !lower.hasSuffix(".min.css") else { return false }
        let ext = (lower as NSString).pathExtension
        if ext == "json" { return inventoryJSONNames.contains(lower) }
        return inventoryExtensions.contains(ext)
    }

    /// The web-interface files under `sources` (files or folders relative to `root`; empty means the
    /// whole project), sorted by path, skipping dependency, build, VCS, `.dde` and hidden folders and the
    /// prototypes themselves (`docs/prototypes`). A source outside the root or that does not exist is
    /// ignored. Pure file-system reading; the caller keeps it off the main thread.
    static func inventory(root: URL, sources: [String], limit: Int = inventoryLimit,
                          fileManager: FileManager = .default) -> Inventory {
        let base = root.standardizedFileURL
        let basePath = base.path + "/"
        let storagePath = storage(root: base).standardizedFileURL.path
        var seen = Set<String>()
        var entries: [InventoryEntry] = []

        func add(_ url: URL) {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(basePath), !full.hasPrefix(storagePath + "/"), !seen.contains(full),
                  isInventoryFile(url.lastPathComponent) else { return }
            seen.insert(full)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            entries.append(InventoryEntry(path: String(full.dropFirst(basePath.count)), bytes: size))
        }

        func walk(_ folder: URL) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .nameKey]
            guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys, options: []) else { return }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let name = values?.name ?? url.lastPathComponent
                if values?.isDirectory == true {
                    if name.hasPrefix(".") || inventorySkippedFolders.contains(name)
                        || url.standardizedFileURL.path == storagePath { walker.skipDescendants() }
                    continue
                }
                if values?.isRegularFile == true { add(url) }
            }
        }

        let roots = sources.isEmpty ? [""] : sources
        for source in roots {
            let trimmed = source.trimmingCharacters(in: .whitespaces)
            let url = trimmed.isEmpty ? base : base.appendingPathComponent(trimmed).standardizedFileURL
            guard url.path == base.path || url.path.hasPrefix(basePath) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { walk(url) } else { add(url) }
        }
        entries.sort { $0.path < $1.path }
        let cap = max(0, limit)
        guard entries.count > cap else { return Inventory(entries: entries) }
        return Inventory(entries: Array(entries.prefix(cap)), omitted: entries.count - cap)
    }

    // MARK: - Paths and files

    /// The normalised relative path, or `badPath` for anything absolute, hidden, climbing out of the
    /// site or not a text format.
    static func validate(path raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespaces)
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !parts.isEmpty,
              !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") }),
              allowedExtensions.contains((parts.last! as NSString).pathExtension.lowercased()) else {
            throw Failure.badPath(raw)
        }
        return parts.joined(separator: "/")
    }

    /// Every text file under `site`, sorted by path.
    static func read(site: URL) -> [File] {
        guard let walker = FileManager.default.enumerator(at: site, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [File] = []
        let base = site.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base), (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files.append(File(path: String(full.dropFirst(base.count)), content: text))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Applies `change` to `site`. Files replace, edits patch (each `find` must occur exactly once),
    /// deletes remove. Nothing is written unless every part is valid.
    @discardableResult
    static func apply(_ change: Change, to site: URL) throws -> [String] {
        var state = Dictionary(uniqueKeysWithValues: read(site: site).map { ($0.path, $0.content) })
        var touched = Set<String>()
        for file in change.files {
            let path = try validate(path: file.path)
            guard file.content.utf8.count <= maxFileBytes else { throw Failure.tooLarge(path) }
            state[path] = file.content
            touched.insert(path)
        }
        var problems: [String] = []
        for edit in change.edits {
            let path = try validate(path: edit.path)
            guard let text = state[path] else { problems.append("\(path): the file does not exist"); continue }
            guard !edit.find.isEmpty else { problems.append("\(path): empty text to find"); continue }
            let count = text.components(separatedBy: edit.find).count - 1
            guard count == 1 else {
                problems.append("\(path): the text to find occurs \(count) times (it must occur exactly once): \(edit.find.prefix(80))")
                continue
            }
            let patched = text.replacingOccurrences(of: edit.find, with: edit.replace)
            guard patched.utf8.count <= maxFileBytes else { throw Failure.tooLarge(path) }
            state[path] = patched
            touched.insert(path)
        }
        if !problems.isEmpty { throw Failure.edits(problems) }
        var removed: [String] = []
        for path in change.deletes {
            let path = try validate(path: path)
            if state.removeValue(forKey: path) != nil { removed.append(path) }
        }
        let fm = FileManager.default
        for path in touched.sorted() {
            guard let text = state[path] else { continue }
            let url = site.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        for path in removed { try? fm.removeItem(at: site.appendingPathComponent(path)) }
        return touched.sorted()
    }

    // MARK: - Agent answers

    /// A change from the structured answer of the assistant (`files`, `edits`, `delete`; each optional).
    static func change(from answer: Any?) -> Change {
        guard let object = answer as? [String: Any] else { return Change() }
        func text(_ item: [String: Any], _ key: String) -> String { item[key] as? String ?? "" }
        let files = (object["files"] as? [[String: Any]] ?? []).map { File(path: text($0, "path"), content: text($0, "content")) }
        let edits = (object["edits"] as? [[String: Any]] ?? []).map {
            Edit(path: text($0, "path"), find: text($0, "find"), replace: text($0, "replace"))
        }
        return Change(files: files, edits: edits, deletes: object["delete"] as? [String] ?? [])
    }

    /// Replaces the line `<!--SCREENS-->` of the foundation's index.html with one script tag per screen; nil when
    /// the line is missing. The tags are the program's, not the assistant's, so a screen can never be left unloaded.
    static func insertScreenScripts(into html: String, ids: [String]) -> String? {
        let marker = "<!--SCREENS-->"
        guard html.contains(marker) else { return nil }
        let tags = ids.map { "<script src=\"screens/\($0).js\"></script>" }.joined(separator: "\n")
        return html.replacingOccurrences(of: marker, with: marker + "\n" + tags)
    }

    // MARK: - Versions

    /// Copies `site` to `versions/v<version>`.
    static func snapshot(folder: URL, version: Int) throws {
        let target = versionFolder(of: folder, version)
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: site(of: folder), to: target)
    }

    /// Makes `site` equal to `versions/v<version>`.
    static func restore(folder: URL, version: Int) throws {
        let source = versionFolder(of: folder, version)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw Failure.badPath("versions/v\(version)") }
        let live = site(of: folder)
        try? fm.removeItem(at: live)
        try fm.copyItem(at: source, to: live)
    }
}

extension PrototypeFiles.Manifest {
    /// Lenient decoding, in an extension so the memberwise initializer stays: a `prototype.json`
    /// written before `mode` and `gaps` existed (or by a newer app with a mode this one does not
    /// know) still opens, with the defaults for what is missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        slug = try c.decode(String.self, forKey: .slug)
        brief = try c.decodeIfPresent(String.self, forKey: .brief) ?? ""
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        approved = try c.decodeIfPresent(Bool.self, forKey: .approved) ?? false
        screens = try c.decodeIfPresent([String].self, forKey: .screens) ?? []
        assumptions = try c.decodeIfPresent([String].self, forKey: .assumptions) ?? []
        history = try c.decodeIfPresent([PrototypeFiles.Entry].self, forKey: .history) ?? []
        let rawMode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        mode = PrototypeFiles.Mode(rawValue: rawMode) ?? .requirements
        gaps = try c.decodeIfPresent([String].self, forKey: .gaps) ?? []
    }
}
