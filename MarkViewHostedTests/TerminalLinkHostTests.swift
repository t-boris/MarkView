import AppKit
import WebKit
import XCTest
import MarkViewCore
@testable import MarkView

/// What the window does with the files and web addresses a terminal hands it; the test decides what each does.
@MainActor private final class LinkWindow: TerminalLinkTarget {
    var onFile: (URL, Int?) -> Void = { _, _ in }
    var onWeb: (URL) -> Void = { _ in }
    func openFile(_ url: URL, line: Int?, endLine: Int?) { onFile(url, line) }
    func openInAppBrowser(_ url: URL) { onWeb(url) }
}

@MainActor private final class TerminalLinkChecks: NSObject, WKScriptMessageHandler {
    var session: TerminalSession!
    var window: NSWindow!
    var messages: [[String: Any]] = []
    var opened: [(URL, Int?)] = []
    var external: [URL] = []
    var dispatchExternal = false
    var didDispatchExternal = false
    /// The window the session belongs to: files open in its editor, web addresses in its browser (recorded here as `external`).
    let linkWindow = LinkWindow()
    var checks = 0
    var failures = 0
    var finish: ((String?) -> Void)?
    private var runningTask: Task<Void, Never>?
    var launched = false
    let root: URL
    init(root: URL) { self.root = root }

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
        if body["type"] as? String != "input" { session.messages.userContentController(c, didReceive: m) }
        if body["type"] as? String == "ready", !launched {
            launched = true
            runningTask = Task { await run() }
        }
    }
    func pureChecks() {
        // The session's handlers and the contract's terminal messages are the same set (AR-28).
        let declared = session.messages.contract.messageTypes(in: "terminal")
        check(!declared.isEmpty && session.messages.registeredTypes == declared, "the session handles exactly the messages the contract declares for the terminal (\(session.messages.registeredTypes.sorted()) vs \(declared.sorted()))")
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
            // Claude Code shape: Ink/ansi-escapes BEL terminator, id= param, mid-line label, alt screen + SGR drag tracking.
            let pr = URL(string: "https://github.com/anthropics/claude-code/pull/1?x=1&y=%20")!
            for (name, open, close) in [("BEL", "\u{1b}]8;;\(pr.absoluteString)\u{7}", "\u{1b}]8;;\u{7}"),
                                         ("BEL+id", "\u{1b}]8;id=cc-7;\(pr.absoluteString)\u{7}", "\u{1b}]8;;\u{7}"),
                                         ("ST+id", "\u{1b}]8;id=cc-8;\(pr.absoluteString)\u{1b}\\", "\u{1b}]8;;\u{1b}\\")] {
                for mode in [0, 1002, 1003] {
                    let prefix = mode == 0 ? "" : "\u{1b}[?1049h\u{1b}[?\(mode)h\u{1b}[?1006h"
                    try await display(prefix + "\u{1b}[2;1H⏺ Opened \u{1b}[1m" + open + "PR #1" + close + "\u{1b}[0m for review\r\n")
                    try await hover(col: 12, row: 2)
                    try await click()
                    check(links.count == 1 && external == [pr] && inputs.isEmpty, "CC-\(name) mode \(mode): links=\(links.count) ext=\(external) inputs=\(inputs.count)")
                }
            }
            // TUIs such as Claude Code hard-wrap a long OSC 8 link with cursor moves; every row keeps the full target.
            let long = URL(string: "https://github.com/anthropics/claude-code/issues/12345#issuecomment-987654321")!
            let head = String(long.absoluteString.prefix(40)), tail = String(long.absoluteString.dropFirst(40))
            let split = "\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[2;3H\u{1b}]8;id=w1;\(long.absoluteString)\u{7}\(head)\u{1b}]8;;\u{7}"
                + "\u{1b}[3;3H\u{1b}]8;id=w1;\(long.absoluteString)\u{7}\(tail)\u{1b}]8;;\u{7}\r\n"
            for row in [2, 3] {
                try await display(split)
                try await hover(col: 6, row: row)
                try await click()
                check(links.count == 1 && external == [long] && inputs.isEmpty, "OSC 8 link hard-wrapped by TUI, row \(row)")
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
            // Every regular file opens in the app (FileType.isOpenable); binary content is refused when the file is read.
            try await display("archive.iso\r\n")
            try await hover(); try await click()
            check(opened.count == 1 && opened.first?.0 == root.appendingPathComponent("archive.iso") && external.isEmpty, "a file of any type opens in the app")
            // A terminal that belongs to no window (a project operation's) hands the file to the default app.
            let loose = TerminalSession(directory: root, openExternalURL: { [weak self] url in self?.external.append(url) })
            external.removeAll(); opened.removeAll()
            loose.activateLink("archive.iso")
            await pause(400)
            check(external == [root.appendingPathComponent("archive.iso")] && opened.isEmpty, "without a window the file goes to the default app")
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
            if ProcessInfo.processInfo.environment["MARKVIEW_TERMINAL_LINK_OPEN_BROWSER"] == "1" {
                dispatchExternal = true
                linkWindow.onWeb = { [weak self] url in self?.didDispatchExternal = NSWorkspace.shared.open(url) }
                try await display(osc); try await hover(); try await click()
                check(didDispatchExternal && links.count == 1, "real default browser launch from OSC 8 Cmd click")
                print("Default browser: \(NSWorkspace.shared.urlForApplication(toOpen: github)?.lastPathComponent ?? "unknown")")
            }
            print("Terminal link checks: \(checks), failures: \(failures)")
            finish?(nil)
        } catch { finish?(error.localizedDescription) }
    }
    func start(entry: URL) {
        TerminalSession.pageURL = entry
        BridgeContract.bundledURL = TerminalSession.pageURL!.deletingLastPathComponent().appendingPathComponent("js/bridge-contract.json")
        linkWindow.onFile = { [weak self] url, line in self?.opened.append((url, line)) }
        linkWindow.onWeb = { [weak self] url in self?.external.append(url) }
        session = TerminalSession(directory: root, links: linkWindow, openExternalURL: { [weak self] url in
            guard let self else { return }
            if self.dispatchExternal { self.didDispatchExternal = NSWorkspace.shared.open(url) }
            else { self.external.append(url) }
        })
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
        window.isReleasedWhenClosed = false
        window.title = "MarkView terminal link tests"
        window.contentView = web
        window.orderBack(nil)
        // Reload to guarantee test instrumentation is installed before terminal construction.
        web.loadFileURL(TerminalSession.pageURL!, allowingReadAccessTo: TerminalSession.pageURL!.deletingLastPathComponent())
    }
    func stop() {
        finish = nil
        runningTask?.cancel()
        session?.webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        session?.terminate()
        window?.close()
    }

}
@MainActor private final class EditorLineLinkChecks: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var web: WKWebView!
    var window: NSWindow!
    var launched = false
    var checks = 0
    var failures = 0
    var finish: ((String?) -> Void)?
    private var runningTask: Task<Void, Never>?
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any], b["type"] as? String == "ready", !launched else { return }
        launched = true
        runningTask = Task { await run() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !launched else { return }
        launched = true
        runningTask = Task { await run() }
    }
    func js(_ source: String) async throws -> Any? { try await web.evaluateJavaScript(source) }
    func check(_ passed: Bool, _ name: String) {
        checks += 1
        if !passed { failures += 1; print("FAIL: \(name)") }
    }
    func pause() async { try? await Task.sleep(nanoseconds: 300_000_000) }
    func run() async {
        do {
            _ = try await js("""
            setContent('---\\ntitle: Fixture\\n---\\n\\n' + Array.from({length: 180}, (_, i) => 'Paragraph ' + (i+1)).join('\\n\\n'));
            documentGotoLine(245);
            """)
            await pause()
            check(try await js("document.querySelector('[data-line=\"245\"]').textContent") as? String == "Paragraph 121", "markdown line maps include front matter")
            let previewScrolls = try await js("document.getElementById('editor-rendered').scrollTop > 0") as? Bool == true
            if !previewScrolls { print("Editor preview diagnostic: \(try await js("(() => { const e=document.getElementById('editor-rendered'); return [innerHeight,e.clientHeight,e.scrollHeight,e.scrollTop]; })()") ?? "unknown")") }
            check(previewScrolls, "markdown preview scrolls")
            check(try await js("(() => {const el = document.querySelector('[data-line=\"245\"]'), r = el.getBoundingClientRect(); return r.top >= 0 && r.bottom < innerHeight;})()") as? Bool == true, "requested markdown line visible")
            check(try await js("getComputedStyle(document.getElementById('preview-pane')).display !== 'none'") as? Bool == true, "markdown stays formatted")
            _ = try await js("toggleSourceMode(); documentGotoLine(245)")
            check(try await js("(() => {const e = document.getElementById('editor-input'); return e.value.slice(e.selectionStart, e.selectionEnd);})()") as? String == "Paragraph 121", "markdown source line selected")
            _ = try await js("setStructuredContent('{\\n' + Array.from({length: 150}, (_,i) => '  \"key' + i + '\": ' + i).join(',\\n') + '\\n}', 'json'); documentGotoLine(102)")
            check(try await js("getComputedStyle(document.getElementById('editor-pane')).display !== 'none'") as? Bool == true, "structured link reveals source")
            check(try await js("(() => {const e = document.getElementById('editor-input'); return e.value.slice(e.selectionStart, e.selectionEnd);})()") as? String == "  \"key100\": 100,", "structured requested line selected")
            check(try await js("document.getElementById('editor-input').scrollTop > 0") as? Bool == true, "structured source scrolls")
            _ = try await js("setCodeContent(Array.from({length:180}, (_,i) => 'let line' + (i+1) + ' = ' + (i+1)).join('\\n'), 'swift', 'fixture.swift'); codeGotoLine(121,121)")
            for _ in 0..<30 {
                if try await js("!!document.querySelector('.cm-scroller') && document.querySelector('.cm-scroller').scrollTop > 0") as? Bool == true { break }
                await pause()
            }
            let codeScrolls = try await js("!!document.querySelector('.cm-scroller') && document.querySelector('.cm-scroller').scrollTop > 0") as? Bool == true
            if !codeScrolls { print("Editor code diagnostic: \(try await js("(() => { const e=document.querySelector('.cm-scroller'); return e && [innerHeight,e.clientHeight,e.scrollHeight,e.scrollTop]; })()") ?? "unknown")") }
            check(codeScrolls, "code line queued across viewer load")
            print("Editor line checks: \(checks), failures: \(failures)")
            finish?(nil)
        } catch { finish?(error.localizedDescription) }
    }
    func start(page: URL) {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "bridge")
        let editorFolder = page.deletingLastPathComponent()
        config.userContentController.addUserScript(try! BridgeContract(contentsOf: editorFolder.appendingPathComponent("js/bridge-contract.json")).userScript)  // the page gets the bridge contract from the app (AR-28)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 480), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "MarkView editor line link tests"
        web.navigationDelegate = self
        window.contentView = web
        window.orderBack(nil)
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }
    func stop() {
        finish = nil
        runningTask?.cancel()
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
        web?.stopLoading()
        window?.close()
    }

}
final class TerminalLinkHostTests: XCTestCase {
    @MainActor func testTerminalLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markview-terminal-links-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["sample.swift", "spaced file.md", "README.md", "LICENSE", "literal%20.md", "colon:42", "archive.iso", "sub/child.swift"] {
            try "test fixture\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let oldPage = TerminalSession.pageURL, oldContract = BridgeContract.bundledURL
        defer { TerminalSession.pageURL = oldPage; BridgeContract.bundledURL = oldContract }
        let entry = try XCTUnwrap(Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "Editor"))
        let checks = TerminalLinkChecks(root: root)
        defer { checks.stop() }
        let done = expectation(description: "terminal link checks completed")
        checks.finish = { error in if let error { XCTFail(error) }; done.fulfill() }
        checks.start(entry: entry)
        await fulfillment(of: [done], timeout: 120)
        XCTAssertEqual(checks.failures, 0)
        XCTAssertGreaterThanOrEqual(checks.checks, 84)
    }
    @MainActor func testEditorLineLinks() async throws {
        let entry = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
        let stylesheet = entry.deletingLastPathComponent().appendingPathComponent("css/editor.css")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stylesheet.path), "The built editor must include its stylesheet")
        let checks = EditorLineLinkChecks()
        defer { checks.stop() }
        let done = expectation(description: "editor line checks completed")
        checks.finish = { error in if let error { XCTFail(error) }; done.fulfill() }
        checks.start(page: entry)
        await fulfillment(of: [done], timeout: 90)
        XCTAssertEqual(checks.failures, 0)
        XCTAssertEqual(checks.checks, 9)
    }
}
