import AppKit
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What the browser of a window needs of the window beyond its tabs, panels and project (`AR-14` step 9): the workspace and the stores
/// the control tools act on, and a terminal tab for a dev server. `WorkspaceManager` conforms. The stores are read when an agent asks, so
/// a store a window has not needed yet is not made for the browser.
@MainActor
protocol BrowserHostWindow: AnyObject {
    /// The window's workspace, for the control tools (`ControlToolRunner`); the control server lists windows by it.
    var controlWorkspace: WorkspaceManager { get }
    /// The project's feature workspaces, deployments and discussions that the control tools read and write.
    var controlFeatures: FeatureStore { get }
    var controlDeployments: DeploymentStore { get }
    var controlDiscussions: DiscussionStore { get }
    /// Open a terminal in `folder` as an editor tab; `startupCommand` is typed once the shell is up.
    @discardableResult
    func openTerminal(in folder: URL, startupCommand: String?, title: String?, activate: Bool) -> TerminalSession
}

/// The terminals Preview Web App and a picked element reach: the AI terminal that takes the element, and the dev server a preview
/// started, found again for the same app. `AITerminalsController` conforms.
@MainActor
protocol DevServerTerminals: AnyObject {
    /// The terminal the AI panel shows.
    var shown: TerminalSession? { get }
    func previewTerminal(forApp folderPath: String) -> TerminalSession?
    func rememberPreviewTerminal(_ session: TerminalSession, forApp folderPath: String)
}

/// The browser of one window (`AR-14` step 9): its browser tabs, what agents may drive of them (`BrowserAgentTabs`), the pages
/// local HTML files and terminal programs open, Preview Web App with its dev server, and the picked page element that goes to the AI.
/// The tabs are `BrowserSession`s; each reaches its window through `BrowserSessionHost`, which this object is. Background work (the
/// look for the web app, the wait for a dev server) is in its own `TaskBag`, cancelled when the window closes (`AR-19`).
@MainActor
final class BrowserHost: BrowserSessionHost {
    /// This window's id for agents driving its browser tab (`AgentToolServer`).
    let controlID = UUID()

    private let tabs: TabsController
    private let layout: PanelLayout
    private let chrome: WindowChrome
    private let project: any ProjectProviding
    private let terminals: any DevServerTerminals
    private weak var window: (any BrowserHostWindow)?
    /// What the window's pages ask the person with (`alert`, `confirm`), given to each browser tab (`AR-22`).
    private let prompts: any UserPrompts
    private let tasks = TaskBag()

    init(tabs: TabsController, layout: PanelLayout, chrome: WindowChrome, project: any ProjectProviding, terminals: any DevServerTerminals,
         window: any BrowserHostWindow, prompts: any UserPrompts) {
        self.prompts = prompts
        self.tabs = tabs
        self.layout = layout
        self.chrome = chrome
        self.project = project
        self.terminals = terminals
        self.window = window
    }

    /// The window closes: the look for a web app and the wait for a dev server stop.
    func close() {
        tasks.cancelAll()
    }

    // MARK: - Control by agents

    /// Offer this window to agents (`AgentToolServer`): its browser tabs, its project's features, and the
    /// workspace itself for the control tools. Called when the window is shown, a folder opens or a terminal starts.
    func register() {
        let browser = BrowserAgentTabs(
            tabs: { [weak self] in self?.sessions ?? [] },
            active: { [weak self] in
                guard let self, self.tabs.openTabs.indices.contains(self.tabs.activeTabIndex),
                      case .browser(let session) = self.tabs.openTabs[self.tabs.activeTabIndex].kind else { return nil }
                return session
            },
            show: { [weak self] session in self?.show(session) },
            open: { [weak self] url, name in
                guard let self else { return BrowserSession(url: url, prompts: NoPrompts()) }
                let session = self.open(url)
                if let name { session.agentName = name }
                return session
            })
        AgentToolServer.register(controlID, .init(
            workspace: { [weak self] in self?.window?.controlWorkspace },
            root: { [weak self] in self?.project.root },
            features: { [weak self] in self?.window?.controlFeatures },
            deployments: { [weak self] in self?.window?.controlDeployments },
            discussions: { [weak self] in self?.window?.controlDiscussions },
            browser: { tool, args in await browser.run(tool, args) }))
    }

    /// The window's browser tabs, in tab order.
    var sessions: [BrowserSession] {
        tabs.openTabs.compactMap { if case .browser(let session) = $0.kind { return session }; return nil }
    }

    /// Bring a browser tab to the front.
    func show(_ session: BrowserSession) {
        guard let index = tabs.openTabs.firstIndex(where: { if case .browser(let s) = $0.kind { return s === session }; return false }) else { return }
        layout.workspaceArea = .files
        chrome.showCenter = true
        tabs.activeTabIndex = index
    }

    // MARK: - Tabs

    /// Open a browser tab (an empty one for nil), next to the files.
    @discardableResult
    func open(_ url: URL?, activate: Bool = true) -> BrowserSession {
        let session = BrowserSession(url: url, host: self, prompts: prompts)
        session.agentName = BrowserAgentTools.nextTabName(taken: sessions.map(\.agentName))
        let base = project.root ?? FileManager.default.temporaryDirectory
        var tab = OpenTab(url: base.appendingPathComponent(ProjectPaths.placeholderName("browser-" + session.id.uuidString)),
                          content: "", originalContent: "")
        tab.kind = .browser(session)
        if activate {
            layout.workspaceArea = .files
            chrome.showCenter = true
        }
        tabs.appendTab(tab, activate: activate)
        return session
    }

    /// Show a local HTML file in a browser tab: the tab already showing it is reloaded, else a new
    /// one opens. The page may read the project's files, so relative stylesheets and scripts load.
    func openHTML(_ file: URL) {
        let file = file.standardizedFileURL
        guard FileType.isHTML(file), FileManager.default.fileExists(atPath: file.path) else { return }
        layout.workspaceArea = .files
        chrome.showCenter = true
        for index in tabs.openTabs.indices {
            if case .browser(let session) = tabs.openTabs[index].kind, session.url?.standardizedFileURL == file {
                tabs.activeTabIndex = index
                session.load(file)
                return
            }
        }
        let session = open(nil)
        session.localReadRoot = project.containerRoot(for: file)
        session.load(file)
    }

    /// A page a terminal program opened: shown in this window's browser, reusing a tab rather than
    /// adding one — the tab already on the same server, else the active, preview or first browser tab.
    func openInAppBrowser(_ url: URL) {
        let candidates: [(index: Int, session: BrowserSession)] = tabs.openTabs.indices.compactMap { index in
            if case .browser(let session) = tabs.openTabs[index].kind { return (index, session) }
            return nil
        }
        let sameServer = { (session: BrowserSession) in
            session.url?.host == url.host && session.url?.port == url.port && session.url?.scheme == url.scheme
        }
        let chosen = candidates.first { sameServer($0.session) }
            ?? candidates.first { $0.index == tabs.activeTabIndex }
            ?? candidates.first { $0.session.isAppPreview }
            ?? candidates.first
        layout.workspaceArea = .files
        chrome.showCenter = true
        if let chosen {
            tabs.activeTabIndex = chosen.index
            chosen.session.load(url)
        } else {
            open(url)
        }
    }

    // MARK: - Picked element

    /// A picked page element goes into the AI terminal's input line as text (page, selector,
    /// screenshot path, HTML) and, for pasting by hand, onto the clipboard as image plus text.
    func browserSession(_ session: BrowserSession, picked element: PickedElement, screenshot: URL?) {
        let message = BrowserElementPick.message(for: element, screenshot: screenshot)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let screenshot, let image = NSImage(contentsOf: screenshot) { pasteboard.writeObjects([image]) }
        pasteboard.setString(message, forType: .string)
        let shot = screenshot == nil ? " (no screenshot: the element is off screen)" : ""
        if let terminal = terminals.shown {
            terminal.paste(message + "\n")
            session.pickNotice = "Sent \(element.tag) to the AI input\(shot)"
        } else {
            session.pickNotice = "No AI terminal is open — \(element.tag) is on the clipboard\(shot)"
        }
    }

    func browserSession(_ session: BrowserSession, openInNewTab url: URL) {
        open(url)
    }

    // MARK: - Preview Web App

    /// Preview Web App: the project's web app in a browser tab. A development server that
    /// already answers is shown at once; otherwise the app's dev script runs in a terminal
    /// tab and the tab shows the server as soon as it prints its address or a port answers.
    func previewWebApp() {
        if let index = tabs.openTabs.firstIndex(where: { tab in
            if case .browser(let session) = tab.kind { return session.isAppPreview }
            return false
        }), case .browser(let session) = tabs.openTabs[index].kind {
            // One preview tab per window: bring it back and look again.
            tabs.activeTabIndex = index
            layout.workspaceArea = .files
            chrome.showCenter = true
            findWebApp(for: session)
            return
        }
        let session = open(nil)
        findWebApp(for: session)
    }

    private func findWebApp(for session: BrowserSession) {
        session.isAppPreview = true
        session.preview = .searching
        guard let root = project.root else {
            session.preview = .noApp
            return
        }
        tasks.store(Task { [weak self] in
            let targets = await Self.webAppTargets(in: root)
            guard let self, !Task.isCancelled else { return }
            switch targets.count {
            case 0:
                if let url = await WebAppPreview.firstAnswering(WebAppPreview.commonPorts) {
                    session.showPreview(url)
                } else {
                    session.preview = .noApp
                }
            case 1:
                self.browserSession(session, startWebApp: targets[0])
            default:
                session.preview = .choose(targets)
            }
        }, for: "findWebApp:" + session.id.uuidString)
    }

    /// The web apps in a project, found on the disk off the main actor.
    private nonisolated static func webAppTargets(in root: URL) async -> [WebAppTarget] {
        WebAppPreview.targets(root: root)
    }

    /// Show `target` in `session`: at once when its server answers, else after starting it.
    func browserSession(_ session: BrowserSession, startWebApp target: WebAppTarget) {
        session.preview = .starting(target, started: false)
        if target.isElectron { session.standInForElectron() }
        tasks.store(Task { [weak self] in
            guard let self else { return }
            if !target.reuseRunningServer, let occupied = await WebAppPreview.firstListening(target.ports) {
                session.preview = .portInUse(target, occupied.port ?? 0)
                return
            }
            if target.reuseRunningServer, let url = await WebAppPreview.firstAnswering(target.ports) {
                session.showPreview(url)
                return
            }
            let key = target.folder.standardizedFileURL.path
            let terminal: TerminalSession
            if target.reuseRunningServer, let existing = self.terminals.previewTerminal(forApp: key) {
                terminal = existing
            } else {
                guard let window = self.window else { return }
                terminal = window.openTerminal(in: target.folder, startupCommand: target.command, title: "Dev server", activate: false)
                if target.reuseRunningServer { self.terminals.rememberPreviewTerminal(terminal, forApp: key) }
                // A terminal tab starts its shell when its page is shown; this one starts now and
                // keeps the output until the tab is opened.
                terminal.start()
            }
            session.previewTerminalID = terminal.id
            session.preview = .starting(target, started: true)
            let watch = DevServerWatch()
            terminal.onOutput = { [weak watch] data in watch?.read(data) }
            defer { terminal.onOutput = nil }
            let deadline = Date().addingTimeInterval(180)
            var round = 0
            while Date() < deadline {
                guard !session.isClosed, !Task.isCancelled, case .starting = session.preview else { return }
                if let url = watch.url, await WebAppPreview.firstAnswering([url.port ?? 80], timeout: 1) != nil {
                    session.showPreview(url)
                    return
                }
                if round % 3 == 0, let url = await WebAppPreview.firstAnswering(target.ports) {
                    session.showPreview(url)
                    return
                }
                round += 1
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            if case .starting = session.preview { session.preview = .timedOut(target) }
        }, for: "startWebApp:" + session.id.uuidString)
    }

    func browserSessionShowTerminal(_ session: BrowserSession) {
        guard let id = session.previewTerminalID,
              let index = tabs.openTabs.firstIndex(where: { tab in
                  if case .terminal(let terminal) = tab.kind { return terminal == id }
                  return false
              }) else { return }
        tabs.activeTabIndex = index
    }
}
