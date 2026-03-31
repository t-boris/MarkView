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
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            let sorted = contents
                .filter { !$0.lastPathComponent.hasPrefix(".") } // Hide hidden files
                .sorted { a, b in
                    let aIsDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let bIsDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                    if aIsDir && !bIsDir { return true }
                    if !aIsDir && bIsDir { return false }
                    return a.lastPathComponent.lowercased() < b.lastPathComponent.lowercased()
                }

            self.children = sorted.map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileNode(url: url, isDirectory: isDir)
            }
        } catch {
            self.children = []
        }
    }

    /// Recursively build the entire tree
    static func buildTree(from url: URL) -> FileNode {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let node = FileNode(url: url, isDirectory: isDirectory)

        if isDirectory {
            node.loadChildren()
            // Optionally load one level deep
            for child in node.children ?? [] {
                if child.isDirectory {
                    child.loadChildren()
                }
            }
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
