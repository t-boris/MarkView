import AppKit
import WebKit

// The terminal's unrelated assistant/dictation dependencies are not exercised here.
enum CLITool { case claude, codex, cline, copilot }
final class WhisperClient {}

@MainActor final class TerminalLinkTests: NSObject, WKScriptMessageHandler {
    var session: TerminalSession!
    var window: NSWindow!
    var messages: [[String: Any]] = []
    var opened: [(URL, Int?)] = []
    var external: [URL] = []
    var checks = 0
    var failures = 0
    var launched = false
    let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

    func check(_ passed: Bool, _ name: String) {
        checks += 1
        if !passed { failures += 1; print("FAIL: \(name), opened=\(opened), external=\(external), messages=\(messages)") }
    }
    func js(_ source: String) async throws -> Any? { try await session.webView.evaluateJavaScript(source) }
    func pause(_ ms: UInt64 = 120) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any] else { return }
        messages.append(body)
        // Observe input without typing synthetic mouse reports into the real shell.
        if body["type"] as? String != "input" { session.userContentController(c, didReceive: m) }
        if body["type"] as? String == "ready", !launched {
            launched = true
            Task { await run() }
        }
    }
    func pureChecks() {
        let file = root.appendingPathComponent("sample.swift")
        let resolve: (String) -> TerminalLink? = { TerminalLink.resolve($0, directory: self.root) }
        for text in ["sample.swift", "./sample.swift", file.path, file.absoluteString] {
            check(resolve(text) == .file(file, line: nil), "resolve \(text)")
        }
        for text in ["sample.swift:42", "sample.swift:42:3", "sample.swift#L42", file.absoluteString + "#L42"] {
            check(resolve(text) == .file(file, line: 42), "resolve line \(text)")
        }
        check(resolve("spaced file.md") == .file(root.appendingPathComponent("spaced file.md"), line: nil), "space in path")
        check(resolve("literal%20.md") == .file(root.appendingPathComponent("literal%20.md"), line: nil), "literal percent")
        check(resolve("colon:42") == .file(root.appendingPathComponent("colon:42"), line: nil), "literal colon")
        check(resolve("https://github.com") == .web(URL(string: "https://github.com")!), "https")
        check(resolve("HTTP://example.com/a") == .web(URL(string: "HTTP://example.com/a")!), "http case")
        for text in ["missing.md", "sub", "javascript:alert(1)", "data:text/html,hi", "ssh://host/a", "file://remote/tmp/file", "https:", "https:///", "bad\npath", "sample.swift:0"] {
            check(resolve(text) == nil, "reject \(text)")
        }
        check(TerminalLink.workingDirectory(foregroundPID: 0, shellPID: 0, fallback: root) == root, "cwd fallback")
    }
    func display(_ output: String) async throws {
        _ = try await js("mvReset(); mvWrite('\(Data(output.utf8).base64EncodedString())')")
        await pause()
        messages.removeAll(); opened.removeAll(); external.removeAll()
    }
    func hover(col: Int = 2, row: Int = 1, meta: Bool = true) async throws {
        _ = try await js("""
        (() => { const t = testTerm, r = t.element.querySelector('.xterm-screen').getBoundingClientRect();
        window.point = { clientX: r.left + r.width / t.cols * \(Double(col) - 0.5), clientY: r.top + r.height / t.rows * \(Double(row) - 0.5), bubbles: true, metaKey: \(meta), button: 0 };
        t.element.querySelector('.xterm-screen').dispatchEvent(new MouseEvent('mousemove', {bubbles: true, clientX: r.right - 4, clientY: r.bottom - 4, metaKey: \(meta)}));
        window.target = document.elementFromPoint(point.clientX, point.clientY);
        target.dispatchEvent(new MouseEvent('mousemove', point)); })()
        """)
        // Native filesystem checks complete asynchronously before link activation.
        await pause(300)
    }
    func click(meta: Bool = true, button: Int = 0) async throws {
        _ = try await js("target.dispatchEvent(new MouseEvent('mousedown', {...point, metaKey: \(meta), button: \(button), buttons: \(button == 0 ? 1 : 2)})); target.dispatchEvent(new MouseEvent('mouseup', {...point, metaKey: \(meta), button: \(button)}));")
        await pause(200)
    }
    var links: [[String: Any]] { messages.filter { $0["type"] as? String == "link" } }
    var inputs: [[String: Any]] { messages.filter { $0["type"] as? String == "input" } }
    func run() async {
        do {
            // Wait until the login shell settles, then use deterministic output fixtures.
            await pause(1500)
            pureChecks()
            let github = URL(string: "https://github.com")!
            let osc = "\u{1b}]8;;https://github.com\u{1b}\\different label\u{1b}]8;;\u{1b}\\\r\n"
            for (name, output) in [("plain URL", "https://github.com\r\n"), ("OSC 8", osc)] {
                try await display(output)
                try await hover()
                check(try await js("target.closest('.xterm-screen').title") as? String == "https://github.com (⌘click to open)", "\(name) target tooltip")
                try await click()
                check(links.count == 1 && external == [github], "\(name) opens once through native handler")
            }
            for mode in [1000, 1002, 1003] {
                for output in [osc, "https://github.com\r\n"] {
                    try await display("\u{1b}[?1049h\u{1b}[?\(mode)h\u{1b}[?1006h" + output)
                    try await hover()
                    try await click()
                    check(links.count == 1 && external == [github], "URL opens in mouse mode \(mode), OSC=\(output == osc)")
                    check(inputs.isEmpty, "Cmd click sends no PTY input in mouse mode \(mode)")
                    messages.removeAll(); external.removeAll()
                    try await hover(meta: false)
                    try await click(meta: false)
                    check(inputs.count >= 2 && external.isEmpty && links.isEmpty, "ordinary TUI click preserved in mouse mode \(mode)")
                }
            }
            for path in ["sample.swift:42:3", "./sample.swift:42", root.appendingPathComponent("sample.swift").path + ":42", "sample.swift:42:matched text"] {
                try await display(path + "\r\n")
                try await hover()
                try await click()
                check(opened.count == 1 && opened.first?.0 == root.appendingPathComponent("sample.swift") && opened.first?.1 == 42, "file click \(path)")
                check(external.isEmpty, "supported file stays in app")
            }
            for path in ["README.md", "LICENSE", "\"spaced file.md\"", "literal%20.md", "(sample.swift:42)", "sample.swift:42,"] {
                try await display(path + "\r\n")
                try await hover(col: path.hasPrefix("(") ? 3 : 2)
                try await click()
                check(opened.count == 1, "ls/quoted/punctuation path \(path)")
            }
            try await display("\u{1b}]8;;" + root.appendingPathComponent("sample.swift").absoluteString + "#L42\u{1b}\\file label\u{1b}]8;;\u{1b}\\\r\n")
            try await hover(); try await click()
            check(opened.count == 1 && opened.first?.1 == 42, "OSC 8 file URL with fragment")
            try await display("\u{1b}[?1000h\u{1b}[?1006hsample.swift:42\r\n")
            try await hover(); try await click()
            check(opened.count == 1 && opened.first?.1 == 42 && inputs.isEmpty, "file in mouse-tracking TUI")
            try await display("archive.zip\r\n")
            try await hover(); try await click()
            check(external == [root.appendingPathComponent("archive.zip")] && opened.isEmpty, "unsupported file uses default app")
            try await display("漢字 sample.swift:42\r\n")
            try await hover(col: 7); try await click()
            check(opened.count == 1 && opened.first?.1 == 42, "wide characters before path")
            try await display("e\u{301} sample.swift:42\r\n")
            try await hover(col: 4); try await click()
            check(opened.count == 1, "combining character before path")
            let cols = (try await js("testTerm.cols") as? Int)!
            try await display(String(repeating: " ", count: cols - 5) + "sample.swift:42\r\n")
            try await hover(col: 2, row: 2); try await click()
            check(opened.count == 1 && opened.first?.1 == 42, "soft-wrapped path")
            for output in ["missing.md\r\n", "\u{1b}]8;;javascript:alert(1)\u{1b}\\label\u{1b}]8;;\u{1b}\\\r\n"] {
                try await display(output); try await hover(); try await click()
                check(opened.isEmpty && external.isEmpty, "missing/unsafe link has no native action")
            }
            try await display("https://github.com\r\n"); try await hover(); try await click(button: 2)
            check(external.isEmpty, "right click does not open")
            check(try await js("window.confirms") as? Int == 0, "never falls back to browser confirm")
            // Exercise the real PTY and proc_pidinfo after changing the shell directory.
            session.write("cd '\(root.appendingPathComponent("sub").path)'\r")
            await pause(400)
            try await display("child.swift:7\r\n"); try await hover(); try await click()
            check(opened.count == 1 && opened.first?.0 == root.appendingPathComponent("sub/child.swift") && opened.first?.1 == 7, "relative click follows live shell cd")
            if CommandLine.arguments.contains("--open-browser") {
                var dispatched = false
                session.openExternalURL = { url in dispatched = NSWorkspace.shared.open(url) }
                try await display(osc); try await hover(); try await click()
                check(dispatched && links.count == 1, "real default browser launch from OSC 8 Cmd click")
                print("Default browser: \(NSWorkspace.shared.urlForApplication(toOpen: github)?.lastPathComponent ?? "unknown")")
            }
            print("Terminal link checks: \(checks), failures: \(failures)")
            session.terminate()
            exit(failures == 0 ? 0 : 1)
        } catch { print("ERROR: \(error)"); session.terminate(); exit(1) }
    }
    func start() {
        TerminalSession.pageURL = URL(fileURLWithPath: CommandLine.arguments[1])
        session = TerminalSession(directory: root)
        session.openFile = { [weak self] url, line in self?.opened.append((url, line)) }
        session.openExternalURL = { [weak self] url in self?.external.append(url) }
        let web = session.webView
        web.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        web.configuration.userContentController.add(self, name: "terminal")
        web.configuration.userContentController.addUserScript(WKUserScript(source: """
        window.confirms = 0;
        const oldConfirm = window.confirm.bind(window);
        window.confirm = function(s) { window.confirms++; return oldConfirm(s); };
        Object.defineProperty(window, 'MVTerm', { configurable: true, set(v) {
            const Original = v.Terminal;
            v.Terminal = class extends Original { constructor(o) { super(o); window.testTerm = this; } };
            Object.defineProperty(window, 'MVTerm', { value: v, writable: true, configurable: true });
        }});
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "MarkView terminal link tests"
        window.contentView = web
        window.orderBack(nil)
        // Reload to guarantee test instrumentation is installed before terminal construction.
        web.loadFileURL(TerminalSession.pageURL!, allowingReadAccessTo: TerminalSession.pageURL!.deletingLastPathComponent())
        Task { await pause(90_000); print("TIMEOUT"); session.terminate(); exit(2) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let tests = MainActor.assumeIsolated { let t = TerminalLinkTests(); t.start(); return t }
app.run()
