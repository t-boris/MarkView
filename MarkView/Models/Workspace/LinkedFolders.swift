import Foundation

/// A folder attached to a project as an alias (Task 59): browsed in the file tree, searched and
/// indexed together with the project, readable by the AI. The project's own elements — features,
/// bugs, metadata — stay in the opened folder; a linked folder is never moved, copied or changed
/// by linking it.
struct LinkedFolder: Codable, Equatable, Identifiable {
    /// The folder's canonical path (`ProjectColor.projectKey`).
    var path: String
    /// Unique among the project's linked folders; usually the folder's name.
    var name: String
    var added: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

enum LinkedFolders {
    /// Document ids of files in linked folders start with this: never a path inside the project.
    static let documentIdPrefix = "@linked/"

    // MARK: Store — local settings of the project, never in the project folder

    static let defaultsKey = "project.linkedFolders"
    /// Posted when a project's linked folders change; `object` is the project key.
    static let didChange = Notification.Name("LinkedFoldersDidChange")

    static func key(_ project: URL) -> String { ProjectColor.projectKey(for: project) }

    static func load(project: URL?) -> [LinkedFolder] {
        guard let project, let data = UserDefaults.standard.dictionary(forKey: defaultsKey)?[key(project)] as? Data else { return [] }
        return decode(data)
    }

    static func save(_ folders: [LinkedFolder], project: URL) {
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        if folders.isEmpty { all[key(project)] = nil } else { all[key(project)] = encode(folders) }
        UserDefaults.standard.set(all, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChange, object: key(project))
    }

    static func encode(_ folders: [LinkedFolder]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(folders)
    }

    static func decode(_ data: Data) -> [LinkedFolder] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LinkedFolder].self, from: data)) ?? []
    }

    // MARK: Linking

    /// Why `folder` cannot be linked to `project`, or nil when it can. Only existing folders;
    /// never the project itself, a folder inside it (already part of the project), one that
    /// contains it, one already linked, or one nested in a linked folder either way (it would be
    /// searched twice).
    static func problem(linking folder: URL, to project: URL, existing: [LinkedFolder]) -> String? {
        let path = key(folder)
        let root = key(project)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "“\(folder.lastPathComponent)” is not a folder."
        }
        if path == root { return "“\(folder.lastPathComponent)” is the project folder itself." }
        if path.hasPrefix(root + "/") { return "“\(folder.lastPathComponent)” is inside the project already." }
        if root.hasPrefix(path + "/") { return "“\(folder.lastPathComponent)” contains the project folder." }
        for linked in existing {
            if linked.path == path { return "“\(folder.lastPathComponent)” is linked already." }
            if path.hasPrefix(linked.path + "/") { return "“\(folder.lastPathComponent)” is inside the linked folder “\(linked.name)”." }
            if linked.path.hasPrefix(path + "/") { return "“\(folder.lastPathComponent)” contains the linked folder “\(linked.name)”." }
        }
        return nil
    }

    /// A name for `folder` that no linked folder uses: its name, else "name-2", "name-3"…
    static func uniqueName(for folder: URL, among existing: [LinkedFolder]) -> String {
        let base = folder.lastPathComponent.isEmpty ? "folder" : folder.lastPathComponent
        let taken = Set(existing.map(\.name))
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }

    /// `folder` linked to `project`, or the reason it cannot be.
    static func link(_ folder: URL, to project: URL, existing: [LinkedFolder], now: Date = Date()) -> Result<LinkedFolder, LinkError> {
        if let problem = problem(linking: folder, to: project, existing: existing) { return .failure(LinkError(message: problem)) }
        // Whole seconds: the stored ISO 8601 date reads back equal.
        let added = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return .success(LinkedFolder(path: key(folder), name: uniqueName(for: folder, among: existing), added: added))
    }

    struct LinkError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Paths

    /// The linked folder that contains `url` (or is `url`), if any.
    static func folder(containing url: URL, in linked: [LinkedFolder]) -> LinkedFolder? {
        let path = key(url)
        return linked.first { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    /// The document id of a file for the project's index: its path inside the project, or
    /// `@linked/<name>/<path>` inside a linked folder, else (outside both) its file name — the
    /// same rule as `SemanticDatabase.documentId(for:root:)`, extended to linked folders.
    static func documentId(for fileURL: URL, root: URL, linked: [LinkedFolder]) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") {
            return SemanticDatabase.documentId(for: fileURL, root: root)
        }
        let resolved = key(fileURL)
        for folder in linked where resolved.hasPrefix(folder.path + "/") {
            return documentIdPrefix + folder.name + "/" + resolved.dropFirst(folder.path.count + 1)
        }
        return fileURL.lastPathComponent
    }

    /// The linked folder and relative path a `@linked/<name>/<path>` document id names, or nil
    /// for any other id.
    static func split(documentId: String, in linked: [LinkedFolder]) -> (folder: LinkedFolder, relativePath: String)? {
        guard documentId.hasPrefix(documentIdPrefix) else { return nil }
        let rest = documentId.dropFirst(documentIdPrefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let name = String(rest[..<slash])
        guard let folder = linked.first(where: { $0.name == name }) else { return nil }
        return (folder, String(rest[rest.index(after: slash)...]))
    }

    /// The file a `@linked/…` document id names, or nil for any other id or an unknown folder.
    static func resolve(documentId: String, in linked: [LinkedFolder]) -> URL? {
        guard let (folder, relativePath) = split(documentId: documentId, in: linked) else { return nil }
        return folder.url.appendingPathComponent(relativePath)
    }
}

extension CLITool {
    /// Arguments that let the CLI read `folders` besides its working directory (Claude
    /// `--add-dir`). Codex reads the whole disk in its read-only sandbox; Cline and Copilot have
    /// no such option.
    func additionalFolderArgs(_ folders: [URL]) -> [String] {
        guard self == .claude else { return [] }
        return folders.flatMap { ["--add-dir", $0.path] }
    }
}
