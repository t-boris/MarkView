import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the Contents panel says about a file: name, kind, size, dates and, by kind, text counts or
/// the pixel size of an image. Foundation and ImageIO only, so it is checked on its own
/// (`tools/tests/file-info-tests.sh`). Reading blocks: call `load` off the main thread.
struct FileInfo: Equatable {
    struct Row: Equatable, Identifiable {
        var id: String { label }
        let label: String
        let value: String
    }

    let rows: [Row]

    /// Text beyond this is not counted.
    static let maximumCountedBytes = 5 * 1_048_576

    static func load(_ url: URL) -> FileInfo {
        var rows: [Row] = []
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentTypeKey, .isDirectoryKey]
        let values = try? url.resourceValues(forKeys: keys)
        rows.append(Row(label: "Name", value: url.lastPathComponent))
        if let type = values?.contentType, let description = type.localizedDescription {
            rows.append(Row(label: "Kind", value: description))
        } else if !url.pathExtension.isEmpty {
            rows.append(Row(label: "Kind", value: url.pathExtension.uppercased() + " file"))
        }
        if let size = values?.fileSize {
            rows.append(Row(label: "Size", value: sizeString(Int64(size))))
        }
        if let modified = values?.contentModificationDate { rows.append(Row(label: "Modified", value: dateString(modified))) }
        if let created = values?.creationDate { rows.append(Row(label: "Created", value: dateString(created))) }
        if let dimensions = imageSize(url) {
            rows.append(Row(label: "Dimensions", value: "\(dimensions.width) × \(dimensions.height) px"))
        }
        if let counts = textCounts(url, size: values?.fileSize ?? 0) {
            rows.append(Row(label: "Lines", value: grouped(counts.lines)))
            rows.append(Row(label: "Words", value: grouped(counts.words)))
            rows.append(Row(label: "Characters", value: grouped(counts.characters)))
        }
        rows.append(Row(label: "Path", value: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
        return FileInfo(rows: rows)
    }

    /// "12.3 KB (12,603 bytes)".
    static func sizeString(_ bytes: Int64) -> String {
        let short = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return bytes < 1000 ? short : "\(short) (\(grouped(Int(bytes))) bytes)"
    }

    static func dateString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func grouped(_ number: Int) -> String {
        number.formatted(.number.grouping(.automatic))
    }

    static func imageSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Lines, words and characters of a UTF-8 text file; nil for anything else or beyond the size limit.
    static func textCounts(_ url: URL, size: Int) -> (lines: Int, words: Int, characters: Int)? {
        guard size <= maximumCountedBytes, let data = try? Data(contentsOf: url), !data.contains(0),
              let text = String(data: data, encoding: .utf8) else { return nil }
        if text.isEmpty { return (0, 0, 0) }
        var lines = text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        if !text.hasSuffix("\n") { lines += 1 }
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return (lines, words, text.count)
    }
}
