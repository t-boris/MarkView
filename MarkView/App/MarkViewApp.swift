import SwiftUI
import UniformTypeIdentifiers

// MARK: - Custom UTType for Markdown
extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

final class MarkViewAppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)? {
        didSet {
            // Deliver any URLs that arrived before the handler was set
            if let handler = onOpenURLs, !pendingURLs.isEmpty {
                handler(pendingURLs)
                pendingURLs.removeAll()
            }
        }
    }
    private var pendingURLs: [URL] = []

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let handler = onOpenURLs {
            handler(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }
}

@main
struct MarkViewApp: App {
    @NSApplicationDelegateAdaptor(MarkViewAppDelegate.self) private var appDelegate
    @StateObject private var themeManager = ThemeManager()
    @FocusedValue(\.workspaceManager) private var activeWorkspace
    @State private var ddeSettingsWindow: NSWindow?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    for window in NSApp.windows {
                        window.appearance = NSAppearance(named: .darkAqua)
                        if window.frameAutosaveName.isEmpty {
                            window.setContentSize(NSSize(width: 1200, height: 800))
                            window.center()
                        }
                    }
                    // Handle files/folders opened via Finder Services
                    appDelegate.onOpenURLs = { urls in
                        // Open in the active window's workspace, or create new
                        for url in urls {
                            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                            // Find the key window's workspace via notification
                            NotificationCenter.default.post(name: .openInActiveWindow, object: url)
                        }
                    }

                    // Poll for Finder Quick Action requests
                    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                        Self.checkFinderOpenRequest { urls in
                            for url in urls {
                                NotificationCenter.default.post(name: .openInActiveWindow, object: url)
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
                    openFolder()
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
    private static func checkFinderOpenRequest(handler: @escaping ([URL]) -> Void) {
        let path = "/tmp/markview_open_path.txt"
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return }

        // Delete immediately so we don't re-process
        try? fm.removeItem(atPath: path)

        let url = URL(fileURLWithPath: content)
        handler([url])
        NSLog("[MarkView] Opened from Finder: \(content)")
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

    private func newWindow() {
        // Use SwiftUI's built-in new window action (we kept .newItem intact)
        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
    }

    private func openFolder() {
        let currentIsEmpty = activeWorkspace?.rootNode == nil && activeWorkspace?.openTabs.isEmpty != false
        let ws = activeWorkspace

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK, let url = panel.url {
            if currentIsEmpty, let ws = ws {
                ws.openFolder(url)
            } else {
                // Open in new window: store URL, trigger new window
                Self.pendingFolderURL = url
                newWindow()
                // If newWindow didn't work, fallback after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if Self.pendingFolderURL != nil {
                        // New window didn't pick it up — open in current
                        Self.pendingFolderURL = nil
                        ws?.openFolder(url)
                    }
                }
            }
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
