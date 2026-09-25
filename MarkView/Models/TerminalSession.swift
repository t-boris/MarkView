import AppKit
import Darwin
import WebKit

/// What a terminal in the AI panel runs: an assistant inside the user's shell, or the
/// shell alone.
enum TerminalProfile: String, CaseIterable, Identifiable {
    case claude, codex, cline, copilot, shell

    var id: String { rawValue }

    init(_ tool: CLITool) {
        switch tool {
        case .claude: self = .claude
        case .codex: self = .codex
        case .cline: self = .cline
        case .copilot: self = .copilot
        }
    }

    var tool: CLITool? {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .cline: return .cline
        case .copilot: return .copilot
        case .shell: return nil
        }
    }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cline: return "Cline"
        case .copilot: return "Copilot"
        case .shell: return "Shell"
        }
    }

    var icon: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cline: return "circle.hexagongrid"
        case .copilot: return "airplane"
        case .shell: return "terminal"
        }
    }
}

/// One embedded terminal: a login shell on a pseudo-terminal (PTY) that Swift owns,
/// drawn by xterm.js in its own web view (`Resources/Editor/terminal.html`).
///
/// The web view lives as long as the session, so switching tabs or panels never
/// loses the screen. Output is read on a background queue and sent to the page in
/// batches; keystrokes and size changes come back through the "terminal" handler.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, WKScriptMessageHandler {
    let id = UUID()
    let directory: URL
    /// Typed into the shell once it is up (e.g. "claude --model sonnet"), or nil.
    private(set) var startupCommand: String?
    /// What it runs; a shell for terminals opened in folders.
    @Published private(set) var profile: TerminalProfile
    /// Tab title in the AI panel ("Claude Code", "Codex 2").
    var title: String

    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?

    private(set) lazy var webView: WKWebView = makeWebView()
    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var pageReady = false
    private var pendingOutput = Data()
    private var flushScheduled = false
    private var startupSent = false
    /// When the shell started (for `pasteWhenReady`); nil before the page asked for it.
    private var startedAt: Date?
    private var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

    init(directory: URL, profile: TerminalProfile = .shell, startupCommand: String? = nil, title: String? = nil) {
        self.directory = directory
        self.profile = profile
        self.startupCommand = startupCommand
        self.title = title ?? profile.title
        super.init()
    }

    // MARK: - Web view

    /// The terminal page (overridable for tests that run outside the app bundle).
    static var pageURL = Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "Editor")

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakMessageHandler(self), name: "terminal")
        let view = WKWebView(frame: .zero, configuration: configuration)
        if let page = Self.pageURL {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                pageReady = true
                resize(cols: body["cols"] as? Int ?? 80, rows: body["rows"] as? Int ?? 24)
                applyTheme()
                if masterFD < 0 { start() } else { flush() }
            case "input":
                if let text = body["data"] as? String { write(text) }
            case "resize":
                resize(cols: body["cols"] as? Int ?? 80, rows: body["rows"] as? Int ?? 24)
            case "pasteFiles":
                pasteClipboardFiles()
            case "link":
                if let text = body["url"] as? String, let url = URL(string: text),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
        }
    }

    func applyTheme() {
        guard pageReady else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        webView.evaluateJavaScript("window.mvSetTheme && window.mvSetTheme(\(dark))")
    }

    func focus() {
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.mvFocus && window.mvFocus()")
    }

    // MARK: - Process

    /// Start the user's login shell in `directory` on a new PTY.
    func start() {
        guard masterFD < 0 else { return }
        exitCode = nil
        startupSent = false
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        // Markers of a Claude Code session MarkView may have been launched from: inherited,
        // they make claude in this terminal act as that session's child (no transcripts).
        // The login shell sets the user's own CLAUDE_CODE_* settings again from its rc files.
        for key in environment.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") {
            environment[key] = nil
        }
        // Claude Code in these terminals always keeps its session transcripts (resume, history).
        environment["CLAUDE_CODE_FORCE_SESSION_PERSISTENCE"] = "1"
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "MarkView"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }

        // Everything the child needs is prepared before fork: after fork only
        // async-signal-safe calls (chdir, execve, _exit) are allowed.
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shell), strdup("-l"), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let directoryPath = strdup(directory.path)
        let shellPath = strdup(shell)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(directoryPath)
            free(shellPath)
        }
        var master: Int32 = -1
        var windowSize = size
        let pid = forkpty(&master, nil, nil, &windowSize)
        if pid == 0 {
            _ = chdir(directoryPath!)
            _ = execve(shellPath!, argv, envp)
            _exit(127)
        }
        guard pid > 0 else {
            deliver(Data("\r\nCould not start a terminal: \(String(cString: strerror(errno)))\r\n".utf8))
            return
        }
        masterFD = master
        childPID = pid
        isRunning = true
        startedAt = Date()
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .userInitiated))
        read.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(master, &buffer, buffer.count)
            guard count > 0 else { return }
            let data = Data(buffer[0..<count])
            Task { @MainActor in self?.deliver(data) }
        }
        read.resume()
        readSource = read

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            MainActor.assumeIsolated { self?.processExited(status: status) }
        }
        exit.resume()
        exitSource = exit
    }

    private func processExited(status: Int32) {
        readSource?.cancel(); readSource = nil
        exitSource?.cancel(); exitSource = nil
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        childPID = 0
        isRunning = false
        exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        webView.evaluateJavaScript("window.mvExited && window.mvExited(\(exitCode ?? 0))")
    }

    /// Start again (same folder; optionally a new startup command). The terminal is fully
    /// reset: a program killed mid-run (claude, codex) never switched its modes off, and a
    /// leftover mouse-tracking mode would type mouse reports into the new shell.
    func restart(startupCommand command: String? = nil) {
        if let command { startupCommand = command }
        restartProcess()
    }

    /// Restart running something else (the toolbar switched the assistant).
    func restart(profile newProfile: TerminalProfile, startupCommand command: String?, title newTitle: String) {
        profile = newProfile
        startupCommand = command
        title = newTitle
        restartProcess()
    }

    private func restartProcess() {
        terminate()
        pendingOutput.removeAll()
        webView.evaluateJavaScript("window.mvReset && window.mvReset()")
        start()
    }

    /// End the shell and everything started in it.
    func terminate() {
        if childPID > 0 { kill(-childPID, SIGHUP); kill(childPID, SIGHUP) }
        readSource?.cancel(); readSource = nil
        exitSource?.cancel(); exitSource = nil
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        childPID = 0
        isRunning = false
    }

    // MARK: - Input and output

    /// Keystrokes or text into the terminal, as if typed.
    func write(_ text: String) {
        guard masterFD >= 0 else { return }
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { Darwin.write(masterFD, $0.baseAddress, $0.count) }
            if written <= 0 { break }
            offset += written
        }
    }

    /// Insert text as a paste: full-screen programs (claude, codex) take it as one block,
    /// newlines included, without running it. `submit` presses Enter afterwards.
    func paste(_ text: String, submit: Bool = false) {
        write("\u{1b}[200~" + text + "\u{1b}[201~")
        if submit {
            // Give the program a moment to take the paste before Enter.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.write("\r") }
        }
        focus()
    }

    /// Paste of something that is not text: files copied in Finder are typed as their paths;
    /// an image (a screenshot) is saved as a PNG and its path typed. Claude Code and Codex
    /// attach an image given by its path.
    func pasteClipboardFiles(from pasteboard: NSPasteboard = .general) {
        var paths: [String] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            paths = urls.map(\.path)
        } else if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MarkView/pasted-images", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("image-\(Int(Date().timeIntervalSince1970 * 1000)).png")
            guard (try? png.write(to: file)) != nil else { return }
            paths = [file.path]
        }
        guard !paths.isEmpty else { return }
        // Escaped the way Terminal does for a dropped file.
        let escaped = paths.map { path in
            path.reduce(into: "") { out, character in
                if " '\"()[]{}&;$`!*?<>|#~\\".contains(character) { out.append("\\") }
                out.append(character)
            }
        }
        paste(escaped.joined(separator: " "))
    }

    /// Like `paste`, but when the session has only just started, wait until the startup
    /// command (the assistant) has had time to come up.
    func pasteWhenReady(_ text: String, submit: Bool) {
        let wait = max(0, (startedAt?.timeIntervalSinceNow ?? 0) + 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.paste(text, submit: submit) }
    }

    private func resize(cols: Int, rows: Int) {
        size.ws_col = UInt16(max(2, cols))
        size.ws_row = UInt16(max(2, rows))
        guard masterFD >= 0 else { return }
        var windowSize = size
        _ = ioctl(masterFD, TIOCSWINSZ, &windowSize)
    }

    /// Output to the page, batched per frame; the startup command goes in once the
    /// shell has printed its prompt.
    private func deliver(_ data: Data) {
        pendingOutput.append(data)
        if !startupSent, let command = startupCommand, !command.isEmpty {
            startupSent = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.write(command + "\r") }
        }
        guard pageReady, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard pageReady, !pendingOutput.isEmpty else { return }
        let chunk = pendingOutput.base64EncodedString()
        pendingOutput.removeAll(keepingCapacity: true)
        webView.evaluateJavaScript("window.mvWrite('\(chunk)')")
    }
}

/// WKUserContentController retains its handlers; this keeps the session releasable.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
