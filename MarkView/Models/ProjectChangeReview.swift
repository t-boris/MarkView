import CryptoKit
import Foundation

struct ProjectChange: Identifiable {
    enum Kind: String { case added, modified, deleted }
    let path: String
    let kind: Kind
    let before: String?
    let current: String?
    var id: String { path }
}

/// Tracks disk changes from the moment a project opens. The baseline is kept in
/// memory and includes small readable file contents for a side-by-side review.
/// It reports observed changes without claiming which process made them.
actor ProjectChangeScanner {
    private struct FileState {
        let hash: String
        let text: String?
        let size: Int
        let modified: Date?
        let identifier: String?
    }

    private var root: URL?
    private var baseline: [String: FileState] = [:]
    private var current: [String: FileState] = [:]
    private static let excludedDirectories = ProjectSearchIndex.excludedDirectories
    /// Folders skipped by their path in the project: hand-off packages, and the agents' git worktrees, which are whole
    /// copies of the project (BUG-083).
    static let excludedPaths = ["docs/handoffs", ".claude/worktrees"]
    private static let maximumReviewBytes = 524_288
    /// Larger files, and binary ones of any size, are not read (BUG-083): their size, date and file identity stand for
    /// their content, so opening a project costs what its text files cost, not every byte on disk.
    static let maximumHashBytes = 8 << 20

    func open(_ project: URL?) throws {
        root = project
        current = [:]
        baseline = try project.map(scan) ?? [:]
        current = baseline
    }

    func refresh() throws -> [ProjectChange] {
        guard let root else { return [] }
        current = try scan(root)
        return Set(baseline.keys).union(current.keys).compactMap { path in
            let before = baseline[path]
            let after = current[path]
            if before == nil { return ProjectChange(path: path, kind: .added, before: nil, current: after?.text) }
            if after == nil { return ProjectChange(path: path, kind: .deleted, before: before?.text, current: nil) }
            if before?.hash != after?.hash {
                return ProjectChange(path: path, kind: .modified, before: before?.text, current: after?.text)
            }
            return nil
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func acknowledge() {
        baseline = current
    }

    private func scan(_ project: URL) throws -> [String: FileState] {
        let fm = FileManager.default
        let root = project.standardizedFileURL.path + "/"
        guard let enumerator = fm.enumerator(at: project, includingPropertiesForKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .fileResourceIdentifierKey
        ]) else { return [:] }
        let skippedPaths = Set(Self.excludedPaths.map { project.standardizedFileURL.appendingPathComponent($0).path })
        var result: [String: FileState] = [:]
        while let url = enumerator.nextObject() as? URL {
            try Task<Never, Never>.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                                   .isSymbolicLinkKey, .fileSizeKey,
                                                                   .contentModificationDateKey, .fileResourceIdentifierKey]) else { continue }
            if values.isDirectory == true {
                if Self.excludedDirectories.contains(url.lastPathComponent.lowercased()) ||
                    skippedPaths.contains(url.standardizedFileURL.path) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  url.standardizedFileURL.path.hasPrefix(root) else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(root.count))
            let name = url.lastPathComponent.lowercased()
            if ProjectSearchIndex.excludedFileNames.contains(name) ||
                ProjectSearchIndex.excludedExtensions.contains(url.pathExtension.lowercased()) { continue }
            let fileSize = values.fileSize ?? 0
            let identifier = values.fileResourceIdentifier.map { String(describing: $0) }
            if let previous = current[path], previous.size == fileSize,
               previous.modified == values.contentModificationDate,
               previous.identifier == identifier {
                result[path] = previous
                continue
            }
            // The chunks a read returns are autoreleased: without a pool per file they lived until the whole walk ended,
            // which held every byte of the project at once (BUG-083).
            let state = try autoreleasepool {
                try Self.state(of: url, name: name, size: fileSize, modified: values.contentModificationDate, identifier: identifier)
            }
            if let state { result[path] = state }
        }
        return result
    }

    /// The state of one file: a SHA-256 of its content, and its text when it is small and readable; for a binary or a
    /// large file only its size, date and file identity, which change whenever its content does. Nil when it can't be read.
    private static func state(of url: URL, name: String, size: Int, modified: Date?, identifier: String?) throws -> FileState? {
        let ext = url.pathExtension.lowercased()
        if ProjectSearchIndex.binaryExtensions.contains(ext) || size > maximumHashBytes {
            let date = modified.map { String($0.timeIntervalSince1970) } ?? "-"
            return FileState(hash: "file:\(size):\(date):\(identifier ?? "-")", text: nil, size: size, modified: modified,
                             identifier: identifier)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var captured = Data()
        let readable = ProjectSearchIndex.textExtensions.contains(ext) || ProjectSearchIndex.textNames.contains(name)
        let capture = readable && size <= maximumReviewBytes
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
            if capture { captured.append(chunk) }
        }
        return FileState(hash: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                         text: capture ? String(data: captured, encoding: .utf8) : nil,
                         size: size, modified: modified, identifier: identifier)
    }
}

@MainActor
final class ProjectChangeReview: ObservableObject {
    @Published private(set) var changes: [ProjectChange] = []
    @Published private(set) var isScanning = false
    @Published var error: String?

    private let scanner = ProjectChangeScanner()

    func open(_ project: URL?) async {
        isScanning = true
        defer { isScanning = false }
        do {
            try await scanner.open(project)
            changes = []
            error = nil
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            changes = try await scanner.refresh()
            error = nil
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
    }

    func acknowledge() async {
        await scanner.acknowledge()
        changes = []
    }
}
