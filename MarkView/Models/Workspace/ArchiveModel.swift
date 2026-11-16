import AppKit
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What an archive tab shows: its entries as a tree, searchable; a click opens a file from it in a
/// viewer (a temporary copy), and the archive can be unpacked next to itself or elsewhere.
@MainActor
final class ArchiveModel: ObservableObject {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    struct Row: Identifiable {
        let id: String
        let entry: ArchiveEntry
        let depth: Int
        /// The label: the name in the tree, the whole path in a search.
        let title: String
        let isDirectory: Bool
        let expanded: Bool
    }

    let url: URL
    @Published private(set) var phase = Phase.loading
    @Published private(set) var entries: [ArchiveEntry] = []
    @Published private(set) var rows: [Row] = []
    @Published var filter = "" { didSet { rebuild() } }
    @Published private(set) var expanded: Set<String> = []
    /// The entry being unpacked for a look, and a line about the last extraction.
    @Published private(set) var opening: String?
    @Published private(set) var busy: String?
    @Published var notice: String?
    @Published var error: String?
    private(set) var extractedTo: URL?
    /// The unpacking this archive started: it ends with the tab (the model is released), and a new one replaces its own kind (`AR-19`).
    private let tasks = TaskBag()

    init(url: URL) { self.url = url }

    var files: Int { entries.filter { !$0.isDirectory }.count }
    var folders: Int { entries.filter(\.isDirectory).count }
    var unpackedBytes: Int64 { entries.reduce(0) { $0 + $1.size } }
    var unsafeCount: Int { entries.filter { !$0.isSafe }.count }
    var archiveBytes: Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    func load() async {
        phase = .loading
        let url = url
        let result = await Task.detached(priority: .userInitiated) { Result { try Archive.list(url) } }.value
        switch result {
        case .success(let list):
            entries = list
            // Folders the archive does not list on their own still need a row.
            expanded = Set(topLevelFolders(list))
            phase = .loaded
            rebuild()
        case .failure(let failure):
            phase = .failed(failure.localizedDescription)
        }
    }

    private func topLevelFolders(_ list: [ArchiveEntry]) -> [String] {
        // A single top folder (most archives) opens at once; otherwise everything starts closed.
        let tops = Set(list.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        return tops.count == 1 && list.contains(where: { $0.path.contains("/") }) ? Array(tops) : []
    }

    func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        rebuild()
    }

    private func rebuild() {
        guard phase == .loaded else { return }
        let query = filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            rows = entries.filter { !$0.isDirectory && $0.path.localizedCaseInsensitiveContains(query) }.prefix(2000).map {
                Row(id: $0.path, entry: $0, depth: 0, title: $0.path, isDirectory: false, expanded: false)
            }
            return
        }
        // Directories, listed or implied, and files, in path order with folders before files at each level.
        var folders: [String: ArchiveEntry] = [:]
        var children: [String: [ArchiveEntry]] = [:]
        for entry in entries {
            let parts = entry.path.split(separator: "/").map(String.init)
            for depth in 1..<max(parts.count, 1) {
                let folder = parts[..<depth].joined(separator: "/")
                if folders[folder] == nil {
                    folders[folder] = ArchiveEntry(path: folder, isDirectory: true, isSymlink: false, size: 0, modified: "")
                    children[parent(of: folder), default: []].append(folders[folder]!)
                }
            }
            if entry.isDirectory {
                if folders[entry.path] == nil { folders[entry.path] = entry; children[parent(of: entry.path), default: []].append(entry) }
            } else {
                children[parent(of: entry.path), default: []].append(entry)
            }
        }
        var out: [Row] = []
        func walk(_ folder: String, depth: Int) {
            let list = (children[folder] ?? []).sorted {
                $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            for entry in list {
                let open = entry.isDirectory && expanded.contains(entry.path)
                out.append(Row(id: entry.path, entry: entry, depth: depth, title: entry.name, isDirectory: entry.isDirectory, expanded: open))
                if open { walk(entry.path, depth: depth + 1) }
            }
        }
        walk("", depth: 0)
        rows = out
    }

    private func parent(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// Unpack one file to the cache and hand it to `open` (a viewer).
    func open(_ entry: ArchiveEntry, _ open: @escaping (URL) -> Void) {
        guard opening == nil else { return }
        opening = entry.path
        error = nil
        let url = url
        tasks.store(Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try Archive.extractEntry(entry, from: url) } }.value
            guard let self, !Task.isCancelled else { return }
            opening = nil
            switch result {
            case .success(let copy): open(copy)
            case .failure(let failure): error = failure.localizedDescription
            }
        }, for: "open")
    }

    /// Unpack everything into a new folder; `parent` nil = next to the archive.
    func extract(into parent: URL?, done: @escaping (URL) -> Void) {
        guard busy == nil else { return }
        busy = "Extracting \(files) files…"
        error = nil
        notice = nil
        let url = url, list = entries
        tasks.store(Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                let folder = Archive.uniqueFolder(for: url, in: parent)
                return Result { try Archive.extractAll(url, to: folder, entries: list); return folder }
            }.value
            guard let self, !Task.isCancelled else { return }
            busy = nil
            switch result {
            case .success(let folder):
                extractedTo = folder
                notice = "Extracted \(files) files to \(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
                done(folder)
            case .failure(let failure): error = failure.localizedDescription
            }
        }, for: "extract")
    }

    func showExtracted() {
        if let extractedTo { NSWorkspace.shared.activateFileViewerSelecting([extractedTo]) }
    }
}
