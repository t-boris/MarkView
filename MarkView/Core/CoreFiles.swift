import CryptoKit
import Darwin
import Foundation
import os

/// Atomic file writer with parent directory creation and optional POSIX permissions (`AR-24`).
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL, permissions: Int16? = nil) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let permissions {
            chmod(url.path, mode_t(permissions))
        }
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

/// Append-only JSON Lines file with size-bounded rotation (`AR-24`).
public struct JSONLinesFile: Sendable {
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
        let payload = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)

        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue + payload.count > maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }

        if fm.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try payload.write(to: url, options: .atomic)
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
