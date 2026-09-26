import AppKit
import WebKit

@MainActor final class EditorLineLinkTests: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var web: WKWebView!
    var window: NSWindow!
    var launched = false
    var checks = 0
    var failures = 0
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any], b["type"] as? String == "ready", !launched else { return }
        launched = true
        Task { await run() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !launched else { return }
        launched = true
        Task { await run() }
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
            check(try await js("document.getElementById('editor-rendered').scrollTop > 0") as? Bool == true, "markdown preview scrolls")
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
            check(try await js("!!document.querySelector('.cm-scroller') && document.querySelector('.cm-scroller').scrollTop > 0") as? Bool == true, "code line queued across viewer load")
            print("Editor line checks: \(checks), failures: \(failures)")
            exit(failures == 0 ? 0 : 1)
        } catch { print("ERROR: \(error)"); exit(1) }
    }
    func start() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "bridge")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 480), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "MarkView editor line link tests"
        web.navigationDelegate = self
        window.contentView = web
        window.orderBack(nil)
        let page = URL(fileURLWithPath: CommandLine.arguments[1])
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        Task { try? await Task.sleep(nanoseconds: 60_000_000_000); print("TIMEOUT"); exit(2) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let tests = MainActor.assumeIsolated { let t = EditorLineLinkTests(); t.start(); return t }
app.run()
