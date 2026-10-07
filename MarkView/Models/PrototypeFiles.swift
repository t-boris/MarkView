import Foundation

/// File-level rules of Prototype Studio: where a prototype lives, which paths an agent answer may
/// touch, how edits apply, and the version snapshots. Pure Foundation, so `tools/tests/prototype-tests.sh`
/// compiles it on its own.
///
/// A prototype is `<project>/.dde/prototypes/<slug>/` with `prototype.json`, the live `site/` and one
/// `versions/vN/` copy of `site/` per accepted change.
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

    struct Manifest: Codable, Equatable {
        var title: String
        var slug: String
        var brief: String
        /// Requirement sources (files or folders), relative to the project root.
        var sources: [String]
        var version = 0
        var approved = false
        var screens: [String] = []
        var assumptions: [String] = []
        var history: [Entry] = []
    }

    /// Text formats only: the agent answers with text, and the export stays reviewable.
    static let allowedExtensions: Set<String> = ["html", "css", "js", "json", "svg", "txt", "md", "csv"]
    static let maxFileBytes = 600_000

    // MARK: - Locations

    static func folder(root: URL, slug: String) -> URL {
        root.appendingPathComponent(".dde/prototypes", isDirectory: true).appendingPathComponent(slug, isDirectory: true)
    }
    static func site(of folder: URL) -> URL { folder.appendingPathComponent("site", isDirectory: true) }
    static func versionFolder(of folder: URL, _ version: Int) -> URL {
        folder.appendingPathComponent("versions/v\(version)", isDirectory: true)
    }
    static func manifestURL(of folder: URL) -> URL { folder.appendingPathComponent("prototype.json") }

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
        let dir = root.appendingPathComponent(".dde/prototypes", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: manifestURL(of: folder(root: root, slug: $0)).path) }
            .sorted()
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
