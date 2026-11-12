import CryptoKit
import Foundation
import CoreServices

/// Watches a project recursively without traversing its contents on every timer tick.
final class ProjectChangeMonitor {
    /// The stream retains this context, not the monitor. A queued callback therefore cannot
    /// dereference a monitor that was destroyed while its project window was closing.
    private final class Context {
        let root: String
        let includeGenerated: Bool
        let shouldInclude: (String) -> Bool
        let changed: () -> Void
        init(root: String, includeGenerated: Bool, shouldInclude: @escaping (String) -> Bool, changed: @escaping () -> Void) {
            self.root = root; self.includeGenerated = includeGenerated; self.shouldInclude = shouldInclude; self.changed = changed
        }
        func includes(_ path: String) -> Bool {
            guard (path == root || path.hasPrefix(root + "/")), shouldInclude(path) else { return false }
            if includeGenerated { return true }
            let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative == "docs/handoffs" || relative.hasPrefix("docs/handoffs/") ||
               relative == ".claude/worktrees" || relative.hasPrefix(".claude/worktrees/") { return false }
            return !relative.split(separator: "/").contains { ProjectSearchIndex.excludedDirectories.contains($0.lowercased()) }
        }
    }
    private var stream: FSEventStreamRef?

    init(root: URL, includeGenerated: Bool = false, shouldInclude: @escaping (String) -> Bool = { _ in true }, changed: @escaping () -> Void) {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        let box = Context(root: path, includeGenerated: includeGenerated, shouldInclude: shouldInclude, changed: changed)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<Context>.fromOpaque(pointer).retain().toOpaque())
            }, release: { pointer in
                guard let pointer else { return }
                Unmanaged<Context>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, rawPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as NSArray
            if paths.contains(where: { ($0 as? String).map(box.includes) ?? false }) { box.changed() }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "markview.project-change-monitor", qos: .utility))
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}

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
