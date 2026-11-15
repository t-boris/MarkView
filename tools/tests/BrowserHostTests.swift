import Combine
import Foundation

// The browser of a window (AR-14 step 9): the shipping `BrowserHost` over the shipping tabs (`TabsController`), panels, project web-app
// discovery and control window (`AgentToolWindow`), on real temporary folders and a real local port. The tab itself (a WebKit
// view), the terminals and the stores the control tools reach are stand-ins (`BrowserHostStubs.swift`); no page is loaded and no window
// is shown.

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)")
    }
}

@MainActor
func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

nonisolated(unsafe) var temporaryFolders: [URL] = []

func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("browser-host-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    temporaryFolders.append(url)
    return url
}

let defaultsSuite = "browser-host-tests-panels"

func defaults() -> UserDefaults {
    let suite = UserDefaults(suiteName: defaultsSuite)!
    suite.removePersistentDomain(forName: defaultsSuite)
    return suite
}

/// A free port of the loopback interface: bound and closed again.
func freePort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    return Int(UInt16(bigEndian: bound.sin_port))
}

/// A server on the loopback interface that answers every request with a short page, closed by `stop`.
struct Listener {
    let fd: Int32
    let port: Int
    func stop() { close(fd) }
}

func listen() -> Listener {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    Foundation.listen(fd, 8)
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    let thread = Thread {
        let reply = Array("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            var buffer = [UInt8](repeating: 0, count: 2048)
            _ = read(client, &buffer, buffer.count)
            _ = write(client, reply, reply.count)
            close(client)
        }
    }
    thread.start()
    return Listener(fd: fd, port: Int(UInt16(bigEndian: bound.sin_port)))
}

/// The window around the host: it opens the dev server's terminal as a tab, as the manager does.
@MainActor
final class StubWindow: BrowserHostWindow {
    let workspace = WorkspaceManager()
    let features = FeatureStore()
    let deployments = DeploymentStore()
    let discussions = DiscussionStore()
    var tabs: TabsController!
    var terminals: [TerminalSession] = []
    var controlWorkspace: WorkspaceManager { workspace }
    var controlFeatures: FeatureStore { features }
    var controlDeployments: DeploymentStore { deployments }
    var controlDiscussions: DiscussionStore { discussions }
    func openTerminal(in folder: URL, startupCommand: String?, title: String?, activate: Bool) -> TerminalSession {
        let session = TerminalSession(directory: folder, startupCommand: startupCommand)
        terminals.append(session)
        var tab = OpenTab(url: folder.appendingPathComponent(".terminal-" + session.id.uuidString), content: "", originalContent: "")
        tab.kind = .terminal(session.id)
        tabs.appendTab(tab, activate: activate)
        return session
    }
}

@MainActor
struct Rig {
    let folder: URL
    let project = StubProject()
    let tabs = TabsController(dialogs: TabDialogs(askToSave: { _, _ in .cancel }, confirmSave: { _, _ in false },
                                                  reportFailedSave: { _ in }, offerDefaultApp: { _, _ in false }))
    let layout = PanelLayout(defaults: defaults())
    let chrome = WindowChrome(defaults: defaults())
    let terminals = StubTerminals()
    let window = StubWindow()
    let browser: BrowserHost

    init(folder: URL = temporaryFolder(), open: Bool = true) {
        self.folder = folder
        if open { project.root = folder }
        window.tabs = tabs
        browser = BrowserHost(tabs: tabs, layout: layout, chrome: chrome, project: project, terminals: terminals, window: window)
    }

    /// The browser tabs, in order.
    var sessions: [BrowserSession] { browser.sessions }
}

func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

/// A web app the project declares itself (`.markview/preview.json`), so discovery needs no package manager.
func declareApp(_ folder: URL, command: String, ports: [Int], reuse: Bool) {
    let reuseText = reuse ? "true" : "false"
    write(#"{"command":"\#(command)","ports":\#(ports),"reuseRunningServer":\#(reuseText)}"#, to: folder.appendingPathComponent(".markview/preview.json"))
}

// MARK: Tabs

@MainActor
func tabs() {
    print("-- browser tabs")
    let rig = Rig()
    rig.chrome.showCenter = false
    rig.layout.workspaceArea = .work
    let first = rig.browser.open(nil)
    check(first.agentName == "T1" && first.host === rig.browser, "a new browser tab is named for agents and reaches its window through the host")
    check(rig.tabs.openTabs.count == 1 && rig.tabs.activeTabIndex == 0 && rig.chrome.showCenter && rig.layout.workspaceArea == .files,
          "it opens next to the files, active, with the center panel shown")
    if case .browser(let shown) = rig.tabs.openTabs[0].kind { check(shown === first, "the tab carries the session") } else { check(false, "the tab is a browser tab") }
    check(rig.tabs.openTabs[0].url.deletingLastPathComponent().path == rig.folder.path, "its placeholder file lives in the project folder")

    first.agentName = "Jira"
    let second = rig.browser.open(URL(string: "https://example.com/")!)
    check(second.agentName == "T1" && second.url?.absoluteString == "https://example.com/", "the next free name is chosen (T1 is free again once the first is named Jira)")
    let third = rig.browser.open(nil)
    check(third.agentName == "T2", "names do not repeat")
    check(rig.browser.sessions.map(\.id) == [first.id, second.id, third.id], "the sessions are listed in tab order")

    rig.layout.workspaceArea = .work
    rig.chrome.showCenter = false
    rig.browser.show(first)
    check(rig.tabs.activeTabIndex == 0 && rig.layout.workspaceArea == .files && rig.chrome.showCenter, "showing a session brings its tab forward")
    rig.browser.show(BrowserSession(url: nil))
    check(rig.tabs.activeTabIndex == 0, "a session that has no tab changes nothing")

    let quiet = Rig()
    quiet.chrome.showCenter = false
    let background = quiet.browser.open(nil, activate: false)
    check(!quiet.chrome.showCenter && quiet.tabs.openTabs.count == 1 && background.agentName == "T1", "a restored tab opens without taking the window")

    let nowhere = Rig(open: false)
    _ = nowhere.browser.open(nil)
    check(nowhere.tabs.openTabs.count == 1 && nowhere.tabs.openTabs[0].url.path.hasPrefix(FileManager.default.temporaryDirectory.path),
          "with no project folder the tab's placeholder file is in the temporary folder")
}

@MainActor
func pagesOpenedByOthers() async {
    print("-- pages opened by programs")
    let rig = Rig()
    let page = URL(string: "http://localhost:3000/app")!
    rig.browser.openInAppBrowser(page)
    check(rig.sessions.count == 1 && rig.sessions[0].url == page, "with no browser tab a terminal's page opens in a new one")

    let other = rig.browser.open(URL(string: "http://localhost:5173/")!)
    rig.tabs.activeTabIndex = 1
    let next = URL(string: "http://localhost:3000/other")!
    rig.browser.openInAppBrowser(next)
    check(rig.sessions.count == 2 && rig.sessions[0].url == next && rig.tabs.activeTabIndex == 0, "the tab already on the same server is reused and shown")
    check(other.url?.absoluteString == "http://localhost:5173/", "and the other tab is left alone")

    let third = URL(string: "http://localhost:9999/x")!
    rig.tabs.activeTabIndex = 1
    rig.browser.openInAppBrowser(third)
    check(rig.sessions.count == 2 && rig.sessions[1].url == third && rig.sessions[0].url == next && rig.tabs.activeTabIndex == 1,
          "a new server goes into the active browser tab")

    let preview = Rig()
    let a = preview.browser.open(URL(string: "http://localhost:1/")!)
    let b = preview.browser.open(URL(string: "http://localhost:2/")!)
    b.isAppPreview = true
    write("note", to: preview.folder.appendingPathComponent("note.md"))
    await preview.tabs.openTextFile(preview.folder.appendingPathComponent("note.md"))
    preview.browser.openInAppBrowser(URL(string: "http://localhost:3/")!)
    check(b.url?.absoluteString == "http://localhost:3/" && a.url?.absoluteString == "http://localhost:1/",
          "when a document is active the preview tab takes the page")
    let firstOnly = Rig()
    let only = firstOnly.browser.open(URL(string: "http://localhost:1/")!)
    write("note", to: firstOnly.folder.appendingPathComponent("note.md"))
    await firstOnly.tabs.openTextFile(firstOnly.folder.appendingPathComponent("note.md"))
    firstOnly.browser.openInAppBrowser(URL(string: "http://localhost:4/")!)
    check(only.url?.absoluteString == "http://localhost:4/" && firstOnly.sessions.count == 1, "otherwise the first browser tab takes it")
}

@MainActor
func localHTML() {
    print("-- local HTML files")
    let rig = Rig()
    let page = rig.folder.appendingPathComponent("site/index.html")
    write("<html></html>", to: page)
    rig.browser.openHTML(rig.folder.appendingPathComponent("site/missing.html"))
    rig.browser.openHTML(rig.folder.appendingPathComponent("site/notes.md"))
    check(rig.sessions.isEmpty, "a file that is missing or is not HTML opens nothing")
    rig.browser.openHTML(page)
    check(rig.sessions.count == 1 && rig.sessions[0].url == page.standardizedFileURL && rig.sessions[0].localReadRoot == rig.folder,
          "an HTML file opens in a tab that may read the project's files")
    rig.browser.open(nil)
    rig.tabs.activeTabIndex = 1
    rig.browser.openHTML(page)
    check(rig.sessions.count == 2 && rig.tabs.activeTabIndex == 0 && rig.sessions[0].loaded.count == 2, "the tab already showing it is shown again and reloaded")
}

// MARK: Control by agents

@MainActor
func control() async {
    print("-- control by agents")
    let rig = Rig()
    AgentToolServer.registered = [:]
    rig.browser.register()
    guard let window = AgentToolServer.registered[rig.browser.controlID] else { check(false, "the window is registered"); return }
    check(window.workspace() === rig.window.workspace && window.root() == rig.folder, "the control tools reach the window's workspace and folder")
    check(window.features() === rig.window.features && window.deployments() === rig.window.deployments && window.discussions() === rig.window.discussions,
          "and the stores of the window")
    let none = await window.browser("browser_tabs", [:])
    check(!none.isError && none.text.contains("No browser tabs are open") && rig.sessions.isEmpty, "no browser tab, none listed")
    let opened = await window.browser("browser_open_tab", ["url": "https://example.com/", "name": "Jira"])
    check(!opened.isError && opened.text.hasPrefix("Opened tab Jira.") && rig.sessions.map(\.agentName) == ["Jira"] && rig.sessions[0].url == URL(string: "https://example.com/"),
          "an agent opens a named tab on an address")
    let listed = await window.browser("browser_tabs", [:])
    check(listed.text.contains("Jira") && listed.text.contains("[active]"), "which is the active one")
    write("note", to: rig.folder.appendingPathComponent("note.md"))
    await rig.tabs.openTextFile(rig.folder.appendingPathComponent("note.md"))
    check(!(await window.browser("browser_tabs", [:])).text.contains("[active]"), "a document in front is no active browser tab")
    let ran = await window.browser("browser_snapshot", ["tab": "Jira"])
    check(ran.text == "browser_snapshot ran in Jira" && rig.tabs.activeTabIndex == 0 && rig.sessions[0].agentLastUsed != nil,
          "a tool runs in the tab it names, brings it to the front and marks it used")
    let unnamed = await window.browser("browser_open_tab", [:])
    check(unnamed.text == "Opened tab T1." && rig.sessions.map(\.agentName) == ["Jira", "T1"], "a tab opened without a name gets the next free one")
    let missing = await window.browser("browser_click", ["tab": "Nowhere"])
    check(missing.isError && missing.text.contains("No single browser tab matches"), "a tab that does not exist is refused with the list of the open ones")
    rig.sessions[0].agentStopped = true
    let stopped = await window.browser("browser_click", ["tab": "Jira"])
    check(stopped.isError && stopped.text.contains("stopped agent control"), "a tab the user stopped is not driven")
    AgentToolServer.registered = [:]
}

// MARK: Preview Web App

@MainActor
func preview() async {
    print("-- Preview Web App")
    let none = Rig(open: false)
    none.browser.previewWebApp()
    check(none.sessions.count == 1 && none.sessions[0].isAppPreview && none.sessions[0].preview == .noApp, "with no folder there is no app to find")

    let rig = Rig()
    declareApp(rig.folder.appendingPathComponent("web"), command: "npm run dev", ports: [freePort()], reuse: false)
    declareApp(rig.folder.appendingPathComponent("api"), command: "npm run serve", ports: [freePort()], reuse: false)
    rig.browser.previewWebApp()
    check(await waitUntil { if case .choose = rig.sessions.first?.preview { return true } else { return false } }, "several apps in the project are offered for choice")
    if case .choose(let targets) = rig.sessions.first?.preview {
        check(Set(targets.map(\.label)) == ["web", "api"], "each by its folder")
    }
    rig.browser.previewWebApp()
    check(rig.sessions.count == 1 && rig.tabs.activeTabIndex == 0, "a second Preview Web App reuses the one preview tab")

    // One app, its port taken by another process: the tab says so and starts nothing.
    let taken = listen()
    defer { taken.stop() }
    let busy = Rig()
    declareApp(busy.folder, command: "npm run dev", ports: [taken.port], reuse: false)
    busy.browser.previewWebApp()
    check(await waitUntil { if case .portInUse(_, let port)? = busy.sessions.first?.preview { return port == taken.port } else { return false } },
          "an app whose port another process holds is not started (port in use)")
    check(busy.window.terminals.isEmpty, "and no terminal is opened")

    // One app, its port free: the dev server starts in a terminal tab and its address is awaited.
    let port = freePort()
    let rig2 = Rig()
    declareApp(rig2.folder, command: "npm run dev", ports: [port], reuse: false)
    rig2.browser.previewWebApp()
    check(await waitUntil { rig2.window.terminals.first?.onOutput != nil }, "the dev server starts in a terminal tab of the project")
    let terminal = rig2.window.terminals.first
    check(terminal?.startupCommand == "npm run dev" && terminal?.directory == rig2.folder && terminal?.started == 1, "with its command, started at once")
    let session = rig2.sessions.first
    check(session?.previewTerminalID == terminal?.id, "the tab remembers which terminal runs its server")
    if case .starting(_, started: true)? = session?.preview { check(true, "and shows that it is waiting for the server") } else { check(false, "and shows that it is waiting for the server") }
    rig2.browser.browserSessionShowTerminal(session!)
    check(rig2.tabs.activeTabIndex == 1, "Show Terminal brings the dev server's tab forward")

    // The server prints its address and answers: the tab shows it.
    let server = listen()
    defer { server.stop() }
    terminal?.onOutput?(Data("  Local:   http://localhost:\(server.port)/\n".utf8))
    check(await waitUntil(8) { session?.previews.isEmpty == false }, "the tab shows the address the server printed, once it answers")
    check(session?.previews.first?.port == server.port && terminal?.onOutput == nil, "and the terminal is no longer read")

    // The window closes while the server is awaited: the wait ends with it.
    let closing = Rig()
    let closingPort = freePort()
    declareApp(closing.folder, command: "npm run dev", ports: [closingPort], reuse: false)
    closing.browser.previewWebApp()
    check(await waitUntil { closing.window.terminals.first?.onOutput != nil }, "a second window waits for its dev server")
    closing.browser.close()
    check(await waitUntil(3) { closing.window.terminals.first?.onOutput == nil }, "closing the window ends the wait (the terminal is no longer read)")
    if case .starting? = closing.sessions.first?.preview { check(true, "and the tab is not left claiming a timeout") } else { check(false, "and the tab is not left claiming a timeout") }

    // A terminal remembered for the same app is reused rather than started again.
    let reuse = Rig()
    let reusePort = freePort()
    declareApp(reuse.folder, command: "npm run dev", ports: [reusePort], reuse: true)
    let existing = TerminalSession(directory: reuse.folder, startupCommand: "npm run dev")
    reuse.terminals.rememberPreviewTerminal(existing, forApp: reuse.folder.standardizedFileURL.path)
    reuse.browser.previewWebApp()
    check(await waitUntil { existing.onOutput != nil }, "a dev server the window already runs for the app is watched again")
    check(reuse.window.terminals.isEmpty && existing.started == 0, "and no second one is started")
    reuse.browser.close()
}

@MainActor
func newWindows() {
    print("-- links that ask for a new window")
    // A picked element writes to the person's clipboard, so only the path that does not is checked here.
    let rig = Rig()
    let session = rig.browser.open(nil)
    rig.browser.browserSession(session, openInNewTab: URL(string: "https://example.com/new")!)
    check(rig.sessions.count == 2 && rig.sessions[1].url?.absoluteString == "https://example.com/new" && rig.tabs.activeTabIndex == 1,
          "a link that asks for a new window opens in a new tab")
}

@main
@MainActor
enum BrowserHostChecks {
    static func main() async {
        tabs()
        await pagesOpenedByOthers()
        localHTML()
        await control()
        await preview()
        newWindows()
        for folder in temporaryFolders { try? FileManager.default.removeItem(at: folder) }
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(defaultsSuite).plist"))
        print("Browser host summary: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
