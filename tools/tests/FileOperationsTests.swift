import Foundation

/// Behaviour of the shipping `FileOperationsController` (`AR-14` step 2) on real temporary folders and the real `TabsController`: moving,
/// copying, dropping, renaming, trashing and creating, with the tabs that follow or close and the refresh of the file tree. Nothing here
/// shows a dialog or a window; the Trash is a folder of the check, so no file reaches the person's Trash.
@main
enum FileOperationsChecks {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        }
    }

    /// The window around the controller: it only counts how often the file tree was asked to read the disk.
    @MainActor
    final class Host: FileOperationsHost {
        var refreshes = 0
        func refreshFileTree() { refreshes += 1 }
    }

    /// An open project that is a folder and the folders linked to it.
    @MainActor
    final class FakeProject: ProjectProviding {
        var root: URL?
        var linked: [URL] = []
        var aiProject: URL? { root }
        var linkedFolderURLs: [URL] { linked }
        var searchRoots: [URL] { (root.map { [$0] } ?? []) + linked }
        var database: SemanticDatabase? { nil }
        init(root: URL?) { self.root = root }
        func relativePath(of url: URL) -> String { url.path }
        func markdownFiles(in folder: URL) -> [URL] { [] }
        func cacheDirectory(for url: URL) -> URL { url.deletingLastPathComponent() }
        func refreshFileTree() {}
        func containerRoot(for url: URL) -> URL? { root }
    }

    /// The Trash of a check: a folder of its own that receives what the controller trashes, so no file reaches the person's Trash.
    @MainActor
    final class Trashed {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("trash-\(UUID().uuidString)")
        var urls: [URL] = []
        var tabsAtTheTime: [[String]] = []
        weak var tabs: TabsController?
        init() { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: folder) }
        func take(_ url: URL) throws {
            tabsAtTheTime.append(tabs?.openTabs.map { $0.url.lastPathComponent } ?? [])
            urls.append(url)
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
    }

    @MainActor
    struct Window {
        let root: URL
        let host = Host()
        let tabs = TabsController()
        /// The window's background tasks, which the controller's unpackings run in.
        let tasks = TaskBag()
        let project: FakeProject
        let files: FileOperationsController
        /// What the Trash stand-in received, in order.
        let trashed = Trashed()

        init(root: URL) {
            self.root = root
            project = FakeProject(root: root)
            let trashed = self.trashed
            trashed.tabs = tabs
            files = FileOperationsController(host: host, tabs: tabs, project: project, tasks: tasks, trash: { url in try trashed.take(url) })
        }

        @discardableResult
        func make(_ path: String, _ text: String = "text\n") throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
        func text(_ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    }

    @MainActor
    static func window(_ body: (Window) async throws -> Void) async {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("file-operations-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        do { try await body(Window(root: url)) } catch { check(false, "a fixture could not be made: \(error)") }
    }

    static func main() async {
        await movingAndCopying()
        await dropping()
        await renaming()
        await trashing()
        await creating()
        await archives()
        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) check(s) failed\n".utf8))
            exit(1)
        }
        print("FileOperationsController: move, copy, drop, rename, trash, create, archives, tabs and refreshes passed")
    }

    @MainActor
    static func movingAndCopying() async {
        await window { w in
            let note = try w.make("note.md", "# Note\n")
            try w.make("docs/sub/inner.md", "# Inner\n")
            try w.make("target/placeholder.txt", "x")
            await w.tabs.openTextFile(note)
            await w.tabs.openTextFile(w.root.appendingPathComponent("docs/sub/inner.md"))
            let target = w.root.appendingPathComponent("target")

            var errors = w.files.transfer([note], into: target, copy: false)
            check(errors.isEmpty, "moving a file reports no error: \(errors)")
            check(!w.exists("note.md") && w.text("target/note.md") == "# Note\n", "the file moved with its content")
            check(w.tabs.openTabs.first?.url == target.appendingPathComponent("note.md"), "the tab of a moved file follows it")
            check(w.host.refreshes == 1, "the file tree was asked to read the disk once, got \(w.host.refreshes)")

            // A folder moves with everything in it; tabs of files inside follow.
            errors = w.files.transfer([w.root.appendingPathComponent("docs/sub")], into: target, copy: false)
            check(errors.isEmpty && w.exists("target/sub/inner.md") && !w.exists("docs/sub"), "a folder moves with what is inside it")
            check(w.tabs.openTabs.last?.url == target.appendingPathComponent("sub/inner.md"), "tabs of files inside a moved folder follow it")

            // A taken name becomes "name 2", never an overwrite.
            try w.make("again/note.md", "# Other\n")
            errors = w.files.transfer([w.root.appendingPathComponent("again/note.md")], into: target, copy: false)
            check(errors.isEmpty && w.text("target/note.md") == "# Note\n" && w.text("target/note 2.md") == "# Other\n",
                  "a taken name is kept, the newcomer is numbered")

            // Copy leaves the original and its tab where they are.
            try w.make("keep.md", "# Keep\n")
            await w.tabs.openTextFile(w.root.appendingPathComponent("keep.md"))
            errors = w.files.transfer([w.root.appendingPathComponent("keep.md")], into: target, copy: true)
            check(errors.isEmpty && w.exists("keep.md") && w.text("target/keep.md") == "# Keep\n", "a copy leaves the original")
            check(w.tabs.openTabs.last?.url == w.root.appendingPathComponent("keep.md"), "a copy moves no tab")

            // A folder never goes into itself.
            errors = w.files.transfer([target], into: target.appendingPathComponent("sub"), copy: false)
            check(errors == ["“target” can't be moved into itself."], "a folder into itself is refused: \(errors)")
            check(w.exists("target/sub/inner.md"), "the refused folder stays")

            // Dropping an item on the folder it is in changes nothing.
            let before = w.host.refreshes
            errors = w.files.transfer([target.appendingPathComponent("note.md")], into: target, copy: false)
            check(errors.isEmpty && w.exists("target/note.md") && !w.exists("target/note 3.md"), "an item moved into its own folder stays")
            check(w.host.refreshes == before + 1, "every transfer asks for one refresh")

            // A source that is gone is an error with its name.
            errors = w.files.transfer([w.root.appendingPathComponent("ghost.md")], into: target, copy: false)
            check(errors.count == 1 && errors[0].hasPrefix("Couldn't move “ghost.md”:"), "a missing source is reported by name: \(errors)")
        }
    }

    @MainActor
    static func dropping() async {
        await window { w in
            let linked = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("linked-\(UUID().uuidString)")
            let outside = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("outside-\(UUID().uuidString)")
            for url in [linked, outside] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            defer { for url in [linked, outside] { try? FileManager.default.removeItem(at: url) } }
            w.project.linked = [linked]
            try w.make("target/placeholder.txt", "x")
            let target = w.root.appendingPathComponent("target")
            try w.make("a.md", "a")
            try w.make("b.md", "b")
            try "l".write(to: linked.appendingPathComponent("l.md"), atomically: true, encoding: .utf8)
            try "o".write(to: outside.appendingPathComponent("o.md"), atomically: true, encoding: .utf8)

            check(w.files.drop([w.root.appendingPathComponent("a.md")], into: target, copyRequested: false).isEmpty
                  && !w.exists("a.md") && w.exists("target/a.md"), "an item of the project moves when dropped")
            check(w.files.drop([w.root.appendingPathComponent("b.md")], into: target, copyRequested: true).isEmpty
                  && w.exists("b.md") && w.exists("target/b.md"), "Option copies an item of the project")
            check(w.files.drop([linked.appendingPathComponent("l.md")], into: target, copyRequested: false).isEmpty
                  && !FileManager.default.fileExists(atPath: linked.appendingPathComponent("l.md").path) && w.exists("target/l.md"),
                  "an item of a linked folder moves when dropped")
            check(w.files.drop([outside.appendingPathComponent("o.md")], into: target, copyRequested: false).isEmpty
                  && FileManager.default.fileExists(atPath: outside.appendingPathComponent("o.md").path) && w.exists("target/o.md"),
                  "an item from elsewhere is copied, never moved out of its place")
            try w.make("c.md", "c")
            check(w.files.drop([w.root.appendingPathComponent("c.md"), outside.appendingPathComponent("o.md")], into: target, copyRequested: false).isEmpty
                  && w.exists("c.md") && w.exists("target/c.md"), "one item from elsewhere makes the whole drop a copy")
        }
    }

    @MainActor
    static func renaming() async {
        await window { w in
            let note = try w.make("note.md", "# Note\n")
            try w.make("taken.md")
            try w.make("folder/inner.md", "# Inner\n")
            await w.tabs.openTextFile(note)
            await w.tabs.openTextFile(w.root.appendingPathComponent("folder/inner.md"))

            check(w.files.rename(note, to: " Plan.md ") == nil && w.exists("Plan.md") && !w.exists("note.md"), "a rename trims the name and moves the file")
            check(w.tabs.openTabs.first?.url == w.root.appendingPathComponent("Plan.md"), "the tab follows the rename")
            check(w.host.refreshes == 1, "a rename asks for one refresh")

            check(w.files.rename(w.root.appendingPathComponent("Plan.md"), to: "taken.md") == "“taken.md” already exists in this folder.",
                  "a taken name is refused")
            check(w.files.rename(w.root.appendingPathComponent("Plan.md"), to: "a/b.md") == "“a/b.md” is not a valid name.", "a name with a slash is refused")
            check(w.files.rename(w.root.appendingPathComponent("Plan.md"), to: "  ") == "“” is not a valid name.", "an empty name is refused")
            check(w.exists("Plan.md"), "refused renames leave the file")

            check(w.files.rename(w.root.appendingPathComponent("Plan.md"), to: "plan.md") == nil, "a change of letter case alone goes through")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: w.root.path)) ?? []
            check(names.contains("plan.md") && !names.contains("Plan.md"), "the case change is on disk: \(names.sorted())")

            check(w.files.rename(w.root.appendingPathComponent("folder"), to: "renamed") == nil && w.exists("renamed/inner.md"), "a folder renames with its content")
            check(w.tabs.openTabs.last?.url == w.root.appendingPathComponent("renamed/inner.md"), "tabs of files inside a renamed folder follow it")
        }
    }

    @MainActor
    static func trashing() async {
        await window { w in
            let id = UUID().uuidString
            let file = try w.make("trash-\(id).md", "# Bye\n")
            try w.make("trash-\(id)-folder/inner.md", "# Inner\n")
            try w.make("stay.md", "# Stay\n")
            await w.tabs.openTextFile(file)
            await w.tabs.openTextFile(w.root.appendingPathComponent("trash-\(id)-folder/inner.md"))
            await w.tabs.openTextFile(w.root.appendingPathComponent("stay.md"))

            let errors = w.files.trash([file, w.root.appendingPathComponent("trash-\(id)-folder"), w.root.appendingPathComponent("trash-\(id)-ghost.md")])
            check(errors.count == 1 && errors[0].hasPrefix("Couldn't move “trash-\(id)-ghost.md” to the Trash:"), "only the missing item is an error: \(errors)")
            check(!w.exists("trash-\(id).md") && !w.exists("trash-\(id)-folder"), "the files left the folder")
            let received = ((try? FileManager.default.contentsOfDirectory(atPath: w.trashed.folder.path)) ?? []).sorted()
            check(received == ["trash-\(id)-folder", "trash-\(id).md"], "the file and the folder with its content went to the Trash: \(received)")
            check(w.trashed.urls.count == 3, "every item was handed to the Trash, the missing one too")
            check(w.trashed.tabsAtTheTime == [["inner.md", "stay.md"], ["stay.md"], ["stay.md"]],
                  "the tabs of an item close just before it goes to the Trash: \(w.trashed.tabsAtTheTime)")
            check(w.tabs.openTabs.map { $0.url.lastPathComponent } == ["stay.md"], "the tabs of trashed items closed, the others stay: \(w.tabs.openTabs.map { $0.url.lastPathComponent })")
            check(w.exists("stay.md") && w.host.refreshes == 1, "an untouched file stays, and the tree is read once")
        }
    }

    /// Waits for the one answer a `start...` method gives to its `finished` closure.
    @MainActor
    static func answer(_ start: (@escaping (Result<URL, Error>) -> Void) -> Void) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in start { continuation.resume(returning: $0) } }
    }

    /// A task leaves the bag a moment after it ends: waits (at most a second) until the bag holds no running task.
    @MainActor
    static func settle(_ tasks: TaskBag) async {
        for _ in 0..<100 where tasks.activeCount > 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @MainActor
    static func archives() async {
        await window { w in
            try w.make("pack/inner.md", "# Inner\n")
            try w.make("pack/deep/more.md", "# More\n")

            // A zip is made off the main thread next to its items, and the file tree is read again.
            let pack = w.root.appendingPathComponent("pack")
            let zipped = await answer { w.files.startCompress([pack], finished: $0) }
            guard case .success(let zip) = zipped else { return check(false, "compressing a folder failed: \(zipped)") }
            check(zip == w.root.appendingPathComponent("pack.zip") && FileManager.default.fileExists(atPath: zip.path), "the zip is next to the folder")
            check(w.host.refreshes == 1, "a finished zip asks for one refresh, got \(w.host.refreshes)")
            await settle(w.tasks)
            check(w.tasks.activeCount == 0, "a finished zip leaves the window's task bag")

            // Unpacking makes a new folder named after the archive, with everything in it.
            let unpacked = await answer { w.files.startExtract(zip, into: nil, finished: $0) }
            guard case .success(let folder) = unpacked else { return check(false, "unpacking failed: \(unpacked)") }
            check(folder == w.root.appendingPathComponent("pack 2") || folder == w.root.appendingPathComponent("pack"), "the folder is named after the archive: \(folder.lastPathComponent)")
            check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pack/deep/more.md").path)
                  || FileManager.default.fileExists(atPath: folder.appendingPathComponent("deep/more.md").path), "the nested file is in the folder")
            check(w.host.refreshes == 2, "a finished unpacking asks for one refresh, got \(w.host.refreshes)")

            // A second unpacking of the same archive replaces the first one: the first is told it stopped, the second finishes.
            var first: Result<URL, Error>?
            var second: Result<URL, Error>?
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                w.files.startExtract(zip, into: nil) { first = $0; if second != nil { done.resume() } }
                w.files.startExtract(zip, into: nil) { second = $0; if first != nil { done.resume() } }
            }
            if case .failure(let error)? = first { check(error is CancellationError, "the replaced unpacking ends in CancellationError, got \(error)") }
            else { check(false, "the replaced unpacking was not told it stopped: \(String(describing: first))") }
            if case .success? = second {} else { check(false, "the replacing unpacking did not finish: \(String(describing: second))") }
            check(w.host.refreshes == 3, "only the finished unpacking asks for a refresh, got \(w.host.refreshes)")

            // Closing the folder or the window cancels what the window runs: the answer is the stop, and the tree is not read.
            let stopped = await withCheckedContinuation { (continuation: CheckedContinuation<Result<URL, Error>, Never>) in
                w.files.startCompress([pack]) { continuation.resume(returning: $0) }
                w.tasks.cancelAll()
            }
            if case .failure(let error) = stopped { check(error is CancellationError, "a cancelled zip ends in CancellationError, got \(error)") }
            else { check(false, "a cancelled zip still reported success: \(stopped)") }
            check(w.host.refreshes == 3, "a cancelled zip does not read the file tree, got \(w.host.refreshes)")
        }
    }

    @MainActor
    static func creating() async {
        await window { w in
            do {
                let url = try w.files.createFile(named: "  ", in: w.root)
                check(url.lastPathComponent == "untitled.md" && w.text("untitled.md") == "# untitled\n\n", "an empty name makes untitled.md with a title")
                let notes = try w.files.createFile(named: "notes.md", in: w.root)
                check(notes == w.root.appendingPathComponent("notes.md") && w.text("notes.md") == "# notes\n\n", "a Markdown file starts with its name as the title")
                _ = try w.files.createFile(named: "data.json", in: w.root)
                check(w.text("data.json") == "", "another type starts empty")
                check(w.host.refreshes == 3, "each creation asks for one refresh, got \(w.host.refreshes)")
            } catch {
                check(false, "creating files threw \(error)")
            }

            func message(_ body: () throws -> Any?) -> String? {
                do { _ = try body(); return nil } catch let error as FileOperationError { return error.message } catch { return "other: \(error)" }
            }
            check(message { try w.files.createFile(named: "notes.md", in: w.root) } == "“notes.md” already exists in this folder.", "an existing file is never replaced")
            check(w.text("notes.md") == "# notes\n\n", "the existing file is untouched")
            check(message { try w.files.createFile(named: "a/b.md", in: w.root) } == "“a/b.md” is not a valid file name.", "a name with a slash is refused")
            check(message { try w.files.createFile(named: "..", in: w.root) } == "“..” is not a valid file name.", "\"..\" is refused")

            let before = w.host.refreshes
            check((try? w.files.createFolder(named: "  ", in: w.root)) == .some(nil) && w.host.refreshes == before, "an empty folder name does nothing")
            let folder = try? w.files.createFolder(named: "New Folder", in: w.root)
            check(folder?.path == w.root.appendingPathComponent("New Folder").path && w.exists("New Folder"), "a folder is created: \(String(describing: folder))")
            check(message { try w.files.createFolder(named: "New Folder", in: w.root) } == "“New Folder” already exists in this folder.", "an existing item is never replaced by a folder")
            check(message { try w.files.createFolder(named: "a:b", in: w.root) } == "“a:b” is not a valid folder name.", "a colon is refused")
        }
    }
}

actor SemanticDatabase {}
