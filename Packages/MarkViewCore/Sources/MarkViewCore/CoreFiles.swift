import CryptoKit
import Darwin
import Foundation

/// Atomic file writer (`AR-24`, `FU-04`, `FU-23`): the data is written to a private temporary file that already has the
/// final mode and metadata, then renamed over the target in one step, so a reader sees the old file or the new one and
/// never a partial write.
///
/// - A symbolic link is followed: the file it points at is replaced and the link stays a link.
/// - The temporary file lives in the volume's item replacement directory (`FileManager.url(for: .itemReplacementDirectory)`,
///   on the target's volume so the rename stays atomic), never next to the target: file watchers and `git status` of the
///   target's folder do not see it, and it is removed on every exit. A crash leaves it in the system's temporary area.
/// - An existing file keeps its extended attributes (quarantine, Finder tags) and ACL; a new file gets none.
/// - The mode is set before the rename, so a file never exists with a mode weaker than the one requested (`FU-04`).
/// - The rename gives the file a new inode: other hard links to the old file keep its old content.
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL, permissions: Int16? = nil) throws {
        let fm = FileManager.default
        let target = try resolvingSymbolicLinks(url)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        var existingStat = stat()
        let exists = stat(target.path, &existingStat) == 0
        let targetMode = permissions.map { mode_t($0) } ?? (exists ? existingStat.st_mode & 0o777 : mode_t(0o644))

        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let tmpURL = scratch.appendingPathComponent(target.lastPathComponent)
        let fd = Darwin.open(tmpURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var closed = false
        do {
            if exists { copyMetadata(from: target.path, to: fd) }
            // Apply target permissions before rename so atomic overwrites never weaken existing or requested modes (`FU-04`).
            guard Darwin.fchmod(fd, targetMode) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let n = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += n
                }
            }
            _ = Darwin.fsync(fd)
            closed = true
            guard Darwin.close(fd) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if !closed { Darwin.close(fd) }
            throw error
        }

        guard Darwin.rename(tmpURL.path, target.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func write(_ text: String, to url: URL, permissions: Int16? = nil) throws {
        try write(Data(text.utf8), to: url, permissions: permissions)
    }

    /// The file `url` stands for: a link as the last component is replaced by what it points at, until the last component
    /// is not a link. The folder is resolved physically at every step, so a relative link is read from where the link
    /// really is. A link to a missing file resolves to where that file would be created, as a shell redirect does.
    private static func resolvingSymbolicLinks(_ url: URL) throws -> URL {
        let fm = FileManager.default
        var current = url
        for _ in 0..<32 { // the depth at which the kernel itself reports a loop of links
            let folder = physicalPath(current.deletingLastPathComponent().path) ?? current.deletingLastPathComponent().path
            let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
            let candidate = folderURL.appendingPathComponent(current.lastPathComponent)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: candidate.path) else { return candidate }
            current = URL(fileURLWithPath: destination, relativeTo: folderURL).absoluteURL
        }
        throw POSIXError(.ELOOP)
    }

    /// Extended attributes and ACL, byte for byte (`copyfile` would rewrite the quarantine record). Best effort: a file
    /// whose attributes cannot be copied is still saved.
    private static func copyMetadata(from source: String, to fd: Int32) {
        if let acl = acl_get_file(source, ACL_TYPE_EXTENDED) {
            _ = acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED)
            acl_free(UnsafeMutableRawPointer(acl))
        }
        let listSize = listxattr(source, nil, 0, 0)
        guard listSize > 0 else { return }
        var list = [CChar](repeating: 0, count: listSize)
        guard listxattr(source, &list, listSize, 0) == listSize else { return }
        for nameBytes in list.split(separator: 0) {
            let name = String(decoding: nameBytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let valueSize = getxattr(source, name, nil, 0, 0, 0)
            guard valueSize >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: valueSize)
            guard getxattr(source, name, &value, valueSize, 0, 0) == valueSize else { continue }
            _ = fsetxattr(fd, name, value, valueSize, 0, 0)
        }
    }

    private static func physicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Canonical project path utilities with symlink-resolving containment checks (`AR-24`, `AR-38`).
public enum ProjectPaths {
    /// Returns the standardized, symlink-resolved URL. If the leaf does not exist yet,
    /// resolves symlinks on the nearest existing ancestor directory and appends the remaining components.
    public static func canonical(_ url: URL) -> URL {
        let std = url.standardizedFileURL
        let fm = FileManager.default
        if fm.fileExists(atPath: std.path) {
            return std.resolvingSymlinksInPath()
        }
        var current = std
        var trailing: [String] = []
        while !fm.fileExists(atPath: current.path) && current.path != "/" {
            trailing.append(current.lastPathComponent)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        var resolved = current.resolvingSymlinksInPath()
        for part in trailing.reversed() {
            resolved.appendPathComponent(part)
        }
        return resolved.standardizedFileURL
    }

    /// True when `url` resolves inside `root` (or equals `root`) after resolving symlinks (`AR-24`).
    public static func contains(_ url: URL, root: URL) -> Bool {
        let base = canonical(root).path
        let target = canonical(url).path
        if target == base { return true }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return target.hasPrefix(prefix)
    }

    /// True when `url` resolves strictly inside `root`: under it, and not `root` itself (`AR-24`).
    public static func containsStrictly(_ url: URL, root: URL) -> Bool {
        relativePath(of: url, under: root)?.isEmpty == false
    }

    /// Relative path of `url` under `root` if `contains(url, root: root)` holds; nil otherwise.
    public static func relativePath(of url: URL, under root: URL) -> String? {
        let base = canonical(root).path
        let target = canonical(url).path
        if target == base { return "" }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    /// Stable, collision-free per-project cache identifier derived from canonical path SHA-256 (`AR-38`).
    public static func projectCacheIdentifier(for root: URL) -> String {
        let canonicalPath = canonical(root).path
        let leaf = URL(fileURLWithPath: canonicalPath).lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let hash = SHA256.hash(data: Data(canonicalPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
        return "\(leaf)-\(hash)"
    }
}

// MARK: - Where MarkView keeps its own files in a project (AR-24)

/// The one place that names the folders and files MarkView keeps inside a project. A `".dde` or `".markview-` literal anywhere
/// else is a finding (tools/lint/architecture-lint.sh, rule `project-paths`): add the location here, with a test in
/// MarkViewCoreTests that asserts its relative path.
extension ProjectPaths {
    /// MarkView's local folder in a project: caches, run records and the stores that are never committed.
    public static let localFolderName = ".dde"
    /// The folder the Recursive Insight pages are written to.
    public static let insightFolderName = ".markview-insight"

    // MARK: Relative paths (prose, pickers, stored relative names)

    public static let workflowRelativePath = localFolderName + "/workflow/workflow.json"
    public static let githubConnectionRelativePath = localFolderName + "/github-connection.json"
    public static let studioRelativePath = localFolderName + "/studio"
    public static let studioAttachmentsRelativePath = studioRelativePath + "/attachments"
    public static let studioTitaniumDataRelativePath = studioRelativePath + "/titanium-data"
    public static let legacyPrototypesRelativePath = localFolderName + "/prototypes"
    public static let prototypeExportsRelativePath = localFolderName + "/exports/prototypes"
    public static let cockpitRelativePath = localFolderName + "/cockpit"

    /// The relative path of a UI Studio capture picture.
    public static func studioCaptureRelativePath(id: String) -> String { studioRelativePath + "/captures/\(id).png" }

    // MARK: Folders and files under `.dde`

    public static func localFolder(_ root: URL) -> URL { root.appendingPathComponent(localFolderName, isDirectory: true) }
    public static func workflowFile(_ root: URL) -> URL { root.appendingPathComponent(workflowRelativePath) }
    public static func lifecycleFolder(_ root: URL) -> URL { localFolder(root).appendingPathComponent("lifecycle", isDirectory: true) }
    public static func cycleTimeFile(_ root: URL) -> URL { lifecycleFolder(root).appendingPathComponent("cycle-time.json") }
    public static func transitionsLog(_ root: URL) -> URL { lifecycleFolder(root).appendingPathComponent("transitions.jsonl") }
    public static func sessionsLog(_ root: URL) -> URL { lifecycleFolder(root).appendingPathComponent("sessions.jsonl") }
    public static func qaFolder(_ root: URL) -> URL { localFolder(root).appendingPathComponent("qa", isDirectory: true) }
    public static func studioFolder(_ root: URL) -> URL { root.appendingPathComponent(studioRelativePath, isDirectory: true) }
    public static func cockpitFolder(_ root: URL) -> URL { root.appendingPathComponent(cockpitRelativePath, isDirectory: true) }
    public static func cockpitRunsFolder(_ root: URL) -> URL { cockpitFolder(root).appendingPathComponent("runs", isDirectory: true) }
    public static func cockpitResultsFolder(_ root: URL) -> URL { cockpitFolder(root).appendingPathComponent("results", isDirectory: true) }
    public static func cockpitTemporalFolder(_ root: URL) -> URL { cockpitFolder(root).appendingPathComponent("temporal", isDirectory: true) }
    public static func discussionsFolder(_ root: URL) -> URL { localFolder(root).appendingPathComponent("discussions", isDirectory: true) }
    public static func understandingFolder(_ root: URL) -> URL { localFolder(root).appendingPathComponent("understanding", isDirectory: true) }
    public static func xrayFoldersFolder(_ root: URL) -> URL { localFolder(root).appendingPathComponent("xray-folders", isDirectory: true) }
    public static func cacheFolder(_ root: URL) -> URL { localFolder(root).appendingPathComponent("cache", isDirectory: true) }
    public static func xrayCacheFolder(_ root: URL) -> URL { cacheFolder(root).appendingPathComponent("xray", isDirectory: true) }
    public static func xrayContentFolder(_ root: URL) -> URL { cacheFolder(root).appendingPathComponent("xray-content", isDirectory: true) }
    public static func explainCacheFolder(_ root: URL) -> URL { cacheFolder(root).appendingPathComponent("explain", isDirectory: true) }
    public static func insightFolder(_ root: URL) -> URL { root.appendingPathComponent(insightFolderName, isDirectory: true) }

    // MARK: Placeholder names

    /// The name of a tab that has no file behind it ("never read or written"): `.markview-<kind>`.
    public static func placeholderName(_ kind: String) -> String { ".markview-" + kind }

    /// The path of a tool's sentinel file, relative to the project: `.dde/.markview-<tool>`.
    public static func sentinelRelativePath(_ tool: String) -> String { localFolderName + "/" + placeholderName(tool) }

    /// True when `url` is the local folder or lies inside one: some ancestor is named `.dde`.
    public static func isInLocalFolder(_ url: URL) -> Bool { url.pathComponents.contains(localFolderName) }
}
