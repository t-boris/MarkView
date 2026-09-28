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
                   .image(folder.appendingPathComponent("image.png")), .architecture("src"), .terminal(folder)],
            activeTabIndex: 1,
            panels: WorkspacePanelState(workspaceArea: "Work", workSection: "Git", navigator: "terminal", left: "issues", feature: "one", git: "changes", stage: "explore", showFiles: true, showNavigator: false, contentsVisible: false, terminalVisible: true, showCenter: false),
            frame: CGRect(x: 300, y: 400, width: 1200, height: 800), minimized: true)
        let second = WorkspaceWindowState(id: UUID(), folder: folder)
        let archive = WindowSessionArchive(windows: [first, second])
        try await storage.save(archive, revision: 1)
        let loaded = await WindowSessionStorage(url: url).load()!
        check(loaded.windows.count == 2, "same-folder windows must not collapse")
        check(loaded.windows.map(\.id) == [first.id, second.id], "identities and order survive a new process")
        check(loaded.windows[0].folder == folder, "folder URLs survive spaces")
        check(loaded.windows[0].activeTabIndex == 1, "active tab survives")
        check(loaded.windows[0].frame == first.frame && loaded.windows[0].minimized, "window placement survives")
        check(loaded.windows[0].panels?.feature == "one" && loaded.windows[0].panels?.showNavigator == false, "per-window panels survive")
        check(loaded.windows[0].panels?.workspaceArea == "Work" && loaded.windows[0].panels?.workSection == "Git",
              "workspace and Work section survive per window")
        check(loaded.windows[0].panels?.contentsVisible == false && loaded.windows[0].panels?.terminalVisible == true &&
              loaded.windows[0].panels?.showCenter == false, "column visibility survives per window")
        check(loaded.windows[0].tabs.count == 5, "all supported tab kinds survive")
        if case .file(let restoredURL, let restoredDraft, let notes, let scroll) = loaded.windows[0].tabs[0] {
            check(restoredURL == file && notes && scroll == 123.5, "file view state survives")
            check(restoredDraft?.content == draft.content && restoredDraft?.original == draft.original, "unsaved text survives without a disk write")
        } else { fatalError("wrong tab kind") }
        if case .github(let item) = loaded.windows[0].tabs[1] {
            check(item == .issue(number: 33, repo: "owner/repo", title: "#33"), "GitHub tabs survive")
        } else { fatalError("wrong GitHub tab") }
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        check(permissions.intValue == 0o600, "draft archive is private")
        try await storage.save(WindowSessionArchive(windows: [second]), revision: 3)
        try await storage.save(archive, revision: 2)
        let afterStale = await storage.load()!
        check(afterStale.windows.count == 1 && afterStale.windows[0].id == second.id, "older autosave cannot overwrite the quit snapshot")
        try await storage.save(WindowSessionArchive(windows: []), revision: 4)
        let allClosed = await storage.load()!
        check(allClosed.windows.isEmpty, "closing all windows stays closed; does not fall back to last folder")
        try await storage.save(WindowSessionArchive(windows: [first, first, second]), revision: 5)
        let deduplicated = await storage.load()!
        check(deduplicated.windows.count == 2, "corrupt duplicate identities cannot open duplicate windows")
        let external = WorkspaceWindowState(id: UUID(), folder: URL(string: "https://example.com")!)
        try await storage.save(WindowSessionArchive(windows: [external]), revision: 6)
        let rejected = await storage.load()
        check(rejected == nil, "external folder URLs are rejected")
        try Data("corrupt archive".utf8).write(to: url)
        let corrupt = await storage.load()
        check(corrupt == nil, "corrupt archive does not crash startup")
        try JSONEncoder().encode(WindowSessionArchive(version: 99, windows: [first])).write(to: url)
        let unknown = await storage.load()
        check(unknown == nil, "unknown archive versions are rejected")
        print("Window session checks: \(checks), failures: 0")
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
        try await storage.save(WindowSessionArchive(windows: [first, second, duplicateFolder]), revision: 1)
        print("Seeded three test windows in two fixture folders.")
    }
}
