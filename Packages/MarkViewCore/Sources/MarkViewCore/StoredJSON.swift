import CryptoKit
import Darwin
import Foundation

/// Reading JSON that the app stored itself (`AR-36`): the reads that are not a whole versioned file (`SchemaVersionedStore`).
///
/// A stored value that cannot be decoded is never silently "absent": the failure is logged with what is wrong with it (a key, a
/// type; never any of its content), and the caller decides what a miss means. A cache or a derived column reads as a miss and is
/// rebuilt; a record the person made is kept by its own store before anything replaces it.
public enum StoredJSON {
    /// What is wrong with a document that did not decode, in words a log or a notice can carry. Never any of its content.
    public static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, _): return "\"\(key.stringValue)\" is missing"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }

    /// `data` as a `T`, or nil with one log line when it cannot be decoded. `owner` names the reader in the log.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, using decoder: JSONDecoder = JSONDecoder(), owner: String) -> T? {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            AppLog.store.warning("\(owner): stored data cannot be decoded (\(describe(error))); it is read as absent")
            return nil
        }
    }
}

/// An append-only JSON-lines file: one JSON object per line, written by the journals and logs (`AR-24`, `AR-36`).
public enum JSONLinesFile {
    /// Adds one line with a single `O_APPEND` write, so two writers (two windows on one project) never overwrite each other. A
    /// line that an earlier, interrupted write left without its newline is ended first, so the new line stands on its own.
    public static func append(_ line: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_RDWR | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var data = line
        let size = Darwin.lseek(descriptor, 0, SEEK_END)
        if size > 0 {
            var last: UInt8 = 0
            if Darwin.pread(descriptor, &last, 1, size - 1) == 1, last != 0x0A { data = Data([0x0A]) + line }
        }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// The records of `text`, oldest first, and how many lines could not be read. A line that does not decode (damaged by an
    /// interrupted write, or made by another version of the app) is skipped and stays in the file: a reader never rewrites a log
    /// from what it decoded. The count is logged once per call, never the lines themselves. Blank lines are not lines. `last`
    /// reads only that many of the final lines (a long log of which a window shows the tail).
    public static func decode<T: Decodable>(_ type: T.Type, from text: String, using decoder: JSONDecoder, owner: String,
                                            last: Int? = nil) -> (records: [T], skipped: Int) {
        var records: [T] = []
        var skipped = 0
        var firstProblem: String?
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        for line in last.map({ lines.suffix($0) }) ?? lines[...] {
            do {
                records.append(try decoder.decode(type, from: Data(line.utf8)))
            } catch {
                skipped += 1
                firstProblem = firstProblem ?? StoredJSON.describe(error)
            }
        }
        if skipped > 0 {
            AppLog.store.warning("\(owner): \(skipped) line(s) of the log cannot be read and are skipped (\(firstProblem ?? "unknown")); they stay in the file")
        }
        return (records, skipped)
    }
}

/// The dated copy that a store keeps of a file or a record it could not read, before anything replaces it (`AR-36`).
public enum UnreadableCopy {
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    /// `<name>.corrupt-<yyyyMMddHHmmss>-<suffix>`: sorts by time, and the suffix keeps two copies of the same second apart.
    public static func name(of name: String, at date: Date = Date(), suffix: String) -> String {
        "\(name).corrupt-\(stampFormatter.string(from: date))-\(suffix)"
    }

    /// The copy of the file at `url`, next to it.
    public static func url(of url: URL, suffix: String = UUID().uuidString.prefix(8).lowercased()) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(name(of: url.lastPathComponent, suffix: suffix))
    }
}

/// A JSON record kept in the preferences (a setting whose value is `Data`, or an entry of a dictionary setting): the preferences'
/// counterpart of `SchemaVersionedStore` (`AR-36`). A record that is there but cannot be read is not "none": it is logged and a copy
/// of its bytes is written to `folder` (once per distinct content) before the next save replaces it, so a corrupted value, or one
/// written by another version of the app, can be recovered by hand.
public enum PreferenceRecord {
    /// Where the copies go: `Application Support/MarkView/Unreadable`.
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkView", isDirectory: true).appendingPathComponent("Unreadable", isDirectory: true)
    }

    /// `data` as a `T`, or nil with a log line and a kept copy when it cannot be decoded. `name` says which record it is (a file name
    /// part: letters, digits and dashes).
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, name: String, using decoder: JSONDecoder = JSONDecoder(),
                                            keepIn folder: URL = defaultFolder) -> T? {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            AppLog.store.error("\(name): the stored record cannot be read (\(StoredJSON.describe(error))); a copy is kept before it is replaced")
            keepCopy(of: data, name: name, in: folder)
            return nil
        }
    }

    /// The copies kept for `name` in `folder`, oldest first.
    public static func copies(named name: String, in folder: URL = defaultFolder) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(name + ".corrupt-") }.sorted()
            .map { folder.appendingPathComponent($0) }
    }

    private static func keepCopy(of data: Data, name: String, in folder: URL) {
        let fingerprint = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        guard !copies(named: name, in: folder).contains(where: { $0.lastPathComponent.hasSuffix("-" + fingerprint) }) else { return }
        do {
            try AtomicFile.write(data, to: folder.appendingPathComponent(UnreadableCopy.name(of: name, suffix: fingerprint)))
        } catch {
            AppLog.store.error("\(name): a copy of the unreadable record could not be kept: \(error.localizedDescription)")
        }
    }
}

/// A JSON file that the app writes and people also read, edit and commit with the project (a prototype's manifest, a Studio
/// scenario, a handoff record): the plain-file counterpart of `SchemaVersionedStore` (`AR-36`). It has no envelope, so that a
/// teammate's older MarkView and a text editor still read it; a file that carries a version field of its own can name it.
///
/// A file that is there but cannot be used is not "none": the read says so, and a write copies it to a dated backup before it
/// replaces it, or refuses when a newer MarkView wrote it. The copies and the refusal follow `SchemaVersionedStore`.
public enum PlainJSONFile {
    /// The version field some of these files carry (`version`, `schemaVersion`) and the newest value this build writes.
    public struct VersionField: Sendable {
        public let key: String
        public let supported: Int
        public init(_ key: String, supported: Int) {
            self.key = key
            self.supported = supported
        }
    }

    public enum Read<T> {
        case loaded(T)
        case missing
        /// The file is there and cannot be decoded; the reason names the key or the type, never any content.
        case unreadable(String)
        /// The file's version field is newer than this build writes.
        case newer(Int)

        public var value: T? {
            if case .loaded(let value) = self { return value }
            return nil
        }
    }

    public struct NewerVersion: LocalizedError, Equatable {
        public let url: URL
        public let found: Int
        public let supported: Int
        public var errorDescription: String? {
            "\(url.lastPathComponent) was written by a newer MarkView (version \(found), this one writes \(supported)); it is left untouched."
        }
    }

    /// The file at `url` as a `T`. A file that cannot be used is logged once per call, tagged with `owner`.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL, using decoder: JSONDecoder = JSONDecoder(),
                                          version: VersionField? = nil, owner: String) -> Read<T> {
        let result = inspect(type, at: url, using: decoder, version: version)
        switch result {
        case .unreadable(let reason):
            AppLog.store.error("\(owner): \(url.lastPathComponent) cannot be read (\(reason)); it is kept as it is and copied to a backup before anything replaces it")
        case .newer(let found):
            AppLog.store.error("\(owner): \(url.lastPathComponent) was written by a newer MarkView (version \(found)); it is left untouched")
        case .loaded, .missing:
            break
        }
        return result
    }

    /// Writes `data` (the encoded value) to `url`. A file already there that was written by a newer MarkView is not touched
    /// (`NewerVersion`); one that cannot be decoded as a `T` is copied to a dated backup first, and nothing is replaced when the
    /// copy cannot be made.
    public static func write<T: Decodable>(_ data: Data, replacing type: T.Type, at url: URL, using decoder: JSONDecoder = JSONDecoder(),
                                           version: VersionField? = nil, owner: String) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            switch inspect(type, at: url, using: decoder, version: version) {
            case .newer(let found):
                AppLog.store.error("\(owner): \(url.lastPathComponent) was written by a newer MarkView (version \(found)); it is not replaced")
                throw NewerVersion(url: url, found: found, supported: version?.supported ?? 0)
            case .unreadable(let reason):
                let copy = UnreadableCopy.url(of: url)
                try FileManager.default.copyItem(at: url, to: copy)
                AppLog.store.error("\(owner): \(url.lastPathComponent) could not be read (\(reason)); it is copied to \(copy.lastPathComponent) before it is replaced")
            case .loaded, .missing:
                break
            }
        }
        try AtomicFile.write(data, to: url)
    }

    private static func inspect<T: Decodable>(_ type: T.Type, at url: URL, using decoder: JSONDecoder, version: VersionField?) -> Read<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .unreadable(error.localizedDescription) }
        if let version, let found = storedVersion(in: data, key: version.key), found > version.supported { return .newer(found) }
        do { return .loaded(try decoder.decode(type, from: data)) } catch { return .unreadable(StoredJSON.describe(error)) }
    }

    /// The integer under `key` at the top level of the document, nil when there is none (or the document is not an object).
    private static func storedVersion(in data: Data, key: String) -> Int? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?[key] as? Int
    }
}
