import Foundation

/// One entry of an archive, as `bsdtar -tv` lists it.
struct ArchiveEntry: Identifiable, Hashable {
    var id: String { path }
    /// Path inside the archive, without a trailing slash.
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    /// Unpacked size in bytes.
    let size: Int64
    /// The date as the listing prints it ("Oct  7 12:00" or "Oct  7  2025").
    let modified: String

    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// An absolute path or a `..` component: such an entry is never read or extracted.
    var isSafe: Bool { Archive.isSafe(path) }
}

enum ArchiveError: LocalizedError, Equatable {
    case unsupported
    case tool(String)
    case unsafe(String)
    case tooLarge(String)
    case tooManyEntries(Int)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This kind of archive is not supported."
        case .tool(let message): return message.isEmpty ? "The archive could not be read." : message
        case .unsafe(let path): return "The archive holds an unsafe path (\(path)); nothing was read or written."
        case .tooLarge(let what): return what
        case .tooManyEntries(let count): return "The archive holds \(count) entries, more than MarkView opens."
        case .notFound(let path): return "\(path) is not in the archive."
        }
    }
}

/// Reading, extracting and making archives with the system's `bsdtar` and `zip` (no library). Every
/// function blocks: call them off the main thread. Nothing in an archive is ever run.
enum Archive {
    static let extensions: Set<String> = ["zip", "tar", "tgz", "tbz2", "txz", "7z", "rar", "jar"]
    static let compoundSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz"]

    static let maxEntries = 200_000
    /// One entry opened for a look.
    static let maxPreviewBytes: Int64 = 100 * 1024 * 1024
    /// Everything an archive may unpack to (a guard against zip bombs).
    static let maxExtractBytes: Int64 = 4 * 1024 * 1024 * 1024

    static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return extensions.contains(url.pathExtension.lowercased()) || compoundSuffixes.contains { name.hasSuffix($0) }
    }

    /// The name without the archive extension: "photos.tar.gz" → "photos".
    static func baseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in compoundSuffixes where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        if extensions.contains(url.pathExtension.lowercased()) { name = (name as NSString).deletingPathExtension }
        return name
    }

    // MARK: Safety

    /// A relative path that stays inside the folder it is written to.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    // MARK: Listing

    static func list(_ archive: URL) throws -> [ArchiveEntry] {
        guard isArchive(archive) else { throw ArchiveError.unsupported }
        let result = run("/usr/bin/bsdtar", ["-tvf", archive.path])
        guard result.status == 0 else { throw ArchiveError.tool(result.error) }
        let entries = parse(listing: result.output)
        if entries.count > maxEntries { throw ArchiveError.tooManyEntries(entries.count) }
        return entries
    }

    /// `-rw-r--r--  0 user group  1234 Oct  7 12:00 dir/file name.txt`
    static func parse(listing: String) -> [ArchiveEntry] {
        listing.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            // Eight columns, then the name (which may hold spaces).
            var index = line.startIndex
            var columns: [Substring] = []
            while columns.count < 8, index < line.endIndex {
                while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
                let start = index
                while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
                if start < index { columns.append(line[start..<index]) }
            }
            guard columns.count == 8, let size = Int64(columns[4]), let kind = columns[0].first else { return nil }
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            var path = String(line[index...])
            let isSymlink = kind == "l"
            if isSymlink, let arrow = path.range(of: " -> ") { path = String(path[..<arrow.lowerBound]) }
            let isDirectory = kind == "d" || path.hasSuffix("/")
            while path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty else { return nil }
            return ArchiveEntry(path: path, isDirectory: isDirectory, isSymlink: isSymlink, size: size,
                                modified: columns[5...7].joined(separator: " "))
        }
    }

    // MARK: Reading one entry

    /// Where the copies of entries opened for a look are kept (temporary; macOS clears it).
    static var cacheRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MarkViewArchives", isDirectory: true)
    }

    /// Unpack one entry to the cache and return the copy. Folders, links and unsafe or large entries are refused.
    static func extractEntry(_ entry: ArchiveEntry, from archive: URL) throws -> URL {
        guard entry.isSafe else { throw ArchiveError.unsafe(entry.path) }
        guard !entry.isDirectory, !entry.isSymlink else { throw ArchiveError.notFound(entry.path) }
        guard entry.size <= maxPreviewBytes else {
            throw ArchiveError.tooLarge("\(entry.name) is \(entry.size / 1_048_576) MB, too large to open from the archive. Extract the archive instead.")
        }
        let values = try? archive.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = "\(archive.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        let folder = cacheRoot.appendingPathComponent(String(fnv(stamp)), isDirectory: true)
        let target = folder.appendingPathComponent(entry.path)
        guard target.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { throw ArchiveError.unsafe(entry.path) }
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: target) else { throw ArchiveError.tool("Could not write \(target.lastPathComponent).") }
        let result = run("/usr/bin/bsdtar", ["-xOf", archive.path, "--", escaped(entry.path)], stdout: handle)
        try? handle.close()
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: target)
            throw ArchiveError.tool(result.error)
        }
        return target
    }

    // MARK: Extracting

    /// A folder next to the archive named after it, "name 2" when taken.
    static func uniqueFolder(for archive: URL, in parent: URL? = nil) -> URL {
        let base = parent ?? archive.deletingLastPathComponent()
        let name = baseName(archive)
        var candidate = base.appendingPathComponent(name, isDirectory: true)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent("\(name) \(number)", isDirectory: true)
            number += 1
        }
        return candidate
    }

    /// Unpack everything into `folder` (made new; an existing folder is never written into). The whole
    /// archive is refused when any path is unsafe or it would unpack to more than `maxExtractBytes`.
    @discardableResult
    static func extractAll(_ archive: URL, to folder: URL, entries: [ArchiveEntry]? = nil) throws -> Int {
        let entries = try entries ?? list(archive)
        if let bad = entries.first(where: { !$0.isSafe }) { throw ArchiveError.unsafe(bad.path) }
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total <= maxExtractBytes else {
            throw ArchiveError.tooLarge("The archive unpacks to \(total / 1_048_576) MB, more than MarkView extracts (\(maxExtractBytes / 1_048_576) MB).")
        }
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw ArchiveError.tool("\(folder.lastPathComponent) already exists.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = run("/usr/bin/bsdtar", ["-xf", archive.path, "-C", folder.path, "--no-same-owner", "--no-same-permissions"])
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw ArchiveError.tool(result.error)
        }
        return entries.filter { !$0.isDirectory }.count
    }

    // MARK: Making a zip

    /// Zip `items` (files and folders) into a new archive next to them; links are stored as links.
    /// One item "a" gives "a.zip", several give "Archive.zip"; a taken name gets a number.
    static func compress(_ items: [URL]) throws -> URL {
        let paths = items.map { $0.standardizedFileURL.path }
        guard let first = items.first, !paths.isEmpty else { throw ArchiveError.notFound("nothing selected") }
        var parent = first.deletingLastPathComponent().standardizedFileURL.path
        while !paths.allSatisfy({ $0.hasPrefix(parent == "/" ? "/" : parent + "/") }) {
            parent = (parent as NSString).deletingLastPathComponent
        }
        let names = paths.map { String($0.dropFirst(parent == "/" ? 1 : parent.count + 1)) }
        let stem = items.count == 1 ? first.lastPathComponent : "Archive"
        var destination = URL(fileURLWithPath: parent).appendingPathComponent(stem + ".zip")
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = URL(fileURLWithPath: parent).appendingPathComponent("\(stem) \(number).zip")
            number += 1
        }
        let result = run("/usr/bin/zip", ["-r", "-q", "-y", "-X", destination.path] + names + ["-x", "*.DS_Store"], directory: URL(fileURLWithPath: parent))
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw ArchiveError.tool(result.error)
        }
        return destination
    }

    // MARK: Helpers

    /// A path as an `-x` member name: bsdtar reads member names as glob patterns.
    static func escaped(_ path: String) -> String {
        var out = ""
        for character in path {
            if "*?[]\\".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private static func fnv(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }

    /// Runs a tool and collects its output. stderr goes to a file, so neither stream can fill a pipe
    /// and stall the process while the other is read.
    private static func run(_ executable: String, _ arguments: [String], directory: URL? = nil,
                            stdout: FileHandle? = nil) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorFile) }
        guard let errorHandle = try? FileHandle(forWritingTo: errorFile) else { return (-1, "", "Could not run \(executable).") }
        process.standardError = errorHandle
        let pipe = Pipe()
        process.standardOutput = stdout ?? pipe
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        let data = stdout == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        try? errorHandle.close()
        let message = ((try? String(contentsOf: errorFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), String(message.suffix(600)))
    }
}
