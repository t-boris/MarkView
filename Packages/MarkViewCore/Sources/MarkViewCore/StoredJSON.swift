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
        let descriptor = open(url.path, O_RDWR | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var data = line
        let size = lseek(descriptor, 0, SEEK_END)
        if size > 0 {
            var last: UInt8 = 0
            if pread(descriptor, &last, 1, size - 1) == 1, last != 0x0A { data = Data([0x0A]) + line }
        }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
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
