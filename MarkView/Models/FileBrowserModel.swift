import Foundation

// The rules behind the Files panel (docs/features/flexible-files-views-and-visible-agent-usage):
// the three views, the filters, the sort, the Workspace level above the project root and the
// tree with its recursive search. Foundation only, so tools/tests/file-browser-tests.sh compiles
// it on its own; the views (FileTreeView, FileBrowserViews) only draw what this produces.

/// How Files shows a folder (AC-1).
enum FileBrowserViewMode: String, CaseIterable, Identifiable {
    case icon, list, tree

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: return "Icons"
        case .list: return "List"
        case .tree: return "Tree"
        }
    }

    var symbol: String {
        switch self {
        case .icon: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .tree: return "list.bullet.indent"
        }
    }
}

/// Which files a filter keeps (AC-3). Folders stay visible under `.openable` so every view can still be
/// navigated; only `.folders` hides files (DEC-003, DEC-004, DEC-007).
enum FileBrowserCategory: String, CaseIterable, Identifiable {
    case all, folders, openable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .folders: return "Folders"
        case .openable: return "Openable files"
        }
    }
}

/// The filters of Files. Everything but `query` is a setting that persists (DEC-008).
struct FileBrowserFilter: Equatable {
    var query = ""
    var showHidden = false
    /// Hide what Git ignores (REQ-001).
    var hideIgnored = false
    var category = FileBrowserCategory.all

    /// Some choice differs from the defaults; the filter control shows it.
    var isActive: Bool { self != FileBrowserFilter() }
    /// A setting, not the typed query, is on.
    var hasSettings: Bool { showHidden || hideIgnored || category != .all }
}

/// The settings that persist across restarts (AC-5): the view and the filter choices. The sort order
/// persists in `WorkspaceFileTreeStore`.
struct FileBrowserPreferences: Equatable {
    var mode = FileBrowserViewMode.list
    var showHidden = false
    var hideIgnored = false
    var category = FileBrowserCategory.all

    private enum Key {
        static let mode = "fileBrowser.viewMode"
        static let showHidden = "fileBrowser.showHidden"
        static let hideIgnored = "fileBrowser.hideIgnored"
        static let category = "fileBrowser.category"
    }

    static func load(from defaults: UserDefaults = .standard) -> FileBrowserPreferences {
        var preferences = FileBrowserPreferences()
        if let raw = defaults.string(forKey: Key.mode), let mode = FileBrowserViewMode(rawValue: raw) { preferences.mode = mode }
        if let raw = defaults.string(forKey: Key.category), let category = FileBrowserCategory(rawValue: raw) { preferences.category = category }
        preferences.showHidden = defaults.bool(forKey: Key.showHidden)
        preferences.hideIgnored = defaults.bool(forKey: Key.hideIgnored)
        return preferences
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(showHidden, forKey: Key.showHidden)
        defaults.set(hideIgnored, forKey: Key.hideIgnored)
        defaults.set(category.rawValue, forKey: Key.category)
    }
}

/// The project folder or a linked folder: a place at the Workspace level (AC-2).
struct FileBrowserRoot: Equatable {
    let url: URL
    let name: String
    /// nil for the project folder; the linked folder's id otherwise.
    let linkedID: String?

    var isProject: Bool { linkedID == nil }
    var key: String { FileBrowser.key(url) }
}

/// A file or folder as the three views show it.
struct FileBrowserEntry: Identifiable, Equatable {
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let modified: Date?
    let size: Int?
    let isHidden: Bool
    /// MarkView has a viewer for it (DEC-004). Always true for folders.
    let hasViewer: Bool
    /// Set when the entry is the project folder or a linked folder at the top level.
    var root: FileBrowserRoot?

    var key: String { FileBrowser.key(url) }
    var id: String { key }
    var name: String { root?.name ?? url.lastPathComponent }
    /// A file without a viewer (DEC-005): selected by a click, never opened by it.
    var isUnsupported: Bool { !isDirectory && !hasViewer }
}

/// What the engine needs to know about the window: places, filter, sort and two lookups the app answers
/// (the viewer classification and Git's ignore list).
struct FileBrowserSource {
    var roots: [FileBrowserRoot]
    var filter: FileBrowserFilter
    var sort: FileTreeSortOrder
    var hasViewer: @Sendable (URL) -> Bool
    /// (url, isDirectory) → Git ignores it. Linked folders outside the project's repository answer false.
    var isIgnored: @Sendable (URL, Bool) -> Bool = { _, _ in false }
}

/// One line of the Tree view.
struct FileBrowserRow: Identifiable, Equatable {
    let entry: FileBrowserEntry
    let depth: Int
    let isExpanded: Bool
    /// Shows a disclosure arrow: any folder in the plain tree, a folder with matches below it in a search.
    let isExpandable: Bool
    /// False for an ancestor kept only to reach a match (drawn dimmer).
    let isMatch: Bool

    var id: String { entry.key }
}

struct FileBrowserSearchResult: Equatable {
    var matches: [FileBrowserEntry] = []
    /// The search stopped at a limit; there may be more matches.
    var truncated = false
    /// Folders that could not be read (permissions, vanished); named in the result's note (DEC-001).
    var unreadableFolders = 0
}

/// Where Icon and List views are: above the project folder, or inside a folder (DEC-009).
enum FileBrowserLocation: Equatable {
    case workspace
    case folder(URL)
}

struct FileBrowserCrumb: Equatable {
    let title: String
    let location: FileBrowserLocation
}

enum FileBrowser {
    /// The identity of a path everywhere in the browser (selection, expansion, rows).
    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .isHiddenKey,
    ]

    // MARK: Entries

    static func entry(for url: URL, source: FileBrowserSource, root: FileBrowserRoot? = nil) -> FileBrowserEntry {
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        // A place is always a folder, even when it has vanished (deleted, drive unmounted): it stays a row that can
        // be unlinked.
        let isDirectory = root != nil || (values?.isDirectory ?? false)
        return FileBrowserEntry(
            url: url,
            isDirectory: isDirectory,
            isSymbolicLink: values?.isSymbolicLink ?? false,
            modified: values?.contentModificationDate,
            size: isDirectory ? nil : values?.fileSize,
            isHidden: url.lastPathComponent.hasPrefix(".") || values?.isHidden == true,
            hasViewer: isDirectory || source.hasViewer(url),
            root: root)
    }

    /// The hidden and Git-ignored filters. Places of the Workspace level are never filtered out.
    static func passesVisibility(_ entry: FileBrowserEntry, _ source: FileBrowserSource) -> Bool {
        if entry.root != nil { return true }
        if entry.isHidden && !source.filter.showHidden { return false }
        if source.filter.hideIgnored && source.isIgnored(entry.url, entry.isDirectory) { return false }
        return true
    }

    static func passesCategory(_ entry: FileBrowserEntry, _ category: FileBrowserCategory) -> Bool {
        switch category {
        case .all: return true
        case .folders: return entry.isDirectory
        case .openable: return entry.isDirectory || entry.hasViewer
        }
    }

    static func matches(name: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The entries of one folder under the filters. Icon and List views apply the name query to them;
    /// the children of an expanded Tree folder do not (the query switches the tree to a search).
    static func listing(of directory: URL, source: FileBrowserSource, applyQuery: Bool) -> [FileBrowserEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: resourceKeys) else {
            return []
        }
        let entries = urls.map { entry(for: $0, source: source) }.filter {
            passesVisibility($0, source) && passesCategory($0, source.filter.category)
                && (!applyQuery || matches(name: $0.name, query: source.filter.query))
        }
        return sorted(entries, by: source.sort)
    }

    /// The Workspace level: the project folder first, then the linked folders in the order they were linked.
    static func workspaceEntries(source: FileBrowserSource, applyQuery: Bool) -> [FileBrowserEntry] {
        source.roots
            .map { entry(for: $0.url, source: source, root: $0) }
            .filter { !applyQuery || matches(name: $0.name, query: source.filter.query) }
    }

    // MARK: Sort (AC-4)

    /// Folders before files; then the chosen field in the chosen direction; ties by name, ascending.
    static func sorted(_ entries: [FileBrowserEntry], by sort: FileTreeSortOrder) -> [FileBrowserEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sort.field {
            case .name:
                let order = compareNames(a, b)
                return sort.ascending ? order == .orderedAscending : order == .orderedDescending
            case .dateModified:
                let da = a.modified ?? .distantPast
                let db = b.modified ?? .distantPast
                if da != db { return sort.ascending ? da < db : da > db }
                return compareNames(a, b) == .orderedAscending
            }
        }
    }

    private static func compareNames(_ a: FileBrowserEntry, _ b: FileBrowserEntry) -> ComparisonResult {
        let order = a.name.compare(b.name, options: [.caseInsensitive])
        if order != .orderedSame { return order }
        // "A" and "a": keep the order stable between runs.
        return a.name == b.name ? .orderedSame : (a.name < b.name ? .orderedAscending : .orderedDescending)
    }

    // MARK: Tree (AC-1, AC-2)

    /// The plain tree: the project folder and the linked folders as siblings, each folder's children read when
    /// it is expanded. `expanded` holds `key(_:)` of the open folders.
    static func treeRows(source: FileBrowserSource, expanded: Set<String>) -> [FileBrowserRow] {
        var rows: [FileBrowserRow] = []
        func add(_ entry: FileBrowserEntry, depth: Int) {
            let open = entry.isDirectory && expanded.contains(entry.key)
            rows.append(FileBrowserRow(entry: entry, depth: depth, isExpanded: open,
                                       isExpandable: entry.isDirectory, isMatch: true))
            guard open else { return }
            for child in listing(of: entry.url, source: source, applyQuery: false) { add(child, depth: depth + 1) }
        }
        for place in workspaceEntries(source: source, applyQuery: false) { add(place, depth: 0) }
        return rows
    }

    // MARK: Tree search (DEC-001)

    /// Every item under the project folder and the linked folders whose name contains the query, found by
    /// walking the disk: collapsed and never-opened folders are searched too. Hidden and ignored items are
    /// skipped with everything below them when those filters are on. Symbolic links to folders are not
    /// followed. The walk is breadth-first, so when the visit or match cap is reached the shallow matches of every
    /// place have already been found, whatever lies deep inside one of them. Meant for a background task:
    /// `isCancelled` is polled between folders.
    static func search(source: FileBrowserSource, matchLimit: Int = 2_000, visitLimit: Int = 300_000,
                       isCancelled: () -> Bool = { false }) -> FileBrowserSearchResult {
        var result = FileBrowserSearchResult()
        var visited = 0
        var pending = source.roots.map(\.url)
        var next = 0
        while next < pending.count {
            let directory = pending[next]
            next += 1
            if isCancelled() { break }
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: resourceKeys) else {
                result.unreadableFolders += 1
                continue
            }
            for url in urls {
                visited += 1
                if visited > visitLimit || result.matches.count >= matchLimit {
                    result.truncated = true
                    return result
                }
                let item = entry(for: url, source: source)
                guard passesVisibility(item, source) else { continue }
                if passesCategory(item, source.filter.category), matches(name: item.name, query: source.filter.query) {
                    result.matches.append(item)
                }
                if item.isDirectory && !item.isSymbolicLink { pending.append(url) }
            }
        }
        return result
    }

    /// The tree of a search: each match under the folders that lead to it, all of them open. A place without a
    /// match is left out.
    static func searchRows(_ result: FileBrowserSearchResult, source: FileBrowserSource) -> [FileBrowserRow] {
        let rootKeys = Set(source.roots.map(\.key))
        let matchKeys = Set(result.matches.map(\.key))
        var known: [String: FileBrowserEntry] = [:]
        for match in result.matches { known[match.key] = match }
        var childrenOf: [String: [FileBrowserEntry]] = [:]
        var placed = Set<String>()
        for match in result.matches {
            var current = match
            while !rootKeys.contains(current.key) {
                guard placed.insert(current.key).inserted else { break }
                let parent = current.url.deletingLastPathComponent()
                let parentKey = key(parent)
                guard parentKey != current.key else { break }
                childrenOf[parentKey, default: []].append(current)
                if rootKeys.contains(parentKey) { break }
                let ancestor = known[parentKey] ?? entry(for: parent, source: source)
                known[parentKey] = ancestor
                current = ancestor
            }
        }
        var rows: [FileBrowserRow] = []
        func add(_ entry: FileBrowserEntry, depth: Int) {
            let children = sorted(childrenOf[entry.key] ?? [], by: source.sort)
            rows.append(FileBrowserRow(entry: entry, depth: depth, isExpanded: !children.isEmpty,
                                       isExpandable: !children.isEmpty,
                                       isMatch: entry.root != nil || matchKeys.contains(entry.key)))
            for child in children { add(child, depth: depth + 1) }
        }
        for place in workspaceEntries(source: source, applyQuery: false) where childrenOf[place.key] != nil {
            add(place, depth: 0)
        }
        return rows
    }

    // MARK: Navigation (AC-2)

    /// The place `url` belongs to: the innermost root that contains it.
    static func root(containing url: URL, in roots: [FileBrowserRoot]) -> FileBrowserRoot? {
        let path = key(url)
        return roots
            .filter { path == $0.key || path.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }
    }

    /// Where ".." goes: from a place's root to the Workspace level, from inside a place to the parent folder.
    static func parent(of location: FileBrowserLocation, roots: [FileBrowserRoot]) -> FileBrowserLocation? {
        guard case .folder(let url) = location else { return nil }
        if roots.contains(where: { $0.key == key(url) }) { return .workspace }
        guard root(containing: url, in: roots) != nil else { return .workspace }
        return .folder(url.deletingLastPathComponent())
    }

    /// Workspace › place › folders down to the location.
    static func crumbs(for location: FileBrowserLocation, roots: [FileBrowserRoot]) -> [FileBrowserCrumb] {
        var crumbs = [FileBrowserCrumb(title: "Workspace", location: .workspace)]
        guard case .folder(let url) = location, let root = root(containing: url, in: roots) else { return crumbs }
        crumbs.append(FileBrowserCrumb(title: root.name, location: .folder(root.url)))
        let rest = String(key(url).dropFirst(root.key.count)).split(separator: "/")
        var current = root.url
        for part in rest {
            current = current.appendingPathComponent(String(part), isDirectory: true)
            crumbs.append(FileBrowserCrumb(title: String(part), location: .folder(current)))
        }
        return crumbs
    }

    /// "Reveal in File Tree" (DEC-008): `filter` with only the choices turned off that would hide `url`, and
    /// the name query cleared. A place is never hidden.
    static func relaxing(_ filter: FileBrowserFilter, toShow url: URL, source: FileBrowserSource) -> FileBrowserFilter {
        var filter = filter
        filter.query = ""
        guard !source.roots.contains(where: { $0.key == key(url) }) else { return filter }
        let item = entry(for: url, source: source)
        let chain = ancestors(of: url, roots: source.roots).dropFirst().map { entry(for: $0, source: source) } + [item]
        if chain.contains(where: \.isHidden) { filter.showHidden = true }
        if chain.contains(where: { source.isIgnored($0.url, $0.isDirectory) }) { filter.hideIgnored = false }
        if !passesCategory(item, filter.category) { filter.category = .all }
        return filter
    }

    /// Runs `search` off the main actor; cancelling the calling task stops the walk between folders.
    static func searchInBackground(source: FileBrowserSource) async -> FileBrowserSearchResult {
        search(source: source, isCancelled: { Task.isCancelled })
    }

    /// Every ancestor folder of `url` inside its place, outermost first, including the place's root: the
    /// folders a Tree must open to show `url`.
    static func ancestors(of url: URL, roots: [FileBrowserRoot]) -> [URL] {
        guard let root = root(containing: url, in: roots) else { return [] }
        var folders: [URL] = []
        var current = url.deletingLastPathComponent()
        while key(current).count >= root.key.count {
            folders.insert(current, at: 0)
            if key(current) == root.key { break }
            current = current.deletingLastPathComponent()
        }
        return folders
    }
}
