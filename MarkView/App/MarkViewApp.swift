import SwiftUI
import UniformTypeIdentifiers
import os
#if canImport(MarkViewCore)
import MarkViewCore
#endif

// MARK: - Custom UTType for Markdown
extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

// MARK: - Custom NSApplication subclass
// Captures open-document Apple Events BEFORE SwiftUI can intercept them.
// Set as NSPrincipalClass in Info.plist.
class MarkViewApplication: NSApplication {
    /// URLs received via Apple Events before any UI is ready
    static var launchURLs: [URL] = []
    private static func debugLog(_ msg: String) {
        AppLog.app.debug("[NSApp] \(msg)")
    }

    override init() {
        super.init()
        Self.debugLog("MarkViewApplication init — registering Apple Event handler")
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc private func handleOpenDocumentsEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        Self.debugLog("handleOpenDocumentsEvent fired")
        guard let docList = event.paramDescriptor(forKeyword: keyDirectObject) else {
            Self.debugLog("  no keyDirectObject")
            return
        }
        for i in 1...docList.numberOfItems {
            guard let desc = docList.atIndex(i) else { continue }
            if let fileURLDesc = desc.coerce(toDescriptorType: typeFileURL) {
                let data = fileURLDesc.data
                if let urlString = String(data: data, encoding: .utf8),
                   let url = URL(string: urlString) {
                    Self.launchURLs.append(url)
                    Self.debugLog("  captured URL: \(url.path)")
                }
            } else if let pathDesc = desc.coerce(toDescriptorType: typeUTF8Text),
                      let path = pathDesc.stringValue {
                Self.launchURLs.append(URL(fileURLWithPath: path))
                Self.debugLog("  captured path: \(path)")
            }
        }
        Self.debugLog("  total captured: \(Self.launchURLs.count)")
    }
}

final class MarkViewAppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)?

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // task: the quit itself: it answers `.terminateLater` and replies when the stores have saved; nothing may cancel it
        Task { @MainActor in
            guard await ProjectOperationsStore.stopAllBeforeQuit(prompts: AlertPrompts()) else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            await RemoteRelaySettings.finishBeforeQuit()
            await RemoteConnectionsStore.shared.finishPendingChanges()
            // The window session is saved on a best-effort basis: an unwritable file never cancels the quit.
            await WindowSessionController.shared.saveBeforeTermination()
            await CockpitAgentRegistry.cancelAllAndWait(reason: "MarkView is closing.")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Quitting for real (not when the user keeps a running project operation): stop the assistants of headless runs
    /// so none keeps working, and spending tokens, for a window that is gone.
    func applicationWillTerminate(_ notification: Notification) {
        AgentToolServer.shutdown()
        RemoteConnectionsStore.shared.suspend()
        CockpitAgentRegistry.cancelAll(reason: "MarkView is closing.")
        AgentProcesses.terminateAll()
    }


    func log(_ msg: String) {
        AppLog.appDelegate.debug("[AppDelegate] \(msg)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching")
        // Migrate legacy agent-wide MCP switches into per-service selections and agent configs once at startup (DEC-004).
        DispatchQueue.global(qos: .utility).async {
            AgentMCPServices.migrateAllIfNeeded()
        }
        // Listen for agents from the start, not when the first folder opens: an agent that drives the app opens it.
        _ = AgentToolServer.socketPath
        // One app-wide poll for Finder Quick Action requests (`AR-19`): started with the app, so a request is taken with or without a
        // window; `enqueueOpen` holds it until a window shows it.
        FinderOpenRequests.shared.start { MarkViewApp.enqueueOpen($0) }
        ensureWindowExists()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureWindowExists()
    }

    private func ensureWindowExists() {
        // task: one-shot check 0.3 s after launch that a window exists; touches only NSApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let visibleWindows = NSApp.windows.filter { ($0.isVisible || $0.isMiniaturized) && !$0.className.contains("Panel") }
            if visibleWindows.isEmpty {
                AppLog.appDelegate.debug("[AppDelegate] No visible windows — creating one")
                // SwiftUI's built-in new window action
                NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        log("application:open: \(urls.count) URLs")
        for url in urls {
            log("  URL: \(url.path)")
        }
        MarkViewApp.enqueueOpen(urls)
    }
}

// MARK: - Process Entry Point
//
// The structural indexer runs out-of-process (re-exec of this same binary with
// `--dde-index <folder>`) so heavy directory scanning never competes with the UI.
// This entry point intercepts that flag BEFORE any SwiftUI / NSApplication setup;
// for a normal launch it falls through to SwiftUI's synthesized `MarkViewApp.main()`.
@main
enum DDEAppEntry {
    static func main() {
        #if MARKVIEW_HOSTED_TEST_HOST
        // The hosted fixture may run CLI entry points in a child process, without starting the app.
        if CommandLine.arguments.contains("--mcp-browser") {
            BrowserAgentTools.runServer(arguments: CommandLine.arguments)
        }
        if CommandLine.arguments.contains("--mcp-project") {
            BrowserAgentTools.runServer(arguments: CommandLine.arguments, profile: ProjectAgentTools.profile)
        }
        if CommandLine.arguments.contains("--project-call") {
            ProjectAgentTools.runCall(arguments: CommandLine.arguments)
        }
        if CommandLine.arguments.contains("--mcp-control") {
            BrowserAgentTools.runServer(arguments: CommandLine.arguments, profile: ControlAgentTools.profile)
        }
        // The dedicated test build never starts windows, sockets or user session restoration.
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
        #else
        let args = CommandLine.arguments
        if args.contains("--remote-workspace-mcp") { RemoteUnixRPC.runMCP(arguments: args) }
        if args.contains("--remote-workspace-guard") { RemoteUnixRPC.runGuard() }
        if args.contains("--mcp-browser") {
            BrowserAgentTools.runServer(arguments: args)  // never returns
        }
        if args.contains("--mcp-project") {
            BrowserAgentTools.runServer(arguments: args, profile: ProjectAgentTools.profile)  // never returns
        }
        if args.contains("--mcp-control") {
            BrowserAgentTools.runServer(arguments: args, profile: ControlAgentTools.profile)  // never returns
        }
        if args.contains("--project-call") {
            ProjectAgentTools.runCall(arguments: args)  // never returns
        }
        if let i = args.firstIndex(of: "--dde-index"), i + 1 < args.count {
            DDEIndexerRunner.run(folderPath: args[i + 1])  // never returns
        }
        MarkViewApp.main()
        #endif
    }
}

/// Headless structural-index runner for the `--dde-index` child process.
/// Opens the workspace database, runs `StructuralIndexer.indexAll()`, and exits.
/// `dispatchMain()` keeps the process alive while the indexing task runs.
enum DDEIndexerRunner {
    private static func err(_ msg: String) {
        FileHandle.standardError.write(Data("[mvindexer] \(msg)\n".utf8))
    }

    static func run(folderPath: String) -> Never {
        let url = URL(fileURLWithPath: folderPath)
        err("start \(folderPath)")
        // task: the child process is this task: it ends the process with exit(), and nothing in a headless run can cancel it
        Task {
            do {
                let db = try await SemanticDatabase.open(workspacePath: url)
                // A file the app must leave alone (newer schema, failed migration) gives an in-memory index: nothing to write.
                guard db.dbPath != nil else { err("the index file is left untouched; nothing to index"); exit(1) }
                try await db.ensureProject(id: url.lastPathComponent, name: url.lastPathComponent, rootPath: url.path)
                let linked = LinkedFolders.load(project: url)
                if !linked.isEmpty { err("linked folders: " + linked.map(\.name).joined(separator: ", ")) }
                let indexer = StructuralIndexer(db: db, rootURL: url, linkedFolders: linked, progress: { msg in err(msg) })
                await indexer.indexAll()
                err("done")
                exit(0)
            } catch {
                err("error: \(error)")
                exit(1)
            }
        }
        dispatchMain()  // never returns; the indexing task above runs while the main queue idles
    }
}

struct MarkViewApp: App {
    @NSApplicationDelegateAdaptor(MarkViewAppDelegate.self) private var appDelegate
    @FocusedValue(\.workspaceManager) private var activeWorkspace
    @FocusedValue(\.workspaceHasFolder) private var activeWorkspaceHasFolder
    /// The layout presets of View > Layout (`AR-33`).
    @ObservedObject private var layouts = LayoutCatalog.shared

    /// Marketing version from Info.plist, shown in each workspace window's title (ContentView).
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    init() {
        _ = RemoteConnectionsStore.shared
    }

    var body: some Scene {
        Self.debugLogStatic("MarkViewApp body evaluated")
        return WindowGroup(id: WindowSessionController.sceneID, for: UUID.self) { id in
            ContentView(windowSessionID: id.wrappedValue)
                .appFontScaled()
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    appDelegate.log("ContentView onAppear START")
                    // Handle files/folders opened via Finder Services
                    appDelegate.onOpenURLs = { urls in
                        appDelegate.log("onOpenURLs callback fired with \(urls.count) URLs")
                        Self.enqueueOpen(urls)
                    }

                    appDelegate.log("ContentView onAppear: handler set")
                }
        } defaultValue: {
            UUID()
        }
        .commands {
            // MARK: - File Menu
            CommandGroup(after: .newItem) {
                Button("Open File...") {
                    openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open Folder...") {
                    NotificationCenter.default.post(name: .showFolderPicker, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("New Project…") {
                    // A window without a folder takes it; otherwise a new window does.
                    if let workspace = activeWorkspace, activeWorkspaceHasFolder != true {
                        workspace.requests.newProject = NewProjectRequest()
                    } else {
                        Self.pendingNewProject = true
                        newWindow()
                    }
                }

                Button("Publish to GitHub…") {
                    activeWorkspace?.requests.gitHubPublishRequested = true
                }
                .disabled(activeWorkspaceHasFolder != true)

                Button("Close Folder") {
                    activeWorkspace?.closeFolder()
                }
                .disabled(activeWorkspaceHasFolder != true)

                Divider()

                Button("Link Folder…") {
                    activeWorkspace?.project.chooseFoldersToLink()
                }
                .disabled(activeWorkspaceHasFolder != true)

                Divider()

                Button("Recreate Metadata…") {
                    activeWorkspace?.removeMetadata(recreate: true)
                }
                .disabled(activeWorkspaceHasFolder != true)

                Button("Remove Metadata…") {
                    activeWorkspace?.removeMetadata(recreate: false)
                }
                .disabled(activeWorkspaceHasFolder != true)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    activeWorkspace?.tabs.saveActiveFile()
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            CommandGroup(after: .saveItem) {
                Button("Export PDF Book…") { activeWorkspace?.presentPDFBook() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(activeWorkspace == nil)
                Button("Export PDF...") {
                    exportPDF()
                }
                .keyboardShortcut("e", modifiers: .command)
            }

            // MARK: - View Menu
            CommandGroup(after: .toolbar) {
                Divider()

                Button("Search Project…") {
                    activeWorkspace?.chrome.showGlobalSearch = true
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Theme…") {
                    activeWorkspace?.theme.showsPicker = true
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Toggle File Tree") {
                    activeWorkspace?.chrome.toggleNavigation()
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Toggle Right Panel") {
                    activeWorkspace?.chrome.toggleRightPanel()
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Agents") {
                    activeWorkspace?.toggleAIConsole()
                }
                .keyboardShortcut("3", modifiers: [.command])

                toolMenuItems(.afterAgents)

                Button("X-Ray") {
                    activeWorkspace?.codeXRay.openArchitecture()
                }
                .keyboardShortcut("4", modifiers: [.command])
                .disabled(activeWorkspaceHasFolder != true)

                Button("Browser") {
                    activeWorkspace?.browser.open(nil)
                }
                .keyboardShortcut("5", modifiers: [.command])

                Button("Preview Web App") {
                    activeWorkspace?.browser.previewWebApp()
                }
                .keyboardShortcut("6", modifiers: [.command])
                .disabled(activeWorkspaceHasFolder != true)

                toolMenuItems(.afterWebPreview)

                Divider()

                Menu("Layout") {
                    LayoutMenuItems(library: layouts.library, enabled: activeWorkspaceHasFolder == true,
                                    apply: { activeWorkspace?.applyLayoutPreset($0) }, reload: { layouts.startReload() })
                }
            }

            CommandGroup(after: .appSettings) {
                Button("DDE Settings...") {
                    DDESettingsWindow.show(workspace: activeWorkspace)
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            }
        }
    }

    /// The View menu items of the tools registered for `slot` (`ToolRegistry`), in the registry's order.
    @ViewBuilder
    private func toolMenuItems(_ slot: ToolMenuSlot) -> some View {
        ForEach(ToolRegistry.shared.menuTools(slot)) { tool in
            Button(tool.title) {
                activeWorkspace?.openTool(tool.id)
            }
            .keyboardShortcut(tool.shortcut?.keyboardShortcut)
            .disabled(tool.menu?.requiresFolder == true && activeWorkspaceHasFolder != true)
        }
    }

    // MARK: - File Actions

    /// Check if Finder Quick Action wrote a path for us to open
    private static func debugLogStatic(_ msg: String) {
        AppLog.finder.debug("[Static] \(msg)")
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { [weak activeWorkspace] response in
            if response == .OK, let url = panel.url {
                activeWorkspace?.openFile(url)
            }
        }
    }

    /// Pending folder URL for new window to pick up
    static var pendingFolderURL: URL?
    /// File › New Project… asked for a new window: it shows the new-project sheet on appearing.
    static var pendingNewProject = false
    /// Files/folders requested from outside (Finder "Open With", Quick Action)
    /// that no window has taken yet. Durable until drained, so a request that
    /// arrives before any window is ready is never lost.
    static var pendingOpenURLs: [URL] = []

    /// Queue external open requests and signal windows to drain the queue.
    /// The active window's ContentView takes them (see `drainPendingOpens`).
    static func enqueueOpen(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingOpenURLs.append(contentsOf: urls)
        debugLogStatic("enqueueOpen: \(urls.map(\.path)) (queue=\(pendingOpenURLs.count))")
        NotificationCenter.default.post(name: .openInActiveWindow, object: nil)
    }

    private func newWindow() {
        // Use SwiftUI's built-in new window action (we kept .newItem intact)
        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
    }

    private func openFolder() {
        let ws = activeWorkspace
        let keyWindow = NSApp.keyWindow

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder to open in MarkView"

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let currentIsEmpty = ws?.rootNode == nil && ws?.tabs.openTabs.isEmpty != false
            if currentIsEmpty, let ws = ws {
                ws.openFolder(url)
            } else {
                Self.pendingFolderURL = url
                self.newWindow()
                // task: one-shot 1 s fallback of the Finder open hand-off; it only reads and clears a static, and the window is not its owner
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if Self.pendingFolderURL != nil {
                        Self.pendingFolderURL = nil
                        ws?.openFolder(url)
                    }
                }
            }
        }

        // Show as sheet on current window to prevent window from closing
        if let keyWindow = keyWindow {
            panel.beginSheetModal(for: keyWindow, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    private func exportPDF() {
        guard let activeWorkspace else { return }
        NotificationCenter.default.post(.exportPDFRequested, for: activeWorkspace)
    }
}

/// The single DDE Settings window, opened from the menu and from places that point to a fix
/// there (a dictation field whose OpenAI key or model failed). It shows the settings of the
/// window that opened it: the assistant choice there is that window's project's (BUG-022).
@MainActor
enum DDESettingsWindow {
    private static var window: NSWindow?
    /// The workspace whose settings the window shows.
    private static weak var shownWorkspace: WorkspaceManager?

    static func show(workspace: WorkspaceManager?) {
        let window = self.window ?? makeWindow()
        if let workspace, workspace !== shownWorkspace {
            bind(window, to: workspace)
        } else if shownWorkspace == nil {
            // No window has focus (the menu with only the Settings window open): no project.
            bind(window, to: WorkspaceManager(prompts: AlertPrompts()))
        }
        window.title = shownWorkspace?.projectFolder.map { "DDE Settings — \($0.lastPathComponent)" } ?? "DDE Settings"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func makeWindow() -> NSWindow {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 900)
        let size = NSSize(width: min(640, screen.width - 40), height: min(740, screen.height - 60))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: min(600, size.width), height: min(440, size.height))
        window.center()
        self.window = window
        return window
    }

    /// Show `workspace`'s settings: opened from another window, the content is rebuilt for it.
    private static func bind(_ window: NSWindow, to workspace: WorkspaceManager) {
        shownWorkspace?.theme.detach(window)
        shownWorkspace = workspace
        let size = window.contentLayoutRect.size
        let hosting = NSHostingView(
            rootView: DDESettingsView(terminals: workspace.terminals)
                .environmentObject(workspace)
                .environmentObject(workspace.windowUI)
                .observingParts(of: workspace)
                .appFontScaled()
                .windowThemed(workspace.theme)
        )
        workspace.theme.attach(window)
        // The window owns its dimensions; the scroll view follows the available viewport.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(size)
    }
}

// MARK: - Notifications for one window

extension NotificationCenter {
    /// Posts a notification that is for one window only: every window's observers hear it, and the ones of other windows ignore it
    /// (`Notification.isFor`). A scroll, a reveal or an export started in one window must not move another window.
    func post(_ name: Notification.Name, for workspace: any WindowCommands, object: Any? = nil, userInfo: [AnyHashable: Any] = [:]) {
        var info = userInfo
        info[Notification.workspaceKey] = ObjectIdentifier(workspace)
        post(name: name, object: object, userInfo: info)
    }
}

extension Notification {
    static let workspaceKey = "workspace"

    /// True when this notification was posted for `workspace`'s window. One posted for no window is for none.
    func isFor(_ workspace: any WindowCommands) -> Bool {
        (userInfo?[Self.workspaceKey] as? ObjectIdentifier) == ObjectIdentifier(workspace)
    }
}

// MARK: - Tool shortcuts
extension ToolShortcut {
    /// The SwiftUI shortcut of the registry's plain-data shortcut.
    var keyboardShortcut: KeyboardShortcut {
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: flags)
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let exportPDFRequested = Notification.Name("exportPDFRequested")
    static let openInActiveWindow = Notification.Name("openInActiveWindow")
    static let showFolderPicker = Notification.Name("showFolderPicker")
    static let performPDFExport = Notification.Name("PerformPDFExport")
    static let scrollToHeading = Notification.Name("ScrollToHeading")
    static let scrollToText = Notification.Name("ScrollToText")
    /// userInfo: "url" (URL), "line" (Int), optional "endLine" (Int).
    static let revealCodeLine = Notification.Name("RevealCodeLine")
    /// The Contents panel picked a key of a JSON / YAML file (`url`, `path` JSON, `line`).
    static let revealStructure = Notification.Name("RevealStructure")
}

// MARK: - Markdown Document Type
struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownText, .plainText] }

    var text: String = ""

    init() {}

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(decoding: data, as: UTF8.self)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = Data(text.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}
