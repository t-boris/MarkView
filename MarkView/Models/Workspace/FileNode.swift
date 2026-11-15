import Foundation
import SwiftUI

/// Sort field for file tree
enum FileTreeSortField: String, CaseIterable {
    case name = "Name"
    case dateModified = "Date Modified"
}

/// Sort order for file tree
struct FileTreeSortOrder: Equatable {
    var field: FileTreeSortField = .name
    var ascending: Bool = true
}

/// A folder as read off the main thread: a plain value that can cross to the main actor, where `FileNode(tree)` makes the
/// nodes the views observe. A listing holds the immediate children only; an expansion that is restored lists the expanded
/// folders too.
struct FileTree: Sendable {
    let url: URL
    let isDirectory: Bool
    var isExpanded = false
    /// nil for a file; empty for a folder that has not been listed.
    var children: [FileTree]?

    init(url: URL, isDirectory: Bool) {
        self.url = url.standardizedFileURL
        self.isDirectory = isDirectory
        self.children = isDirectory ? [] : nil
    }

    var id: String { url.path }

    /// The tree of `url` with only the root's immediate children listed.
    static func build(from url: URL, sortOrder: FileTreeSortOrder = FileTreeSortOrder()) -> FileTree {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        var tree = FileTree(url: url, isDirectory: isDirectory)
        if isDirectory { tree.children = listing(of: tree.url, sortOrder: sortOrder) }
        return tree
    }

    /// The openable files and the folders in `url`, folders first, in the order of `sortOrder`; empty when the folder cannot be read.
    static func listing(of url: URL, sortOrder: FileTreeSortOrder) -> [FileTree] {
        do {
            let needsDate = sortOrder.field == .dateModified
            let prefetchKeys: [URLResourceKey] = needsDate
                ? [.isDirectoryKey, .contentModificationDateKey]
                : [.isDirectoryKey]
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: prefetchKeys)

            let items: [(url: URL, isDir: Bool, modDate: Date?)] = contents.compactMap { itemURL in
                let vals = try? itemURL.resourceValues(forKeys: Set(prefetchKeys))
                let isDir = vals?.isDirectory ?? false
                guard isDir || FileType.isOpenable(itemURL) else { return nil }
                return (itemURL, isDir, vals?.contentModificationDate)
            }

            let asc = sortOrder.ascending
            let sorted = items.sorted { a, b in
                if a.isDir && !b.isDir { return true }
                if !a.isDir && b.isDir { return false }
                switch sortOrder.field {
                case .name:
                    let cmp = a.url.lastPathComponent.lowercased() < b.url.lastPathComponent.lowercased()
                    return asc ? cmp : !cmp
                case .dateModified:
                    let da = a.modDate ?? .distantPast
                    let db = b.modDate ?? .distantPast
                    let cmp = da < db
                    return asc ? cmp : !cmp
                }
            }

            return sorted.map { FileTree(url: $0.url, isDirectory: $0.isDir) }
        } catch {
            return []
        }
    }

    /// Restore expanded folders on a rebuilt tree without forcing unrelated folders open.
    mutating func restoreExpansion(from expandedPaths: Set<String>, sortOrder: FileTreeSortOrder = FileTreeSortOrder()) {
        guard isDirectory else { return }

        let expandedHere = expandedPaths.contains(id)
        let descendantPrefix = id + "/"
        let hasExpandedDescendant = expandedPaths.contains { $0.hasPrefix(descendantPrefix) }

        isExpanded = expandedHere

        guard expandedHere || hasExpandedDescendant else { return }

        if children?.isEmpty != false {
            children = Self.listing(of: url, sortOrder: sortOrder)
        }

        for index in children?.indices ?? 0..<0 {
            children?[index].restoreExpansion(from: expandedPaths, sortOrder: sortOrder)
        }
    }
}

/// Represents a file or folder in the workspace tree
class FileNode: Identifiable, ObservableObject, Hashable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool

    @Published var children: [FileNode]?
    @Published var isExpanded: Bool = false

    init(url: URL, isDirectory: Bool) {
        let normalizedURL = url.standardizedFileURL
        self.url = normalizedURL
        self.id = normalizedURL.path
        self.isDirectory = isDirectory
        self.name = normalizedURL.lastPathComponent

        if isDirectory {
            self.children = []
        }
    }

    /// The nodes of a tree that was read off the main thread.
    convenience init(_ tree: FileTree) {
        self.init(url: tree.url, isDirectory: tree.isDirectory)
        isExpanded = tree.isExpanded
        children = tree.children?.map { FileNode($0) }
    }

    /// Indicates if this node represents a Markdown file
    var isMarkdown: Bool {
        url.pathExtension.lowercased() == "md"
    }

    /// Load children from the file system
    func loadChildren(sortOrder: FileTreeSortOrder = FileTreeSortOrder()) {
        guard isDirectory else { return }
        children = FileTree.listing(of: url, sortOrder: sortOrder).map { FileNode($0) }
    }

    /// Build tree with only the root's immediate children loaded.
    /// Subdirectory contents are loaded on-demand when expanded.
    static func buildTree(from url: URL, sortOrder: FileTreeSortOrder = FileTreeSortOrder()) -> FileNode {
        FileNode(FileTree.build(from: url, sortOrder: sortOrder))
    }

    /// Capture expanded directory paths so a rebuilt tree can restore UI state.
    func expandedDirectoryPaths() -> Set<String> {
        guard isDirectory else { return [] }

        var paths: Set<String> = isExpanded ? [id] : []
        for child in children ?? [] {
            paths.formUnion(child.expandedDirectoryPaths())
        }
        return paths
    }

    // MARK: - Hashable Conformance

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }
}
