import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The folders a project leaves out of its file tree. They are a fact about the project, so they are kept under the project's full
/// path: two projects whose folders have the same name (`~/a/app`, `~/b/app`) used to share one list, because the key was only
/// the last path component.
enum ExcludedFolders {
    /// The key of a project's list: its full path.
    static func key(for root: URL) -> SettingsKey<[String]> { Setting.excludedFolders(path: root.standardizedFileURL.path) }

    /// The key before the full path was used; it is read once for a project that has no list under its own key yet.
    private static func nameKey(for root: URL) -> SettingsKey<[String]> { Setting.excludedFoldersByName(root.lastPathComponent) }

    static func load(for root: URL, defaults: UserDefaults = .standard) -> Set<String> {
        let settings = Settings(defaults)
        if let saved = settings.stored(key(for: root)) { return Set(saved) }
        // A list saved under the folder's name comes along once, then the project keeps its own; the old entry stays for any other
        // project that has the same name and has not been opened since.
        if let legacy = settings.stored(nameKey(for: root)) {
            settings.set(legacy, for: key(for: root))
            return Set(legacy)
        }
        return []
    }

    static func save(_ folders: Set<String>, for root: URL, defaults: UserDefaults = .standard) {
        Settings(defaults).set(folders.sorted(), for: key(for: root))
    }
}
