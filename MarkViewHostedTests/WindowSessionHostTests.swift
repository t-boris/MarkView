import AppKit
import Foundation
import MarkViewCore
import SwiftUI
import XCTest
@testable import MarkView

// A window's theme is its id; these are the ids the checks use.
private extension AppTheme {
    static let midnight = AppTheme("midnight"), paper = AppTheme("paper")
}

private enum WindowSessionChecks {
    static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        XCTAssertTrue(condition, message, line: line)
    }
    static func run() async throws {
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
        } else { XCTFail("wrong PDF tab kind") }
        if case .file(let restoredURL, let restoredDraft, let notes, let scroll) = loaded.windows[0].tabs[0] {
            check(restoredURL == file && notes && scroll == 123.5, "file view state survives")
            check(restoredDraft?.content == draft.content && restoredDraft?.original == draft.original, "unsaved text survives without a disk write")
        } else { XCTFail("wrong tab kind") }
        if case .github(let item) = loaded.windows[0].tabs[1] {
            check(item == .issue(number: 33, repo: "owner/repo", title: "#33"), "GitHub tabs survive")
        } else { XCTFail("wrong GitHub tab") }
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
        } else { XCTFail("the first tab is a file") }
        if case .github(let item) = restored[12] { check(item == .run(id: 4, repo: "o/r", title: "run"), "a GitHub tab of an earlier version loads") } else { XCTFail("the 13th tab is a run") }
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

}

/// A window that never takes the key focus. The test host is never active: there, a closed key window can stay `NSApp`'s key
/// window, as no other window takes the focus, and stay alive for that reason alone (seen while finding BUG-138's holder).
private final class UnfocusedWindow: NSWindow {
    override var canBecomeKey: Bool { false }
}

extension EditorHostTests {
    func testWindowSessionPersistence() async throws { try await WindowSessionChecks.run() }

    /// A closed window's workspace is freed (BUG-138): nothing it made keeps it once its close has run, with its folder and a
    /// file open.
    @MainActor func testAClosedWindowsWorkspaceIsFreed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-freed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appendingPathComponent("note.md")
        try Data("# Note\n".utf8).write(to: note)
        weak var released: WorkspaceManager?
        do {
            let workspace = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: folder.appendingPathComponent("recent.json"))
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 100, height: 100),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            workspace.hostWindow = window
            workspace.openFolder(folder)
            for _ in 0..<500 where workspace.projectFolder == nil || workspace.rootNode == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNotNil(workspace.rootNode)
            workspace.openFile(note)
            for _ in 0..<500 where workspace.tabs.openTabs.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(workspace.tabs.openTabs.map(\.url.lastPathComponent), ["note.md"])
            released = workspace
            // What closing the window runs (`WindowSessionController`'s willClose handler).
            workspace.windowWillClose()
            withExtendedLifetime(window) {}
        }
        for _ in 0..<300 where released != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(released, "the closed window's workspace is still alive")
    }

    /// The window's own view, shown in a window and closed, lets go of that window and of its workspace. The view kept its window
    /// in a strong `@State`, which lives in the window's own view graph: the closed window, the graph and the workspace with its
    /// project database stayed alive (BUG-138).
    @MainActor func testAClosedWorkspaceWindowLetsGoOfItsView() async throws {
        weak var closedWindow: NSWindow?
        weak var closedWorkspace: AnyObject?
        do {
            let window = UnfocusedWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600),
                                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let hosting = NSHostingView(rootView: ContentView())
            window.contentView = hosting
            // The view offers its workspace to the control tools once it knows its window.
            var shown: (any AgentControlWindow)?
            for _ in 0..<500 {
                hosting.layoutSubtreeIfNeeded()
                shown = AgentToolServer.liveWindows().first { $0.workspace.hostWindow === window }?.workspace
                if shown != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let workspace = try XCTUnwrap(shown, "the window's view never showed its workspace")
            // A person closes a window that its session has taken: its close is handled from then on.
            for _ in 0..<500 where !(window.delegate is WindowCloseDelegate) { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(window.delegate is WindowCloseDelegate, "the window's session never took the window")
            closedWindow = window
            closedWorkspace = workspace
            window.close()
        }
        // The app's event loop takes the window's events; the test host runs none, and a waiting event, or the last one taken,
        // holds the window it names (seen while finding BUG-138's holder). Take them, ending with an event of no window.
        for _ in 0..<500 where closedWindow != nil || closedWorkspace != nil {
            while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
            if let empty = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(empty, atStart: false)
                _ = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let seenBy = closedWindow.map { window in
            [NSApp.keyWindow === window ? "the key window" : nil, NSApp.mainWindow === window ? "the main window" : nil,
             NSApp.currentEvent?.window === window ? "the current event" : nil,
             NSApp.windows.contains(window) ? "NSApp.windows" : nil, window.isVisible ? "visible" : nil]
                .compactMap { $0 }.joined(separator: ", ")
        } ?? ""
        // macOS 27 frees the closed window; on macOS 26 (the CI runner) something more keeps it, not yet known (BUG-138). There a
        // failure is expected until that holder is found, and the window's direct holders go to the log.
        if let address = closedWindow.map({ String(describing: Unmanaged.passUnretained($0).toOpaque()) }) {
            await Self.logHolders(of: address)
        }
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.isEnabled = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
        XCTExpectFailure("BUG-138: on macOS 26 a holder not yet known keeps a closed window", options: options)
        XCTAssertNil(closedWindow, "the closed window is still alive (\(seenBy))")
        XCTAssertNil(closedWorkspace, "the closed window's workspace is still alive")
    }

    /// Writes the direct holders of the object at `address` in this process to the log: the first level of
    /// `leaks --traceTree`, one line per holder.
    private static func logHolders(of address: String) async {
        let result = await Subprocess.run(.init(executable: "/usr/bin/leaks",
                                                arguments: ["--traceTree=\(address)", String(getpid())], timeout: 120))
        let holders = result.stdout.split(separator: "\n").filter { line in
            line.hasPrefix("      ") && line.dropFirst(6).first?.isNumber == true
        }
        print("BUG-138: direct holders of the closed window (leaks exit \(result.exitCode)):\n" + holders.joined(separator: "\n"))
    }
}
