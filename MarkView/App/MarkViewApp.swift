import SwiftUI
import UniformTypeIdentifiers

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
        let line = "\(ISO8601DateFormatter().string(from: Date())) [NSApp] \(msg)\n"
        let path = NSHomeDirectory() + "/markview_debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
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

    func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [AppDelegate] \(msg)\n"
        let path = NSHomeDirectory() + "/markview_debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching")
        ensureWindowExists()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureWindowExists()
    }

    private func ensureWindowExists() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let visibleWindows = NSApp.windows.filter { $0.isVisible && !$0.className.contains("Panel") }
            if visibleWindows.isEmpty {
                self.log("No visible windows — creating one")
                // Try SwiftUI's built-in new window action
                if NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil) {
                    return
                }
                // Fallback: use File > New Window menu item
                NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        log("application:open: \(urls.count) URLs")
        for url in urls {
            log("  URL: \(url.path)")
        }
        // Save URL for the new window's onAppear to pick up
        if let url = urls.first {
            MarkViewApp.pendingOpenURL = url
            log("  saved as pendingOpenURL")
        }
    }
}

@main
struct MarkViewApp: App {
    @NSApplicationDelegateAdaptor(MarkViewAppDelegate.self) private var appDelegate
    @StateObject private var themeManager = ThemeManager()
    @FocusedValue(\.workspaceManager) private var activeWorkspace
    @State private var ddeSettingsWindow: NSWindow?

    /// Build timestamp for debugging — visible in window title
    static let buildID = "\(Int(Date().timeIntervalSince1970) % 100000)"

    init() {
    }

    var body: some Scene {
        Self.debugLogStatic("MarkViewApp body evaluated")
        return WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                .frame(minWidth: 900, minHeight: 600)
                .navigationTitle("MarkView [\(Self.buildID)]")
                .onAppear {
                    appDelegate.log("ContentView onAppear START")
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    for window in NSApp.windows {
                        window.appearance = NSAppearance(named: .darkAqua)
                        if window.frameAutosaveName.isEmpty {
                            window.setContentSize(NSSize(width: 1200, height: 800))
                            window.center()
                        }
                    }
                    // Handle files/folders opened via Finder Services
                    appDelegate.onOpenURLs = { [self] urls in
                        appDelegate.log("onOpenURLs callback fired with \(urls.count) URLs")
                        for url in urls {
                            let id = UUID()
                            appDelegate.log("  posting openInActiveWindow for: \(url.path) id=\(id)")
                            NotificationCenter.default.post(name: .openInActiveWindow, object: ["url": url, "id": id] as [String: Any])
                        }
                    }

                    appDelegate.log("ContentView onAppear: handler set, starting timer")
                    // Poll for Finder Quick Action requests
                    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                        Self.checkFinderOpenRequest { urls in
                            for url in urls {
                                NotificationCenter.default.post(name: .openInActiveWindow, object: ["url": url, "id": UUID()] as [String: Any])
                            }
                        }
                    }
                }
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
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    activeWorkspace?.saveActiveFile()
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            CommandGroup(after: .saveItem) {
                Button("Export PDF...") {
                    exportPDF()
                }
                .keyboardShortcut("e", modifiers: .command)
            }

            // MARK: - View Menu
            CommandGroup(after: .toolbar) {
                Divider()

                Button("Toggle Theme") {
                    themeManager.toggleTheme()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Toggle File Tree") {
                    activeWorkspace?.showFileTree.toggle()
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Toggle Table of Contents") {
                    activeWorkspace?.showTOC.toggle()
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Toggle Semantic Panel") {
                    activeWorkspace?.showSemanticPanel.toggle()
                }
                .keyboardShortcut("3", modifiers: [.command])
            }

            CommandGroup(after: .appSettings) {
                Button("DDE Settings...") {
                    openDDESettings()
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            }
        }
    }

    private func openDDESettings() {
        if let ddeSettingsWindow {
            ddeSettingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DDE Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        let wm = activeWorkspace ?? WorkspaceManager()
        window.contentView = NSHostingView(
            rootView: DDESettingsView()
                .environmentObject(wm)
        )
        ddeSettingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - File Actions

    /// Check if Finder Quick Action wrote a path for us to open
    private static func debugLogStatic(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [Static] \(msg)\n"
        let path = NSHomeDirectory() + "/markview_debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func checkFinderOpenRequest(handler: @escaping ([URL]) -> Void) {
        let path = "/tmp/markview_open_path.txt"
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return }

        // Delete immediately so we don't re-process
        try? fm.removeItem(atPath: path)

        let url = URL(fileURLWithPath: content)
        debugLogStatic("checkFinderOpenRequest: found \(content), calling handler")
        handler([url])
        debugLogStatic("checkFinderOpenRequest: handler called, notification posted")
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdownText, .plainText]
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
    /// URL from .onOpenURL — saved for the new window that Finder "Open With" creates
    static var pendingOpenURL: URL?

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
            let currentIsEmpty = ws?.rootNode == nil && ws?.openTabs.isEmpty != false
            if currentIsEmpty, let ws = ws {
                ws.openFolder(url)
            } else {
                Self.pendingFolderURL = url
                self.newWindow()
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
        NotificationCenter.default.post(name: .exportPDFRequested, object: nil)
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let exportPDFRequested = Notification.Name("exportPDFRequested")
    static let themeDidChange = Notification.Name("ThemeDidChange")
    static let openInActiveWindow = Notification.Name("openInActiveWindow")
    static let showFolderPicker = Notification.Name("showFolderPicker")
    static let performPDFExport = Notification.Name("PerformPDFExport")
    static let scrollToHeading = Notification.Name("ScrollToHeading")
    static let scrollToText = Notification.Name("ScrollToText")
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
