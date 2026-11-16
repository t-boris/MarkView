import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

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

/// The folders linked to a project, kept as local settings of the project (never in the project folder). The store is here, in
/// the AI layer, because an assistant run reads them (`CLICompletion`); the rules for linking, and the document ids of their
/// files, are `LinkedFolders` extensions in the Workspace domain.
enum LinkedFolders {
    /// Posted when a project's linked folders change; `object` is the project key.
    static let didChange = Notification.Name("LinkedFoldersDidChange")

    static func key(_ project: URL) -> String { ProjectColor.projectKey(for: project) }

    static func load(project: URL?) -> [LinkedFolder] {
        guard let project, let data = Settings.standard.value(Setting.linkedFolders)[key(project)] as? Data else { return [] }
        return decode(data)
    }

    static func save(_ folders: [LinkedFolder], project: URL) {
        var all = Settings.standard.value(Setting.linkedFolders)
        if folders.isEmpty { all[key(project)] = nil } else { all[key(project)] = encode(folders) }
        Settings.standard.set(all, for: Setting.linkedFolders)
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
}
