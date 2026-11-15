import Foundation

@main struct WindowSessionTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fatalError(message) }
    }
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--seed-ui" {
            try await seedUI(at: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        let storage = WindowSessionStorage(url: url)
        let empty = await storage.load()
        check(empty == nil, "first launch has no session")
        let folder = URL(fileURLWithPath: "/tmp/two windows same folder")
        let file = folder.appendingPathComponent("document.md")
        let draft = WorkspaceDraft(content: "unsaved text\n", original: "disk text\n")
        let first = WorkspaceWindowState(id: UUID(), folder: folder,
            tabs: [.file(url: file, draft: draft, notes: true, scroll: 123.5),
                   .github(.issue(number: 33, repo: "owner/repo", title: "#33")),
                   .image(folder.appendingPathComponent("image.png")), .architecture("src"), .terminal(folder),
                   .pdf(folder.appendingPathComponent("read only.pdf"))],
            activeTabIndex: 1,
            panels: WorkspacePanelState(workspaceArea: "Work", workSection: "Git", navigator: "terminal", left: "issues", feature: "one", git: "changes", stage: "explore", showFiles: true, showNavigator: false, contentsVisible: false, terminalVisible: true, showCenter: false, welcomeBackdrop: "aurora"),
            frame: CGRect(x: 300, y: 400, width: 1200, height: 800), minimized: true,
            theme: WindowThemeSettings(theme: .midnight, accents: [.midnight: ThemeColor(0xFF4D9A), .paper: ThemeColor(0x00AA00)]),
            uiState: ["search.panelMode": .string("Documents"), "uiStudioInspectorWidth": .double(412), "contents.infoExpanded": .bool(false), "n": .int(3)])
        let second = WorkspaceWindowState(id: UUID(), folder: folder)
        let archive = WindowSessionArchive(windows: [first, second])
        check(try await storage.save(archive, revision: 1) == .saved, "a normal save writes the archive")
        let loaded = await WindowSessionStorage(url: url).load()!
        check(loaded.windows.count == 2, "same-folder windows must not collapse")
        check(loaded.windows.map(\.id) == [first.id, second.id], "identities and order survive a new process")
        check(loaded.windows[0].folder == folder, "folder URLs survive spaces")
        check(loaded.windows[0].activeTabIndex == 1, "active tab survives")
        check(loaded.windows[0].frame == first.frame && loaded.windows[0].minimized, "window placement survives")
        check(loaded.windows[0].theme == first.theme && loaded.windows[0].theme?.theme == .midnight &&
              loaded.windows[0].theme?.accentOverride(for: .paper)?.rgb == 0x00AA00, "each window's theme and per-theme accents survive")
        check(loaded.windows[1].theme == nil, "a window saved without a theme stays without one")
        check(loaded.windows[0].uiState == first.uiState && loaded.windows[0].uiState?["uiStudioInspectorWidth"] == .double(412),
              "each window's own interface state (modes, widths, expanded sections) survives")
        check(loaded.windows[1].uiState == nil, "a window saved without interface state stays without it")
        check(loaded.windows[0].panels?.feature == "one" && loaded.windows[0].panels?.showNavigator == false, "per-window panels survive")
        check(loaded.windows[0].panels?.workspaceArea == "Work" && loaded.windows[0].panels?.workSection == "Git",
              "workspace and Work section survive per window")
        check(loaded.windows[0].panels?.contentsVisible == false && loaded.windows[0].panels?.terminalVisible == true &&
              loaded.windows[0].panels?.showCenter == false, "column visibility survives per window")
        check(loaded.windows[0].panels?.welcomeBackdrop == "aurora", "each window's welcome-screen background survives (BUG-120)")
        // A session written before BUG-120 has no such key: it must still load, and the window keeps the choice it starts with.
        let oldPanels = #"{"navigator":"contents","left":"files","feature":"","git":"changes","stage":"explore","showFiles":true,"showNavigator":true}"#
        let decodedOld = try JSONDecoder().decode(WorkspacePanelState.self, from: Data(oldPanels.utf8))
        check(decodedOld.welcomeBackdrop == nil, "panels saved before BUG-120 load without a welcome-screen background")
        check(loaded.windows[0].tabs.count == 6, "all supported tab kinds survive")
        if case .pdf(let restoredPDF) = loaded.windows[0].tabs[5] {
            check(restoredPDF == folder.appendingPathComponent("read only.pdf"), "PDF tabs survive session restoration without text drafts")
        } else { fatalError("wrong PDF tab kind") }
        if case .file(let restoredURL, let restoredDraft, let notes, let scroll) = loaded.windows[0].tabs[0] {
            check(restoredURL == file && notes && scroll == 123.5, "file view state survives")
            check(restoredDraft?.content == draft.content && restoredDraft?.original == draft.original, "unsaved text survives without a disk write")
        } else { fatalError("wrong tab kind") }
        if case .github(let item) = loaded.windows[0].tabs[1] {
            check(item == .issue(number: 33, repo: "owner/repo", title: "#33"), "GitHub tabs survive")
        } else { fatalError("wrong GitHub tab") }
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        check(permissions.intValue == 0o600, "draft archive is private")
        check(try await storage.save(WindowSessionArchive(windows: [second]), revision: 3) == .saved, "the quit snapshot is written")
        check(try await storage.save(archive, revision: 2) == .superseded, "an older revision is dropped, not written")
        let afterStale = await storage.load()!
        check(afterStale.windows.count == 1 && afterStale.windows[0].id == second.id, "older autosave cannot overwrite the quit snapshot")
        check(try await storage.save(WindowSessionArchive(windows: []), revision: 4) == .saved, "an empty archive is written")
        let allClosed = await storage.load()!
        check(allClosed.windows.isEmpty, "closing all windows stays closed; does not fall back to last folder")
        check(try await storage.save(WindowSessionArchive(windows: [first, first, second]), revision: 5) == .saved, "an archive with duplicates is written")
        let deduplicated = await storage.load()!
        check(deduplicated.windows.count == 2, "corrupt duplicate identities cannot open duplicate windows")
        let external = WorkspaceWindowState(id: UUID(), folder: URL(string: "https://example.com")!)
        check(try await storage.save(WindowSessionArchive(windows: [external]), revision: 6) == .saved, "an archive with an external folder is written")
        let rejected = await storage.load()
        check(rejected == nil, "external folder URLs are rejected")
        // A session saved before themes existed has no "theme" key and still opens.
        let before = ##"{"version":1,"windows":[{"id":"6B8E2A0C-1D3F-4A56-9B7C-0E1F2A3B4C5D","tabs":[],"activeTabIndex":-1,"minimized":false}]}"##
        try Data(before.utf8).write(to: url)
        let old = await WindowSessionStorage(url: url).load()
        check(old?.windows.count == 1 && old?.windows[0].theme == nil, "a session from before themes opens without a theme")
        try await checkSessionsOfEarlierVersions(at: url, storage: storage)
        try Data("corrupt archive".utf8).write(to: url)
        let corrupt = await storage.load()
        check(corrupt == nil, "corrupt archive does not crash startup")
        try JSONEncoder().encode(WindowSessionArchive(version: 99, windows: [first])).write(to: url)
        let unknown = await storage.load()
        check(unknown == nil, "unknown archive versions are rejected")
        try await checkNewerFileIsLeftAlone(in: directory)
        let permsURL = url.deletingLastPathComponent().appendingPathComponent("perms-session.json")
        check(try await WindowSessionStorage(url: permsURL).save(WindowSessionArchive(windows: [first]), revision: 1) == .saved, "the permissions archive is written")
        let posixPerms = (try FileManager.default.attributesOfItem(atPath: permsURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check(posixPerms == 0o600, "saved window sessions enforce 0600 permissions")
        print("Window session checks: \(checks), failures: 0")
    }

    /// Windows saved by 6.26.2 and earlier, with every kind of tab they could hold: the tool tabs (Git, Build & Deployment, Workflow, QA,
    /// Discussions, file changes) were one enum case each and are one `.tool` case now. The text below is what the compiler-generated
    /// coding of those versions wrote; it must still load, and saving it again must write the same text, so an older MarkView can read it.
    static func checkSessionsOfEarlierVersions(at url: URL, storage: WindowSessionStorage) async throws {
        let tabs = [
            ##"{"file":{"draft":{"content":"x","original":"y"},"notes":true,"scroll":12.5,"url":"file:\/\/\/tmp\/p\/a.md"}}"##,
            ##"{"file":{"notes":false,"scroll":0,"url":"file:\/\/\/tmp\/p\/b.md"}}"##,
            ##"{"image":{"_0":"file:\/\/\/tmp\/p\/i.png"}}"##, ##"{"pdf":{"_0":"file:\/\/\/tmp\/p\/p.pdf"}}"##, ##"{"archive":{"_0":"file:\/\/\/tmp\/p\/a.zip"}}"##,
            ##"{"deployments":{}}"##, ##"{"discussions":{}}"##, ##"{"workflow":{}}"##, ##"{"git":{}}"##, ##"{"qa":{}}"##, ##"{"changeReview":{}}"##,
            ##"{"github":{"_0":{"issue":{"number":3,"repo":"o\/r","title":"#3"}}}}"##, ##"{"github":{"_0":{"run":{"id":4,"repo":"o\/r","title":"run"}}}}"##,
            ##"{"github":{"_0":{"pullRequest":{"number":5,"repo":"o\/r","title":"pr"}}}}"##,
            ##"{"architecture":{"_0":"src"}}"##, ##"{"terminal":{"_0":"file:\/\/\/tmp\/p"}}"##, ##"{"browser":{"_0":"https:\/\/example.com"}}"##,
            ##"{"data":{"_0":"file:\/\/\/tmp\/p\/d.csv"}}"##
        ]
        let archive = ##"{"version":1,"windows":[{"id":"6B8E2A0C-1D3F-4A56-9B7C-0E1F2A3B4C5D","folder":"file:///tmp/p","tabs":[\##(tabs.joined(separator: ","))],"activeTabIndex":8,"minimized":false}]}"##
        try Data(archive.utf8).write(to: url)
        let loaded = await WindowSessionStorage(url: url).load()
        check(loaded?.windows.count == 1 && loaded?.windows[0].tabs.count == tabs.count, "a session saved by an earlier version loads with all its tabs")
        let restored = loaded?.windows[0].tabs ?? []
        let toolKeys = ["deployments", "discussions", "workflow", "git", "qa", "changeReview"]
        let restoredTools = restored.compactMap { tab -> String? in if case .tool(let id) = tab { return id.rawValue }; return nil }
        check(restoredTools == toolKeys, "every tool tab of an earlier version loads as the tool's tab (\(restoredTools))")
        check(toolKeys.allSatisfy { ToolRegistry.shared.isRestorable(ToolID(rawValue: $0)) }, "and every one of them is a tool the app restores")
        if case .file(let fileURL, let draft, let notes, let scroll) = restored[0] {
            check(fileURL.path == "/tmp/p/a.md" && draft?.content == "x" && draft?.original == "y" && notes && scroll == 12.5, "a file tab of an earlier version loads with its draft")
        } else { fatalError("the first tab is a file") }
        if case .github(let item) = restored[12] { check(item == .run(id: 4, repo: "o/r", title: "run"), "a GitHub tab of an earlier version loads") } else { fatalError("the 13th tab is a run") }
        // Saving writes the text the earlier versions wrote, tab by tab.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (written, tab) in zip(tabs, restored) {
            let wrote = try JSONSerialization.jsonObject(with: Data(written.utf8)) as? NSDictionary
            let writes = try JSONSerialization.jsonObject(with: encoder.encode(tab)) as? NSDictionary
            check(wrote != nil && wrote == writes, "a tab is saved as the earlier versions saved it: \(written)")
        }
        // A tool this version does not have loads, and is left out when the window is restored.
        let future = ##"{"version":1,"windows":[{"id":"6B8E2A0C-1D3F-4A56-9B7C-0E1F2A3B4C5E","tabs":[{"timeline":{}},{"git":{}}],"activeTabIndex":1,"minimized":false}]}"##
        try Data(future.utf8).write(to: url)
        let unknown = await WindowSessionStorage(url: url).load()
        let ids = unknown?.windows[0].tabs.compactMap { tab -> ToolID? in if case .tool(let id) = tab { return id }; return nil } ?? []
        check(ids.map(\.rawValue) == ["timeline", "git"] && !ToolRegistry.shared.isRestorable(ids[0]) && ToolRegistry.shared.isRestorable(ids[1]),
              "a tab of a tool this version lacks does not stop the session from loading and is not restored")
    }

    /// A session file written by a newer MarkView (a future `schema` envelope, or a legacy payload with `version > 1`) is
    /// never overwritten, refusing it again costs no read of the file, the user is told once per launch, and quitting is
    /// never held up by it or by any other write failure (FU-15, FU-21).
    static func checkNewerFileIsLeftAlone(in directory: URL) async throws {
        let fm = FileManager.default
        let url = directory.appendingPathComponent("newer-session.json")
        let windows = [WorkspaceWindowState(id: UUID(), folder: URL(fileURLWithPath: "/tmp/newer"))]
        let archive = WindowSessionArchive(windows: windows)
        let storage = WindowSessionStorage(url: url)

        // Legacy payload from a newer MarkView.
        try JSONEncoder().encode(WindowSessionArchive(version: 99, windows: windows)).write(to: url)
        let legacy = try Data(contentsOf: url)
        check(try await storage.save(archive, revision: 1) == .refused(announce: true),
              "a legacy payload with a newer version is refused, and the user is told")
        check(try Data(contentsOf: url) == legacy, "a legacy payload with a newer version is never overwritten")
        check(try await storage.save(archive, revision: 2) == .refused(announce: false), "the refusal is announced once")

        // The verdict stands while the file keeps its modification date: the file is not read again (here it could not be:
        // a read of an unreadable file would count as a damaged file and the save would go ahead).
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        check(try await storage.save(archive, revision: 3) == .refused(announce: false), "a known refusal is not decided again from the file")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        check(try Data(contentsOf: url) == legacy, "a refusal from the cached verdict leaves the file alone")
        // A file that changed is looked at again: this one is fine, so autosave resumes.
        let healthy = #"{"schema":1,"updatedAt":"2026-11-15T00:00:00Z","data":{"version":1,"windows":[]}}"#
        try Data(healthy.utf8).write(to: url)
        check(try await storage.save(archive, revision: 4) == .saved, "autosave resumes once the file is replaced by a readable one")
        check(await storage.load()?.windows.map(\.id) == windows.map(\.id), "the resumed autosave wrote the archive")

        // Envelope from a newer MarkView.
        let envelope = #"{"schema":99,"updatedAt":"2026-11-15T00:00:00Z","data":{"version":1,"windows":[]}}"#
        try Data(envelope.utf8).write(to: url)
        let newerSchema = await storage.load()
        check(newerSchema == nil, "newer schema envelopes are rejected")
        check(try await storage.save(archive, revision: 5) == .refused(announce: false),
              "a newer envelope is refused, and the user was already told in this launch")
        check(try Data(contentsOf: url) == Data(envelope.utf8), "a newer envelope is never overwritten")

        // Quitting: neither the refusal nor a failed write throws or touches the file.
        await storage.saveAtQuit(archive, revision: 6)
        check(try Data(contentsOf: url) == Data(envelope.utf8), "quitting over a newer envelope leaves it untouched")
        try legacy.write(to: url)
        await storage.saveAtQuit(archive, revision: 7)
        check(try Data(contentsOf: url) == legacy, "quitting over a newer legacy payload leaves it untouched")
        if geteuid() != 0 {
            let locked = directory.appendingPathComponent("locked")
            try fm.createDirectory(at: locked, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
            let unwritable = WindowSessionStorage(url: locked.appendingPathComponent("session.json"))
            var failed = false
            do { _ = try await unwritable.save(archive, revision: 1) } catch { failed = true }
            check(failed, "an unwritable folder fails an autosave")
            await unwritable.saveAtQuit(archive, revision: 2)
            check(!fm.fileExists(atPath: locked.appendingPathComponent("session.json").path), "the failed quit save wrote nothing")
        }
        let quitURL = directory.appendingPathComponent("quit-session.json")
        let quitStorage = WindowSessionStorage(url: quitURL)
        await quitStorage.saveAtQuit(archive, revision: 1)
        check(await quitStorage.load()?.windows.map(\.id) == windows.map(\.id), "a normal quit saves the archive")

        // A new launch tells the user again.
        try Data(envelope.utf8).write(to: url)
        check(try await WindowSessionStorage(url: url).save(archive, revision: 1) == .refused(announce: true),
              "a new launch announces the refusal again")
    }

    /// Seed only the dedicated test bundle's archive, never the installed app's state.
    static func seedUI(at root: URL) async throws {
        let a = root.appendingPathComponent("Restore-A"), b = root.appendingPathComponent("Restore-B")
        for folder in [a, b] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["first.md", "second.md"] {
                try "# Fixture \(name)\n\nSaved on disk.\n".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        let panels = WorkspacePanelState(navigator: "contents", left: "files", feature: "", git: "changes", stage: "explore", showFiles: true, showNavigator: true)
        func file(_ folder: URL, _ name: String) -> WorkspaceTabState {
            .file(url: folder.appendingPathComponent(name), draft: nil, notes: false, scroll: 0)
        }
        let edited = WorkspaceDraft(content: "# Unsaved test draft\n\nRecovered after restart.\n", original: "# Fixture second.md\n\nSaved on disk.\n")
        let deleted = WorkspaceDraft(content: "# Deleted-file draft\n", original: "# Old text\n")
        let first = WorkspaceWindowState(id: UUID(), folder: a,
            tabs: [file(a, "first.md"), .file(url: a.appendingPathComponent("second.md"), draft: edited, notes: false, scroll: 0),
                   .file(url: a.appendingPathComponent("removed.md"), draft: deleted, notes: false, scroll: 0)],
            activeTabIndex: 1, panels: panels, frame: CGRect(x: 30, y: 350, width: 1050, height: 750))
        let second = WorkspaceWindowState(id: UUID(), folder: b,
            tabs: [file(b, "first.md"), file(b, "missing.md"), file(b, "second.md")],
            activeTabIndex: 2, panels: panels, frame: CGRect(x: 1130, y: 350, width: 1050, height: 750))
        let duplicateFolder = WorkspaceWindowState(id: UUID(), folder: a, tabs: [file(a, "first.md")],
            activeTabIndex: 0, panels: panels, frame: CGRect(x: 150, y: 150, width: 1050, height: 750))
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storage = WindowSessionStorage(url: support.appendingPathComponent("MarkView-com.markview.WindowRestoreTest/windowSessions.json"))
        _ = try await storage.save(WindowSessionArchive(windows: [first, second, duplicateFolder]), revision: 1)
        print("Seeded three test windows in two fixture folders.")
    }
}
