import Foundation

/// File-system work a window needs but must never do on the main thread (`AR-42`): walking a project tree, and reading the
/// open files to see what an assistant changed. Every function is a plain function over values: the caller runs it in a
/// detached task and applies the result on the main actor. A walk ends early when the calling task is cancelled.
public enum BackgroundFileScans {
    /// Whether `folder` holds at least one Markdown file. Hidden files, package contents, anything under `.dde` and links
    /// that lead outside the folder do not count. The walk stops at the first hit.
    public static func containsMarkdown(in folder: URL) -> Bool {
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL.path
        // The separator keeps a sibling like `/x/foobar` from passing for `/x/foo`.
        let prefix = resolved.hasSuffix("/") ? resolved : resolved + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return false }
            guard url.pathExtension.lowercased() == "md", !url.path.contains(ProjectPaths.localFolderName) else { continue }
            let file = url.resolvingSymlinksInPath().standardizedFileURL.path
            if file == resolved || file.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// The Markdown files under `root` as paths relative to it, sorted: the document list of the diagram sheet. Hidden files and
    /// folders are skipped.
    public static func markdownPaths(in root: URL) -> [String] {
        // The path enumerator hands out relative paths, so a root under a link (`/var`, `/tmp`) needs no prefix handling.
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            if Task.isCancelled { return [] }
            let name = (relative as NSString).lastPathComponent
            if name.hasPrefix(".") {
                enumerator.skipDescendants()
            } else if (name as NSString).pathExtension.lowercased() == "md" {
                files.append(relative)
            }
        }
        return files.sorted()
    }

    /// The first file called `name` anywhere under `directory`, or nil.
    public static func firstFile(named name: String, in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return nil }
            if url.lastPathComponent == name { return url }
        }
        return nil
    }

    // MARK: - Open files

    /// When the file was last changed, read from the disk now. A `URL` caches resource values, so a date taken through one can
    /// be older than the file; the attributes of the path are always current.
    public static func modificationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// An open tab the watcher looks at, as the window knows it when a check starts.
    public struct OpenFile: Sendable {
        public enum Kind: Sendable { case data, text }
        public let url: URL
        public let kind: Kind
        /// The modification date seen at the previous check; nil when none was taken yet.
        public let seen: Date?
        /// The text the tab holds (text tabs): a file whose text is the same is not a change.
        public let loaded: String

        public init(url: URL, kind: Kind, seen: Date?, loaded: String) {
            self.url = url
            self.kind = kind
            self.seen = seen
            self.loaded = loaded
        }
    }

    /// What the disk holds for one open file.
    public struct OpenFileReading: Sendable {
        public let file: OpenFile
        /// The file's modification date now.
        public let date: Date
        /// The file is newer than at the previous check (data tabs: the viewer reads it again).
        public let isNewer: Bool
        /// The new text of a text file, when it differs from the tab's.
        public let changedText: String?
    }

    /// Read the modification dates of `files` and, for text files that look changed, their text. Without `all`, only a file
    /// newer than the last check is read; `all` reads every text file (a branch switch can restore older modification dates).
    /// A file that cannot be read (gone, unreadable, not UTF-8 text) is left out.
    public static func read(_ files: [OpenFile], all: Bool) -> [OpenFileReading] {
        var readings: [OpenFileReading] = []
        for file in files {
            if Task.isCancelled { break }
            guard let date = modificationDate(of: file.url) else { continue }
            let isNewer = file.seen.map { date > $0 } ?? false
            switch file.kind {
            case .data:
                readings.append(OpenFileReading(file: file, date: date, isNewer: isNewer, changedText: nil))
            case .text:
                guard all || isNewer, let text = try? String(contentsOf: file.url, encoding: .utf8) else {
                    readings.append(OpenFileReading(file: file, date: date, isNewer: isNewer, changedText: nil))
                    continue
                }
                readings.append(OpenFileReading(file: file, date: date, isNewer: isNewer,
                                                changedText: text == file.loaded ? nil : text))
            }
        }
        return readings
    }
}
