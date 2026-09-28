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
    private static let maximumReviewBytes = 524_288

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
        var result: [String: FileState] = [:]
        while let url = enumerator.nextObject() as? URL {
            try Task<Never, Never>.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                                   .isSymbolicLinkKey, .fileSizeKey,
                                                                   .contentModificationDateKey, .fileResourceIdentifierKey]) else { continue }
            if values.isDirectory == true {
                if Self.excludedDirectories.contains(url.lastPathComponent.lowercased()) ||
                    url.standardizedFileURL.path == project.standardizedFileURL.appendingPathComponent("docs/handoffs").path {
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
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            var hasher = SHA256()
            var captured = Data()
            let readable = ProjectSearchIndex.textExtensions.contains(url.pathExtension.lowercased()) ||
                ProjectSearchIndex.textNames.contains(name)
            let capture = readable && fileSize <= Self.maximumReviewBytes
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
                if capture { captured.append(chunk) }
            }
            result[path] = FileState(hash: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                                     text: capture ? String(data: captured, encoding: .utf8) : nil,
                                     size: fileSize, modified: values.contentModificationDate,
                                     identifier: identifier)
        }
        return result
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
