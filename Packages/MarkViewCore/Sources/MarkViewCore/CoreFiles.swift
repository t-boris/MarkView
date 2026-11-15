import CryptoKit
import Darwin
import Foundation
import os

/// Atomic file writer with parent directory creation and POSIX permissions set before rename (`AR-24`, `FU-04`).
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL, permissions: Int16? = nil) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmpURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let mode = mode_t(permissions ?? 0o644)
        let fd = open(tmpURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
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
            // Apply explicit permissions before rename so the target never exists even momentarily with wider mode (`FU-04`).
            if permissions != nil {
                guard fchmod(fd, mode) == 0 else {
                    let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    throw err
                }
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
        let hash = CoreDigest.sha256Hex(canonicalPath).prefix(12)
        return "\(leaf)-\(hash)"
    }
}

/// Shared content hashing helpers (`AR-24`).
public enum CoreDigest {
    public static func of(_ text: String) -> String {
        sha256Hex(text)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    public static func fnv1a64Hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

/// Append-only JSON Lines file with `O_APPEND` writes and size-bounded rotation (`AR-24`, `FU-04`).
public struct RotatingJSONLinesFile: Sendable {
    public let url: URL
    public let maxBytes: Int

    public init(url: URL, maxBytes: Int = 5 * 1024 * 1024) {
        self.url = url
        self.maxBytes = max(1024, maxBytes)
    }

    public func append<T: Encodable>(_ value: T, encoder: JSONEncoder = JSONEncoder()) throws {
        let data = try encoder.encode(value)
        guard let line = String(data: data, encoding: .utf8) else { return }
        try appendLine(line)
    }

    public func appendLine(_ line: String) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var payload = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)

        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue + payload.count > maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }

        // Open with O_APPEND so concurrent/multi-writer appends never overwrite each other (`FU-04`).
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }

        let size = lseek(fd, 0, SEEK_END)
        if size > 0 {
            var lastByte: UInt8 = 0
            if pread(fd, &lastByte, 1, size - 1) == 1, lastByte != 0x0A {
                payload = Data([0x0A]) + payload
            }
        }

        let written = payload.withUnsafeBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return 0 }
            return Darwin.write(fd, base, rawBuffer.count)
        }
        guard written == payload.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func readLines() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

/// Unified `os.Logger` facade replacing ad-hoc file and `NSLog` diagnostics (`AR-24`).
public enum AppLogger {
    public static let subsystem = "com.markview.app"
    public static let workspace = Logger(subsystem: subsystem, category: "workspace")
    public static let bridge = Logger(subsystem: subsystem, category: "bridge")
    public static let ai = Logger(subsystem: subsystem, category: "ai")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let security = Logger(subsystem: subsystem, category: "security")
    public static let qa = Logger(subsystem: subsystem, category: "qa")
}
