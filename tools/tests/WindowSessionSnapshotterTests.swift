import Foundation

// A window's theme is its id; these are the ids the checks use.
extension AppTheme {
    static let midnight = AppTheme("midnight")
}

/// A window's session taken and put back (`AR-14` step 7): the real `TabsController`, `WindowChrome`, `PanelLayout` and
/// `WindowUIState` of one window are saved through the real session storage and restored into another window. Only what the manager
/// alone can open (a folder, a terminal, a browser, an architecture view, a tool) is played by a fake host that records the calls.
@main
enum WindowSessionSnapshotterChecks {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        }
    }

    /// A window as the snapshotter sees it.
    @MainActor
    final class FakeHost: WindowSessionHost {
        let tabs = TabsController(dialogs: TabDialogs(askToSave: { _, _ in .cancel }, reportFailedSave: { _ in }, offerDefaultApp: { _, _ in false }))
        let chrome = WindowChrome(defaults: UserDefaults(suiteName: "snapshotter-\(UUID().uuidString)")!)
        let layout = PanelLayout(defaults: UserDefaults(suiteName: "snapshotter-\(UUID().uuidString)")!)
        let windowUI = WindowUIState(defaults: UserDefaults(suiteName: "snapshotter-\(UUID().uuidString)")!)
        var themeSettings = WindowThemeSettings.fallback
        var windowFolder: URL?
        var terminals: [UUID: URL] = [:]
        /// The calls the manager alone can answer, in order.
        var calls: [String] = []
        /// A folder the person chose while the session was being restored.
        var folderChosenMeanwhile: URL?

        func terminalDirectory(for id: UUID) -> URL? { terminals[id] }
        func restoreFolder(_ folder: URL) async {
            calls.append("folder:" + folder.lastPathComponent)
            windowFolder = folderChosenMeanwhile ?? folder
        }
        func openTool(_ tool: ToolID) {
            calls.append("tool:" + tool.rawValue)
            var tab = OpenTab(url: URL(fileURLWithPath: "/tmp/.tool-\(tool)"), content: "", originalContent: "")
            tab.kind = .tool(tool)
            tabs.appendTab(tab)
        }
        func openFile(_ url: URL) {
            calls.append("file:" + url.lastPathComponent)
            tabs.openDocument(url)
        }
        func openGitHubTab(_ item: GitHubItem) {
            calls.append("github:" + item.title)
            var tab = OpenTab(url: URL(fileURLWithPath: "/tmp/" + item.marker), content: "", originalContent: "")
            tab.kind = .github(item)
            tabs.appendTab(tab)
        }
        func restoreArchitectureTab(scope: String) {
            calls.append("architecture:" + scope)
            var tab = OpenTab(url: URL(fileURLWithPath: "/tmp/.xray-" + scope), content: "", originalContent: "")
            tab.kind = .architecture(scope: scope)
            tabs.appendTab(tab)
        }
        func restoreTerminal(in directory: URL) {
            calls.append("terminal:" + directory.lastPathComponent)
            let id = UUID()
            terminals[id] = directory
            var tab = OpenTab(url: directory.appendingPathComponent(".terminal"), content: "", originalContent: "")
            tab.kind = .terminal(id)
            tabs.appendTab(tab)
        }
        func restoreBrowser(_ url: URL) {
            calls.append("browser:" + url.absoluteString)
            var tab = OpenTab(url: url, content: "", originalContent: "")
            tab.kind = .browser(BrowserSession(url: url))
            tabs.appendTab(tab)
        }
    }

    static func write(_ text: String, to url: URL) { try? text.write(to: url, atomically: true, encoding: .utf8) }

    @MainActor
    static func kindName(_ tab: OpenTab) -> String {
        switch tab.kind {
        case .file: return "file:" + tab.url.lastPathComponent
        case .image: return "image:" + tab.url.lastPathComponent
        case .pdf: return "pdf:" + tab.url.lastPathComponent
        case .data: return "data:" + tab.url.lastPathComponent
        case .archive: return "archive:" + tab.url.lastPathComponent
        case .github(let item): return "github:" + item.title
        case .architecture(let scope): return "architecture:" + scope
        case .terminal: return "terminal"
        case .browser(let session): return "browser:" + (session.url?.absoluteString ?? "")
        case .tool(let tool): return "tool:" + tool.rawValue
        default: return "other"
        }
    }

    @MainActor
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshotter-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.md"), draft = root.appendingPathComponent("draft.md")
        let picture = root.appendingPathComponent("picture.png"), paper = root.appendingPathComponent("paper.pdf"), rows = root.appendingPathComponent("rows.csv")
        write("# Note\n\nsaved\n", to: note)
        write("# Draft\n\nfrom disk\n", to: draft)
        for url in [picture, paper, rows] { try? Data("x".utf8).write(to: url) }

        // --- A window with every kind of tab, panels and interface state.
        let source = FakeHost()
        source.windowFolder = root
        source.themeSettings = WindowThemeSettings(theme: .midnight, accents: [.midnight: ThemeColor(0xFF4D9A)])
        await source.tabs.openTextFile(note)
        await source.tabs.openTextFile(draft)
        source.tabs.updateTabContent("# Draft\n\nunsaved typing\n", documentID: source.tabs.openTabs[1].id)
        source.tabs.scroll.setScrollPosition(321.5, for: source.tabs.openTabs[0].id)
        source.tabs.scroll.setScrollPosition(88, for: source.tabs.openTabs[1].id)
        source.tabs.updateTab(at: 0) { $0.notesView = true }
        source.tabs.openDocument(picture)
        source.tabs.openDocument(paper)
        source.tabs.openDocument(rows)
        source.openGitHubTab(.issue(number: 33, repo: "owner/repo", title: "#33"))
        source.restoreArchitectureTab(scope: "src")
        source.openTool(.git)
        source.openTool(.uiStudio)          // saved only when the descriptor says so
        source.restoreTerminal(in: root)
        source.restoreBrowser(URL(string: "https://example.com/page")!)
        var local = OpenTab(url: URL(string: "file:///tmp/local.html")!, content: "", originalContent: "")
        local.kind = .browser(BrowserSession(url: URL(string: "file:///tmp/local.html")))
        source.tabs.appendTab(local)        // only http(s) pages are saved
        var insight = OpenTab(url: URL(fileURLWithPath: "/tmp/.insight"), content: "", originalContent: "")
        insight.kind = .insight(InsightSession())
        source.tabs.appendTab(insight)      // in-memory jobs are not saved
        source.tabs.activeTabIndex = source.tabs.openTabs.firstIndex { kindName($0) == "pdf:paper.pdf" } ?? -1

        source.chrome.showFileTree = true
        source.chrome.showTOC = true
        source.chrome.showCenter = true
        source.chrome.terminalVisible = true
        source.chrome.agentsVisible = true
        source.layout.workspaceArea = .work
        source.layout.workSection = .git
        source.layout.navigatorTab = .feature
        source.layout.leftPanel = "issues"
        source.layout.issuesFeature = "feature-one"
        source.layout.gitSection = .pullRequests
        source.layout.featureStage = .build
        source.layout.welcomeBackdrop = WelcomeBackdrop.all.last!
        source.windowUI.set("Documents", for: Setting.searchPanelMode, publishing: false)
        source.windowUI.set(412.0, for: Setting.uiStudioInspectorWidth, publishing: false)

        let id = UUID()
        let state = WindowSessionSnapshotter.snapshot(of: source, id: id)
        check(state.id == id && state.folder == root, "the snapshot names the window and its folder")
        check(state.tabs.count == 10, "ten of the thirteen tabs are saved: not the live UI Studio, the local page or the Insight job (\(state.tabs.count))")

        // Through the real storage, as a relaunch does.
        let storageURL = root.appendingPathComponent("windowSessions.json")
        let storage = WindowSessionStorage(url: storageURL)
        let saved = try? await storage.save(WindowSessionArchive(windows: [state]), revision: 1)
        check(saved == .saved, "the session is written")
        guard let loaded = await WindowSessionStorage(url: storageURL).load()?.windows.first else {
            check(false, "the session is read back by a new process"); return finish()
        }

        // --- Another window takes it.
        let target = FakeHost()
        await WindowSessionSnapshotter.restore(loaded, into: target)
        let restored = target.tabs.openTabs.map(kindName)
        let wanted = ["file:note.md", "file:draft.md", "image:picture.png", "pdf:paper.pdf", "data:rows.csv", "github:#33", "architecture:src",
                      "tool:git", "terminal", "browser:https://example.com/page"]
        check(restored == wanted, "the tabs come back in order (\(restored))")
        check(target.windowFolder == root && target.calls.first == "folder:" + root.lastPathComponent, "the folder is opened before the tabs")
        check(target.tabs.activeTabIndex == 3, "the active tab is the one that was active (\(target.tabs.activeTabIndex))")
        check(target.tabs.openTabs[0].content == "# Note\n\nsaved\n" && !target.tabs.openTabs[0].isModified, "a clean file is read from disk")
        check(target.tabs.openTabs[0].notesView, "the notes view of a tab comes back")
        check(target.tabs.openTabs[1].content == "# Draft\n\nunsaved typing\n" && target.tabs.openTabs[1].isModified, "unsaved typing comes back as a draft")
        check(target.tabs.openTabs[1].originalContent == "# Draft\n\nfrom disk\n", "the draft still knows what the disk holds")
        check(target.tabs.openTabs[1].headings.map(\.text) == ["Draft"], "a restored draft lists its own headings")
        check(target.tabs.scroll.scrollPosition(for: target.tabs.openTabs[0].id) == 321.5
              && target.tabs.scroll.scrollPosition(for: target.tabs.openTabs[1].id) == 88, "scroll positions come back")
        check((try? String(contentsOf: draft)) == "# Draft\n\nfrom disk\n", "restoring a draft does not write the file")
        check(target.terminals.values.first == root, "the terminal is opened in its folder")

        // The panels and what the window shows of itself.
        check(target.chrome.showFileTree && target.chrome.showTOC && target.chrome.showCenter && target.chrome.terminalVisible && target.chrome.agentsVisible,
              "the panels come back")
        check(target.layout.workspaceArea == .work && target.layout.leftPanel == "issues" && target.layout.issuesFeature == "feature-one"
              && target.layout.gitSection == .pullRequests && target.layout.featureStage == .build && target.layout.navigatorTab == .feature,
              "the tab each panel shows comes back")
        check(target.layout.workSection == .git, "the Work section comes back")
        check(target.layout.welcomeBackdrop == WelcomeBackdrop.all.last!, "the window's welcome backdrop comes back")
        check(target.windowUI.value(Setting.searchPanelMode) == "Documents" && target.windowUI.value(Setting.uiStudioInspectorWidth) == 412,
              "the interface state of the window comes back")
        check(loaded.theme == source.themeSettings, "the theme settings of the window are in the session")

        // --- A session whose files changed while the app was closed.
        try? FileManager.default.removeItem(at: note)         // clean file removed: nothing to show
        try? FileManager.default.removeItem(at: draft)        // modified file removed: the typing must survive
        try? FileManager.default.removeItem(at: picture)
        let afterwards = FakeHost()
        await WindowSessionSnapshotter.restore(loaded, into: afterwards)
        let names = afterwards.tabs.openTabs.map(kindName)
        check(!names.contains("file:note.md") && !names.contains("image:picture.png"), "files that are gone are not reopened (\(names))")
        check(names.contains("file:draft.md"), "a removed file keeps the unsaved text the person typed")
        if let index = names.firstIndex(of: "file:draft.md") {
            check(afterwards.tabs.openTabs[index].content == "# Draft\n\nunsaved typing\n" && afterwards.tabs.openTabs[index].isModified,
                  "the kept draft is modified and holds the typing")
        }
        check(afterwards.tabs.openTabs[afterwards.tabs.activeTabIndex].kind.isPDFTab, "the active tab is found again after others dropped out")

        // --- The Welcome tab is a choice too.
        var welcome = state
        welcome.activeTabIndex = -1
        let atWelcome = FakeHost()
        await WindowSessionSnapshotter.restore(welcome, into: atWelcome)
        check(atWelcome.tabs.activeTabIndex == -1 && !atWelcome.tabs.openTabs.isEmpty, "a window that showed the Welcome tab shows it again")

        // --- A folder chosen while the old session loads wins: nothing of the old session opens.
        let busy = FakeHost()
        busy.folderChosenMeanwhile = root.appendingPathComponent("elsewhere")
        await WindowSessionSnapshotter.restore(loaded, into: busy)
        check(busy.tabs.openTabs.isEmpty && busy.calls == ["folder:" + root.lastPathComponent], "a folder chosen meanwhile wins over the old session")

        // --- What a session must not do.
        var hostile = WorkspaceWindowState(id: UUID(), folder: URL(string: "https://example.com/not-a-folder"))
        hostile.tabs = [.file(url: URL(string: "https://example.com/a.md")!, draft: nil, notes: false, scroll: 0),
                        .file(url: rows, draft: nil, notes: false, scroll: .infinity),
                        .browser(URL(string: "file:///etc/passwd")!), .terminal(root.appendingPathComponent("missing-folder")),
                        .tool(.uiStudio)]
        hostile.activeTabIndex = 99
        let careful = FakeHost()
        await WindowSessionSnapshotter.restore(hostile, into: careful)
        check(careful.calls.isEmpty, "a web address is no folder, a non-file tab, a local page, a missing folder and a tool that is not restorable open nothing (\(careful.calls))")
        check(careful.tabs.openTabs.count == 1 && careful.tabs.scroll.scrollPosition(for: careful.tabs.openTabs[0].id) == 0,
              "a scroll position that is not a number becomes the top of the file")
        check(careful.tabs.activeTabIndex == 0, "an active tab index past the end falls back to the first tab")

        finish()
    }

    static func finish() {
        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) check(s) failed\n".utf8))
            exit(1)
        }
        print("WindowSessionSnapshotter: tabs, drafts, scroll, panels and interface state survive a session; changed disks and odd sessions are handled")
    }
}

extension TabKind {
    var isPDFTab: Bool { if case .pdf = self { return true }; return false }
}
