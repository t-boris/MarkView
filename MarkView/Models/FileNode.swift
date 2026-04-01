import Foundation
import SwiftUI

/// Represents a file or folder in the workspace tree
class FileNode: Identifiable, ObservableObject, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool

    @Published var children: [FileNode]?
    @Published var isExpanded: Bool = false

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        self.name = url.lastPathComponent

        if isDirectory {
            self.children = []
        }
    }

    /// Indicates if this node represents a Markdown file
    var isMarkdown: Bool {
        url.pathExtension.lowercased() == "md"
    }

    /// Load children from the file system
    func loadChildren() {
        guard isDirectory else { return }

        let fileManager = FileManager.default
        do {
            // Prefetch isDirectoryKey to avoid extra syscalls during sort/map
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])

            // Build (url, isDir) pairs once, filter to relevant items only
            let items: [(url: URL, isDir: Bool)] = contents.compactMap { itemURL in
                let name = itemURL.lastPathComponent
                guard !name.hasPrefix(".") else { return nil } // Hide hidden files
                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                // Only keep directories and markdown files — UI shows nothing else
                guard isDir || itemURL.pathExtension.lowercased() == "md" else { return nil }
                return (itemURL, isDir)
            }

            let sorted = items.sorted { a, b in
                if a.isDir && !b.isDir { return true }
                if !a.isDir && b.isDir { return false }
                return a.url.lastPathComponent.lowercased() < b.url.lastPathComponent.lowercased()
            }

            self.children = sorted.map { FileNode(url: $0.url, isDirectory: $0.isDir) }
        } catch {
            self.children = []
        }
    }

    /// Build tree with only the root's immediate children loaded.
    /// Subdirectory contents are loaded on-demand when expanded.
    static func buildTree(from url: URL) -> FileNode {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let node = FileNode(url: url, isDirectory: isDirectory)

        if isDirectory {
            node.loadChildren()
        }

        return node
    }

    // MARK: - Hashable Conformance

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }
}
