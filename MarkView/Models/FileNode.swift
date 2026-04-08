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

    /// Indicates if this node represents a Markdown file
    var isMarkdown: Bool {
        url.pathExtension.lowercased() == "md"
    }

    /// Load children from the file system
    func loadChildren(sortOrder: FileTreeSortOrder = FileTreeSortOrder()) {
        guard isDirectory else { return }

        let fileManager = FileManager.default
        do {
            let needsDate = sortOrder.field == .dateModified
            let prefetchKeys: [URLResourceKey] = needsDate
                ? [.isDirectoryKey, .contentModificationDateKey]
                : [.isDirectoryKey]
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: prefetchKeys)

            let items: [(url: URL, isDir: Bool, modDate: Date?)] = contents.compactMap { itemURL in
                let name = itemURL.lastPathComponent
                guard !name.hasPrefix(".") else { return nil }
                let vals = try? itemURL.resourceValues(forKeys: Set(prefetchKeys))
                let isDir = vals?.isDirectory ?? false
                let ext = itemURL.pathExtension.lowercased()
                guard isDir || FileType.supportedExtensions.contains(ext) else { return nil }
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

            self.children = sorted.map { FileNode(url: $0.url, isDirectory: $0.isDir) }
        } catch {
            self.children = []
        }
    }

    /// Build tree with only the root's immediate children loaded.
    /// Subdirectory contents are loaded on-demand when expanded.
    static func buildTree(from url: URL, sortOrder: FileTreeSortOrder = FileTreeSortOrder()) -> FileNode {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let node = FileNode(url: url, isDirectory: isDirectory)

        if isDirectory {
            node.loadChildren(sortOrder: sortOrder)
        }

        return node
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

    /// Restore expanded folders on a rebuilt tree without forcing unrelated folders open.
    func restoreExpansionState(from expandedPaths: Set<String>, sortOrder: FileTreeSortOrder = FileTreeSortOrder()) {
        guard isDirectory else { return }

        let expandedHere = expandedPaths.contains(id)
        let descendantPrefix = id + "/"
        let hasExpandedDescendant = expandedPaths.contains { $0.hasPrefix(descendantPrefix) }

        isExpanded = expandedHere

        guard expandedHere || hasExpandedDescendant else { return }

        if children?.isEmpty != false {
            loadChildren(sortOrder: sortOrder)
        }

        for child in children ?? [] {
            child.restoreExpansionState(from: expandedPaths, sortOrder: sortOrder)
        }
    }

    // MARK: - Hashable Conformance

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }
}
