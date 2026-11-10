import Foundation

// End-to-End QA (feature end-to-end-qa, DEC-010): files the bug candidates of QABugs.swift as bug reports. The filer owns what is the
// same wherever the reports live: never filing a key twice, one candidate's failure leaving the others alone, and copying the pictures
// beside the report. A QABugSink owns where they live; QAFeatureStoreBugSink.swift files into the project's `docs/bugs/`. Foundation
// only (with FrontMatter.swift); checked on its own by tools/tests/qa-bugs-tests.sh.

/// One front matter line a QA bug report carries after the standard ones.
struct QABugField: Equatable, Sendable {
    var key: String
    var value: String
}

/// A bug report as the sink writes it: the body already holds the links of the copied pictures.
struct QABugReport: Equatable, Sendable {
    var key: String
    var title: String
    var severity: String
    var body: String
    var provenance: String
    /// `qa_key` (what the dedupe looks up), `qa_run` and `qa_outcome`, after the standard keys.
    var fields: [QABugField]
}

/// Where QA bug reports are looked up and written.
protocol QABugSink: Sendable {
    /// The folder of the bug reports; pictures are copied into its `assets` folder. Nil when there is no project folder.
    func bugFolder() async -> URL?
    /// For each of `keys` that a report already names (front matter `qa_key`): the id of that report. Throws when the reports cannot be
    /// read, so that nothing is filed that might already be there.
    func filedBugs(forKeys keys: [String]) async throws -> [String: String]
    /// Writes the report with the status a new bug starts in; returns its id.
    func createBug(_ report: QABugReport) async throws -> String
    /// Carries the person's mark of a finding to the report filed under `key`, if there is one (REQ-015).
    func applyTriage(key: String, _ change: QABugTriageChange) async throws -> QABugTriageOutcome
}

enum QAFilingStatus: Equatable, Sendable {
    case created(id: String)
    /// A report with this key exists already; nothing was written.
    case alreadyFiled(id: String)
    case failed(String)
}

struct QAFilingResult: Equatable, Sendable {
    var key: String
    var title: String
    var status: QAFilingStatus
    /// What went wrong with a picture, when the report was filed without it.
    var notes: [String] = []
}

/// The reports already filed, found by the front matter field `qa_key` of the files in the bug folder.
enum QABugIndex {
    static let keyField = "qa_key"
    static let runField = "qa_run"
    static let outcomeField = "qa_outcome"

    /// The front matter is at the top; this much of a file is enough to read it.
    static let headLimit = 32_768

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// For each of `keys` that a report in `folder` names: its id (front matter `id`, else the start of its file name, as the bug list
    /// reads it). A folder that does not exist has no reports. A file that cannot be read is skipped.
    static func filedBugs(in folder: URL, keys: Set<String>) throws -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) else { return [:] }
        guard isFolder.boolValue else { throw Failure(message: "\(folder.lastPathComponent) is not a folder.") }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" && $0.lastPathComponent.lowercased() != "readme.md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var found: [String: String] = [:]
        for file in files {
            guard let head = head(of: file), head.contains(keyField) else { continue }
            let front = FrontMatter.split(head).0
            let key = front.string(keyField)
            guard keys.contains(key), found[key] == nil else { continue }
            let id = front.string("id")
            found[key] = id.isEmpty ? String(file.deletingPathExtension().lastPathComponent.prefix(7)) : id
        }
        return found
    }

    /// The file of the report that names `key` in its front matter; nil when there is none.
    static func file(forKey key: String, in folder: URL) throws -> URL? {
        guard !key.isEmpty else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) else { return nil }
        guard isFolder.boolValue else { throw Failure(message: "\(folder.lastPathComponent) is not a folder.") }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" && $0.lastPathComponent.lowercased() != "readme.md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let head = head(of: file), head.contains(keyField) else { continue }
            if FrontMatter.split(head).0.string(keyField) == key { return file }
        }
        return nil
    }

    private static func head(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headLimit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Files bug candidates through a sink. Use one filer per project: its calls run one after the other, so that filing the same
/// candidates twice at once creates each report once.
actor QABugFiler {
    /// Pictures go into this folder beside the reports and are linked as `assets/<file>`, as the bug list's own attachments are (the
    /// GitHub issue text turns that link into a path from the repository root).
    static let assetsFolderName = "assets"
    static let pictureExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    static let maxPictureBytes = 8_000_000

    private let sink: QABugSink
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(sink: QABugSink) { self.sink = sink }

    /// Files each candidate that is not filed yet, in order. The result has one entry per candidate: created, already filed (under the
    /// id of the report that has its key) or failed. A failure of one candidate does not stop the others.
    func file(_ candidates: [QABugCandidate]) async -> [QAFilingResult] {
        await acquire()
        defer { release() }
        guard !candidates.isEmpty else { return [] }

        var keys: [String] = []
        for candidate in candidates where !keys.contains(candidate.key) { keys.append(candidate.key) }
        let existing: [String: String]
        do {
            existing = try await sink.filedBugs(forKeys: keys)
        } catch {
            let message = "The bug reports already filed could not be checked, so nothing was filed: \(error.localizedDescription)"
            return candidates.map { QAFilingResult(key: $0.key, title: $0.title, status: .failed(message)) }
        }

        let folder = await sink.bugFolder()
        var filed = existing
        var failedKeys: [String: QAFilingStatus] = [:]
        var results: [QAFilingResult] = []
        for candidate in candidates {
            if let id = filed[candidate.key] {
                results.append(QAFilingResult(key: candidate.key, title: candidate.title, status: .alreadyFiled(id: id)))
            } else if let failure = failedKeys[candidate.key] {
                results.append(QAFilingResult(key: candidate.key, title: candidate.title, status: failure))
            } else if Task.isCancelled {
                results.append(QAFilingResult(key: candidate.key, title: candidate.title, status: .failed("Filing was cancelled.")))
            } else {
                let result = await fileOne(candidate, bugFolder: folder)
                switch result.status {
                case .created(let id), .alreadyFiled(let id): filed[candidate.key] = id
                case .failed: failedKeys[candidate.key] = result.status
                }
                results.append(result)
            }
        }
        return results
    }

    /// Carries a mark of a finding to its bug report (see `QABugSink.applyTriage`). Runs after the filing in progress, if any.
    func applyTriage(key: String, _ change: QABugTriageChange) async throws -> QABugTriageOutcome {
        await acquire()
        defer { release() }
        return try await sink.applyTriage(key: key, change)
    }

    private func fileOne(_ candidate: QABugCandidate, bugFolder: URL?) async -> QAFilingResult {
        let assets = bugFolder?.appendingPathComponent(Self.assetsFolderName, isDirectory: true)
        let copied = assets.map { Self.copyPictures(candidate.pictures, key: candidate.key, into: $0) }
            ?? PictureCopy(files: [], links: [], notes: candidate.pictures.map { "Picture \"\(Self.plainLabel($0.label))\" was not copied: there is no project folder." })
        let report = QABugReport(
            key: candidate.key, title: candidate.title, severity: candidate.severity,
            body: candidate.body + Self.picturesSection(links: copied.links, notes: copied.notes),
            provenance: "Created by End-to-End QA from run \(candidate.runID)",
            fields: Self.fields(of: candidate))
        do {
            let id = try await sink.createBug(report)
            return QAFilingResult(key: candidate.key, title: candidate.title, status: .created(id: id), notes: copied.notes)
        } catch {
            for file in copied.files { try? FileManager.default.removeItem(at: file) }
            return QAFilingResult(key: candidate.key, title: candidate.title, status: .failed(error.localizedDescription), notes: copied.notes)
        }
    }

    static func fields(of candidate: QABugCandidate) -> [QABugField] {
        [QABugField(key: QABugIndex.keyField, value: candidate.key),
         QABugField(key: QABugIndex.runField, value: candidate.runID),
         QABugField(key: QABugIndex.outcomeField, value: candidate.outcome?.rawValue ?? "defect")]
    }

    // MARK: Pictures

    struct PictureCopy {
        /// The files written.
        var files: [URL]
        /// The Markdown image of each, linked from the bug folder.
        var links: [String]
        var notes: [String]
    }

    /// Copies the pictures into `assets` under names made from the candidate's key (so that copying them again writes the same files).
    /// A picture that is not an ordinary image file of reasonable size is left out and named in the notes.
    static func copyPictures(_ pictures: [QABugPicture], key: String, into assets: URL) -> PictureCopy {
        var copy = PictureCopy(files: [], links: [], notes: [])
        let hash = stableHash(key)
        for (index, picture) in pictures.enumerated() {
            let label = plainLabel(picture.label)
            func skip(_ reason: String) { copy.notes.append("Picture \"\(label)\" was not copied: \(reason)") }
            let source = picture.file
            let ext = source.pathExtension.lowercased()
            guard source.isFileURL, pictureExtensions.contains(ext) else { skip("it is not a PNG, JPEG, GIF or WebP image."); continue }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else { skip("the file does not exist."); continue }
            guard attributes[.type] as? FileAttributeType == .typeRegular else { skip("it is not an ordinary file."); continue }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size <= maxPictureBytes else { skip("it is empty or larger than \(maxPictureBytes / 1_000_000) MB."); continue }
            let name = "qa-\(hash)-\(index + 1)-\(plainName(source.deletingPathExtension().lastPathComponent)).\(ext)"
            let destination = assets.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                skip("\(error.localizedDescription)")
                continue
            }
            copy.files.append(destination)
            copy.links.append("![\(label)](\(assetsFolderName)/\(name))")
        }
        return copy
    }

    /// A picture's label as the text of a Markdown image or a list item: square brackets would start a link.
    private static func plainLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    /// The `## Pictures` section to append to a body; empty without pictures and notes.
    static func picturesSection(links: [String], notes: [String]) -> String {
        guard !links.isEmpty || !notes.isEmpty else { return "" }
        var parts = ["## Pictures"]
        if !links.isEmpty { parts.append(links.joined(separator: "\n\n")) }
        if !notes.isEmpty { parts.append(notes.map { "- \($0)" }.joined(separator: "\n")) }
        return "\n\n" + parts.joined(separator: "\n\n")
    }

    /// Letters, digits, dots, dashes and underscores of a file name; anything else is a dash.
    private static func plainName(_ name: String) -> String {
        var plain = ""
        for character in name {
            let allowed = character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "_")
            if allowed || character == "-" { plain.append(character) } else if !plain.hasSuffix("-") { plain.append("-") }
        }
        let trimmed = String(plain.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "picture" : trimmed
    }

    /// FNV-1a of the key as 16 hex digits: the same key always names the same files.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    // MARK: One call at a time

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

// MARK: - The person's mark on a filed report (REQ-015)

extension QABugTriage {
    /// The front matter line that says which mark this app put on the report, so a later change knows what it may take back.
    static let markField = "qa_triage"

    /// Writes a mark into a report's front matter and body: `ready_to_fix` for a confirmed bug (and taken away again only when this app set
    /// it), the "Workaround" section, and `qa_triage`. Returns the mark the report carried before.
    @discardableResult
    static func apply(_ change: QABugTriageChange, front: inout FrontMatter, body: inout String) -> QATriageState? {
        let previous = QATriageState(rawValue: front.string(markField))
        if change.readyToFix {
            front.set("ready_to_fix", "true")
        } else if previous == .confirmed {
            front.set("ready_to_fix", nil)
        }
        front.set(markField, change.mark?.rawValue)
        body = settingWorkaround(change.workaround, in: body)
        return previous
    }
}
