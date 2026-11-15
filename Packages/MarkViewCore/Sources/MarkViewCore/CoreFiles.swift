import CryptoKit
import Darwin
import Foundation

/// Atomic file writer with parent directory creation and POSIX permissions set before rename (`AR-24`, `FU-04`).
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL, permissions: Int16? = nil) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var existingStat = stat()
        let preservedMode: mode_t? = (permissions == nil && stat(url.path, &existingStat) == 0)
            ? (existingStat.st_mode & 0o777)
            : nil
        let targetMode = permissions.map { mode_t($0) } ?? preservedMode ?? mode_t(0o644)

        let tmpURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tmpURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, targetMode)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var cleanupTmp = true
        defer {
            if cleanupTmp {
                unlink(tmpURL.path)
            }
        }

        var closed = false
        do {
            // Apply target permissions before rename so atomic overwrites never weaken existing or requested modes (`FU-04`).
            guard fchmod(fd, targetMode) == 0 else {
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
            _ = fsync(fd)
            closed = true
            guard close(fd) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if !closed { close(fd) }
            throw error
        }

        guard rename(tmpURL.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        cleanupTmp = false
    }

    public static func write(_ text: String, to url: URL, permissions: Int16? = nil) throws {
        try write(Data(text.utf8), to: url, permissions: permissions)
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
