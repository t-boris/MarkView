import CryptoKit
import Foundation

/// A child process run off the main thread with both pipes drained while it runs (CLAUDE.md: a full pipe must not
/// deadlock it, and `waitUntilExit` never runs on the main thread).
enum StudioProcess {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// `timeout` ends the process (SIGTERM) when it runs longer; its output so far is returned.
    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil, input: Data? = nil,
                    timeout: TimeInterval? = nil) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let directory { process.currentDirectoryURL = directory }
                let out = Pipe(), err = Pipe(), stdin = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = input == nil ? FileHandle.nullDevice : stdin
                do { try process.run() } catch {
                    continuation.resume(returning: Output(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
                }
                if let input {
                    DispatchQueue.global().async {
                        try? stdin.fileHandleForWriting.write(contentsOf: input)
                        try? stdin.fileHandleForWriting.close()
                    }
                }
                var stdoutData = Data(), stderrData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { stdoutData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { stderrData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(status: process.terminationStatus,
                                                      stdout: String(decoding: stdoutData, as: UTF8.self),
                                                      stderr: String(decoding: stderrData, as: UTF8.self)))
            }
        }
    }

    static func git(_ arguments: [String], in directory: URL) async -> Output {
        await run("/usr/bin/git", arguments, in: directory)
    }
}

enum StudioHash {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
}

/// The state of the working tree when an operation started: what each file was, so a change made by the user, the editor
/// or another agent while the assistant worked is detected instead of overwritten (EDIT-05, AC-13).
struct StudioWorkingSnapshot: Equatable {
    var root: URL
    var gitRoot: URL?
    var head: String?
    /// Hashes of changed and untracked files (git) or of every file (no git), by path relative to `root`; nil = deleted.
    var files: [String: String?]
    var editorBuffers: [String: String]

    /// The hash `path` had when the snapshot was taken; nil when it did not exist.
    func startHash(of path: String) async -> String? {
        if let recorded = files[path] { return recorded }
        guard let gitRoot, let head else {
            // No git: a file absent from the full listing did not exist.
            return nil
        }
        let absolute = root.appendingPathComponent(path).standardizedFileURL.path
        let relative = String(absolute.dropFirst(gitRoot.standardizedFileURL.path.count + 1))
        let shown = await StudioProcess.git(["show", "\(head):\(relative)"], in: gitRoot)
        return shown.status == 0 ? StudioHash.sha256(shown.stdout) : nil
    }
}

/// Code revision identity (§10.1) and the working snapshot behind it.
enum StudioRevisionProbe {
    static let ignoredFolders: Set<String> = [".git", "node_modules", ".dde", "dist", "build", ".next", ".nuxt", ".svelte-kit",
                                              "DerivedData", ".build", "Pods", "coverage", ".turbo", ".cache", "out", "target"]
    static let maxListedFiles = 6_000
    static let maxHashedBytes = 2_000_000

    /// The revision of `root`: commit, uncommitted and untracked changes with their contents, and the unsaved editor buffers
    /// (`editorBuffers`, path relative to `root` → text).
    static func compute(root: URL, editorBuffers: [String: String] = [:]) async -> (StudioRevision, StudioWorkingSnapshot) {
        let root = root.standardizedFileURL
        let top = await StudioProcess.git(["rev-parse", "--show-toplevel"], in: root)
        var files: [String: String?] = [:]
        var head: String?
        var gitRoot: URL?
        if top.status == 0 {
            let gitPath = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            gitRoot = URL(fileURLWithPath: gitPath).standardizedFileURL
            let rev = await StudioProcess.git(["rev-parse", "HEAD"], in: root)
            head = rev.status == 0 ? rev.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let status = await StudioProcess.git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], in: root)
            for path in porcelainPaths(status.stdout) {
                let absolute = gitRoot!.appendingPathComponent(path).standardizedFileURL.path
                guard absolute.hasPrefix(root.path + "/") else { continue }
                let relative = String(absolute.dropFirst(root.path.count + 1))
                if relative.split(separator: "/").contains(where: { ignoredFolders.contains(String($0)) }) { continue }
                files[relative] = hash(of: URL(fileURLWithPath: absolute))
            }
        } else {
            for relative in listFiles(root) { files[relative] = hash(of: root.appendingPathComponent(relative)) }
        }
        var digest = "head:\(head ?? "none")\n"
        for path in files.keys.sorted() { digest += "\(path):\(files[path].flatMap { $0 } ?? "deleted")\n" }
        for path in editorBuffers.keys.sorted() { digest += "editor:\(path):\(StudioHash.sha256(editorBuffers[path] ?? ""))\n" }
        let changed = gitRoot == nil ? 0 : files.count
        let revision = StudioRevision(id: StudioHash.sha256(digest), head: head, changedFiles: changed, editorBuffers: editorBuffers.count)
        return (revision, StudioWorkingSnapshot(root: root, gitRoot: gitRoot, head: head, files: files, editorBuffers: editorBuffers))
    }

    /// Paths of `git status --porcelain=v1 -z`: a rename lists its new path (the old one follows and is skipped).
    static func porcelainPaths(_ output: String) -> [String] {
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var paths: [String] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            guard entry.count > 3 else { index += 1; continue }
            let code = entry.prefix(2)
            paths.append(String(entry.dropFirst(3)))
            index += code.contains("R") || code.contains("C") ? 2 : 1
        }
        return paths
    }

    static func hash(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        guard let size = attributes[.size] as? Int, size <= maxHashedBytes else {
            return "large:\((attributes[.size] as? Int) ?? 0):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        return (try? Data(contentsOf: url)).map(StudioHash.sha256)
    }

    private static func listFiles(_ root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var result: [String] = []
        for case let url as URL in enumerator {
            if ignoredFolders.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result.append(String(url.standardizedFileURL.path.dropFirst(root.path.count + 1)))
            if result.count >= maxListedFiles { break }
        }
        return result
    }

    /// Current hashes of `paths` (relative to `root`), for a feature package's revalidation (CAP-06).
    static func currentHashes(_ paths: [String], root: URL) -> [String: String] {
        var result: [String: String] = [:]
        for path in paths { result[path] = hash(of: root.appendingPathComponent(path)) ?? "deleted" }
        return result
    }
}

/// One search-and-replace an assistant proposes; an empty `search` on a missing file creates it with `replace`.
struct StudioEdit: Codable, Equatable {
    var path: String
    var search: String
    var replace: String
}

enum StudioChangeError: Error, Equatable, LocalizedError {
    case invalidPath(String)
    case notFound(String)
    case ambiguous(String, Int)
    case conflict([String])
    case tooLarge(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "\(path) is not a source file of the project UI Studio may change."
        case .notFound(let path): return "The text to change was not found in \(path)."
        case .ambiguous(let path, let count): return "The text to change occurs \(count) times in \(path); the change is ambiguous."
        case .conflict(let paths):
            return "Changed while the assistant worked: " + paths.joined(separator: ", ") + ". Nothing was overwritten."
        case .tooLarge(let path): return "\(path) is too large to change from UI Studio."
        case .writeFailed(let detail): return "The change could not be written: \(detail). Every file was put back."
        }
    }
}

/// Applies, records and selectively undoes source changes (EDIT-05…EDIT-07, plan I-6).
enum StudioChanges {
    /// Folders a UI change never writes: version control, dependencies, MarkView's own data, build output.
    static let protectedFolders: Set<String> = [".git", "node_modules", ".dde", ".markview", "dist", "build", ".next", ".nuxt",
                                                ".svelte-kit", "DerivedData", ".build", "Pods", "vendor", "out", "target", "coverage"]
    static let maxFileSize = 2_000_000

    /// The file `path` names inside `root`, or nil when it escapes the project, is protected or is not a text file.
    static func validatedURL(_ path: String, root: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"), !trimmed.contains("\0") else { return nil }
        let parts = trimmed.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.contains("."), !parts.contains(where: { protectedFolders.contains($0) }) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(trimmed).standardizedFileURL
        // A symlink inside the project must not lead outside it.
        let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard resolvedParent == base.path || resolvedParent.hasPrefix(base.path + "/") else { return nil }
        if FileManager.default.fileExists(atPath: url.path) {
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(base.path + "/") else { return nil }
        }
        let binary: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "ico", "woff", "woff2", "ttf", "otf", "zip", "pdf", "wasm", "mp4", "mov"]
        guard !binary.contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    /// What the edits would make of the files, checked against the snapshot taken when the operation started. Nothing is
    /// written; a conflict, a missing or ambiguous search text or a bad path fails the whole change.
    /// `unsavedNow` lists files with unsaved editor changes at the moment of applying (paths relative to the root).
    static func plan(_ edits: [StudioEdit], snapshot: StudioWorkingSnapshot, unsavedNow: Set<String> = []) async throws -> [StudioFileChange] {
        var texts: [String: String?] = [:]
        var originals: [String: String?] = [:]
        var order: [String] = []
        var conflicts: [String] = []
        for edit in edits {
            let path = edit.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = validatedURL(path, root: snapshot.root) else { throw StudioChangeError.invalidPath(path) }
            if texts[path] == nil {
                let current: String?
                if FileManager.default.fileExists(atPath: url.path) {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    guard size <= maxFileSize else { throw StudioChangeError.tooLarge(path) }
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw StudioChangeError.invalidPath(path) }
                    current = text
                } else {
                    current = nil
                }
                let started = await snapshot.startHash(of: path)
                if started != current.map(StudioHash.sha256) || snapshot.editorBuffers[path] != nil || unsavedNow.contains(path) {
                    conflicts.append(path)
                }
                texts[path] = .some(current)
                originals[path] = .some(current)
                order.append(path)
            }
            var text = texts[path]!
            if edit.search.isEmpty {
                guard text == nil else { throw StudioChangeError.ambiguous(path, 0) }
                text = edit.replace
            } else {
                guard let existing = text else { throw StudioChangeError.notFound(path) }
                let count = existing.components(separatedBy: edit.search).count - 1
                if count == 0 { throw StudioChangeError.notFound(path) }
                if count > 1 { throw StudioChangeError.ambiguous(path, count) }
                text = existing.replacingOccurrences(of: edit.search, with: edit.replace)
            }
            texts[path] = .some(text)
        }
        if !conflicts.isEmpty { throw StudioChangeError.conflict(conflicts) }
        return order.compactMap { path in
            let before = originals[path]!, after = texts[path]!
            return before == after ? nil : StudioFileChange(path: path, before: before, after: after)
        }
    }

    /// Writes the files of `changes` (each atomically); when one write fails, the ones already written are put back.
    static func write(_ changes: [StudioFileChange], root: URL, useAfter: Bool = true) throws {
        var done: [StudioFileChange] = []
        do {
            for change in changes {
                guard let url = validatedURL(change.path, root: root) else { throw StudioChangeError.invalidPath(change.path) }
                try put(useAfter ? change.after : change.before, at: url)
                done.append(change)
            }
        } catch {
            for change in done.reversed() {
                if let url = validatedURL(change.path, root: root) { try? put(useAfter ? change.before : change.after, at: url) }
            }
            if let failure = error as? StudioChangeError { throw failure }
            throw StudioChangeError.writeFailed(error.localizedDescription)
        }
    }

    private static func put(_ text: String?, at url: URL) throws {
        if let text {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Undo

    enum UndoPlan: Equatable {
        /// The file goes back to this text (nil = removed), keeping independent changes.
        case clean(path: String, text: String?)
        /// The reverse change collides with later changes: `merged` holds conflict markers for resolution.
        case conflict(path: String, merged: String, hunks: Int)
        /// The file already is as it was before the operation.
        case unchanged(path: String)
    }

    /// The selective undo of one file (EDIT-07): the operation's reverse change is merged into the current text, so later
    /// independent edits stay; overlapping edits become a conflict instead of a rollback of the whole file.
    static func undoPlan(_ change: StudioFileChange, root: URL) async -> UndoPlan {
        guard let url = validatedURL(change.path, root: root) else { return .conflict(path: change.path, merged: "", hunks: 1) }
        let current: String? = FileManager.default.fileExists(atPath: url.path) ? (try? String(contentsOf: url, encoding: .utf8)) : nil
        if current == change.before { return .unchanged(path: change.path) }
        if current == change.after { return .clean(path: change.path, text: change.before) }
        guard let current, let after = change.after, let before = change.before else {
            // A created file that was edited again, or a deleted file that came back: only the person can decide.
            return .conflict(path: change.path, merged: current ?? "", hunks: 1)
        }
        let merged = await threeWayMerge(current: current, base: after, other: before, path: change.path)
        if let merged, merged.conflicts == 0 { return .clean(path: change.path, text: merged.text) }
        return .conflict(path: change.path, merged: merged?.text ?? current, hunks: max(1, merged?.conflicts ?? 1))
    }

    /// `git merge-file`: applies base→other onto current. Returns the text and the number of conflicts.
    static func threeWayMerge(current: String, base: String, other: String, path: String) async -> (text: String, conflicts: Int)? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-studio-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try current.write(to: folder.appendingPathComponent("current"), atomically: true, encoding: .utf8)
            try base.write(to: folder.appendingPathComponent("base"), atomically: true, encoding: .utf8)
            try other.write(to: folder.appendingPathComponent("other"), atomically: true, encoding: .utf8)
        } catch { return nil }
        let output = await StudioProcess.git(["merge-file", "-p", "-L", "\(path) (now)", "-L", "\(path) (after the change)",
                                              "-L", "\(path) (before the change)", "current", "base", "other"], in: folder)
        guard output.status >= 0 else { return nil }
        return (output.stdout, Int(output.status))
    }

    // MARK: Patch

    /// A unified diff of the operation's files (the patch of a feature package).
    static func unifiedDiff(_ changes: [StudioFileChange]) async -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-studio-diff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var patch = ""
        for (index, change) in changes.enumerated() {
            let old = folder.appendingPathComponent("\(index)-a"), new = folder.appendingPathComponent("\(index)-b")
            try? (change.before ?? "").write(to: old, atomically: true, encoding: .utf8)
            try? (change.after ?? "").write(to: new, atomically: true, encoding: .utf8)
            let output = await StudioProcess.run("/usr/bin/diff", ["-u", "--label", change.before == nil ? "/dev/null" : "a/\(change.path)",
                                                                 "--label", change.after == nil ? "/dev/null" : "b/\(change.path)",
                                                                 old.path, new.path])
            patch += "diff --git a/\(change.path) b/\(change.path)\n" + output.stdout
            if !output.stdout.hasSuffix("\n") && !output.stdout.isEmpty { patch += "\n" }
        }
        return patch
    }
}
