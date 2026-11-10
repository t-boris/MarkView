import AppKit

// A tiny AppKit application for checking the native QA player (feature end-to-end-qa, tools/tests/qa-native-tests.sh): a sign-in form with a
// text field, a secure field, a pop-up, a checkbox, a button, a status label, a scrolling note and a File > Reset menu item. It is an
// accessory application (no Dock icon, never active) whose small window sits at the bottom right of the main screen, behind everything else.
// `--password <x>` sets the password the form accepts (default "secret").

final class Demo: NSObject, NSApplicationDelegate {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let nameLabel = NSTextField(labelWithString: "Name")
    private let name = NSTextField(frame: NSRect(x: 100, y: 222, width: 240, height: 22))
    private let password = NSSecureTextField(frame: NSRect(x: 100, y: 192, width: 240, height: 22))
    private let role = NSPopUpButton(frame: NSRect(x: 96, y: 160, width: 120, height: 25), pullsDown: false)
    private let remember = NSButton(checkboxWithTitle: "Remember me", target: nil, action: nil)
    private let signIn = NSButton(title: "Sign in", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Not signed in")
    private let accepted: String

    override init() {
        let arguments = CommandLine.arguments
        accepted = arguments.firstIndex(of: "--password").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "secret"
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let content = window.contentView!
        nameLabel.frame = NSRect(x: 16, y: 224, width: 80, height: 17)
        let passwordLabel = NSTextField(labelWithString: "Password")
        passwordLabel.frame = NSRect(x: 16, y: 194, width: 80, height: 17)
        let roleLabel = NSTextField(labelWithString: "Role")
        roleLabel.frame = NSRect(x: 16, y: 164, width: 80, height: 17)
        password.setAccessibilityLabel("Password")
        role.addItems(withTitles: ["Viewer", "Editor", "Admin"])
        role.setAccessibilityLabel("Role")
        remember.frame = NSRect(x: 100, y: 134, width: 140, height: 18)
        signIn.frame = NSRect(x: 16, y: 100, width: 90, height: 24)
        signIn.target = self
        signIn.action = #selector(signInPressed)
        status.frame = NSRect(x: 116, y: 104, width: 230, height: 17)
        let notes = NSTextView(frame: NSRect(x: 0, y: 0, width: 328, height: 800))
        notes.string = (1...40).map { "Note line \($0)" }.joined(separator: "\n")
        notes.isEditable = false
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 12, width: 328, height: 76))
        scroll.documentView = notes
        scroll.hasVerticalScroller = true
        scroll.setAccessibilityLabel("Notes")
        for view in [nameLabel, name, passwordLabel, password, roleLabel, role, remember, signIn, status, scroll] as [NSView] { content.addSubview(view) }

        window.title = "QA Native Demo"
        window.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - window.frame.width - 12, y: screen.visibleFrame.minY + 12))
        }
        window.orderBack(nil)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(), fileItem = NSMenuItem(), editItem = NSMenuItem()
        for item in [appItem, fileItem, editItem] { main.addItem(item) }
        let app = NSMenu()
        app.addItem(withTitle: "Quit QA Native Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let file = NSMenu(title: "File")
        let reset = NSMenuItem(title: "Reset", action: #selector(resetPressed), keyEquivalent: "r")
        reset.target = self
        file.addItem(reset)
        fileItem.submenu = file
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    @objc private func signInPressed() {
        status.stringValue = password.stringValue == accepted ? "Signed in as \(name.stringValue)" : "Wrong password"
    }

    @objc private func resetPressed() {
        name.stringValue = ""
        password.stringValue = ""
        status.stringValue = "Not signed in"
        remember.state = .off
        role.selectItem(at: 0)
    }
}

let delegate = Demo()
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
