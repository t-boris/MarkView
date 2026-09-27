import AppKit
import WebKit

// Unrelated assistant/dictation dependencies are not exercised by this harness.
enum CLITool { case claude, codex, cline, copilot }
final class WhisperClient {}

@MainActor final class TerminalLayoutTests: NSObject, WKScriptMessageHandler {
    var session: TerminalSession!
    var window: NSWindow!
    var launched = false
    var checks = 0
    var failures = 0

    func check(_ passed: Bool, _ name: String) {
        checks += 1
        if !passed { failures += 1; print("FAIL: \(name)") }
    }
    func js(_ source: String) async throws -> Any? { try await session.webView.evaluateJavaScript(source) }
    func pause(_ ms: UInt64 = 150) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        session.userContentController(controller, didReceive: message)
        if (message.body as? [String: Any])?["type"] as? String == "ready", !launched {
            launched = true
            Task { await run() }
        }
    }
    func run() async {
        do {
            await pause(1500)
            for width in [300, 500, 699, 941, 1200, 2400, 3440] {
                window.setContentSize(NSSize(width: width, height: 480))
                await pause(250)
                let cols = try await js("testTerm.cols") as! Int
                // The actual shell's COLUMNS and tput must agree with xterm after a resize.
                session.write("clear; printf '%*s\\n' $COLUMNS | tr ' ' =; printf 'SIZE:%s:%s\\n' $COLUMNS $(tput cols)\r")
                var matched = false
                for _ in 0..<20 {
                    if try await js("mvText().includes('SIZE:\(cols):\(cols)')") as? Bool == true {
                        matched = true; break
                    }
                    await pause(100)
                }
                check(matched, "\(width)px: live PTY COLUMNS/tput match xterm")
                check(try await js("mvText().split('\\n')[0] === '='.repeat(testTerm.cols)") as? Bool == true,
                      "\(width)px: shell prints every column")
                for alternate in [false, true] {
                    let prefix = alternate ? "\u{1b}[?1049h" : ""
                    // A styled rightmost cell and a wide glyph exercise TUI output too.
                    let output = prefix + "\u{1b}[2J\u{1b}[H漢" + String(repeating: "W", count: cols - 3)
                        + "\u{1b}[1;31mX\u{1b}[0m"
                    _ = try await js("mvReset(); mvWrite('\(Data(output.utf8).base64EncodedString())')")
                    await pause()
                    let metrics = try await js("""
                        (() => {
                            const host = document.querySelector('#term').getBoundingClientRect();
                            const screen = document.querySelector('.xterm-screen').getBoundingClientRect();
                            const row = document.querySelector('.xterm-rows > div:first-child');
                            const last = row.lastElementChild.getBoundingClientRect();
                            return {left: host.left, right: innerWidth - host.right,
                                screenRight: screen.right, lastRight: last.right,
                                rowRight: row.getBoundingClientRect().right,
                                hostRight: host.right};
                        })()
                        """) as! [String: Double]
                    check(metrics["left"] == 8 && metrics["right"] == 4, "\(width)px: page insets, alt=\(alternate)")
                    check(metrics["lastRight"]! <= metrics["rowRight"]! && metrics["lastRight"]! <= metrics["hostRight"]!,
                          "\(width)px: final TUI cell fully visible, alt=\(alternate), metrics=\(metrics)")
                }
                _ = try await js("mvReset()")
            }
            // xterm 6 owns scrolling through its custom scrollbar, not the empty legacy viewport.
            _ = try await js("testTerm.write(Array.from({length: 120}, (_, i) => 'row ' + i).join('\\r\\n'))")
            await pause(250)
            check(try await js("testTerm.buffer.active.baseY > 0") as? Bool == true, "scrollback is populated")
            let bottom = try await js("testTerm.buffer.active.viewportY") as! Int
            _ = try await js("document.querySelector('.xterm-screen').dispatchEvent(new WheelEvent('wheel', {deltaY: -160, bubbles: true, cancelable: true}))")
            await pause(250)
            check((try await js("testTerm.buffer.active.viewportY") as! Int) < bottom, "wheel scrolls through history")
            _ = try await js("testTerm.scrollToBottom()")
            await pause()
            check(try await js("testTerm.buffer.active.viewportY === testTerm.buffer.active.baseY") as? Bool == true, "scroll returns to bottom")
            check(try await js("document.querySelector('.xterm-scrollable-element > .scrollbar.vertical.visible') !== null") as? Bool == true,
                  "xterm's custom scrollbar remains visible with scrollback")
            print("Terminal layout checks: \(checks), failures: \(failures), DPR: \(try await js("devicePixelRatio") ?? "unknown")")
            session.terminate(); exit(failures == 0 ? 0 : 1)
        } catch { print("ERROR: \(error)"); session.terminate(); exit(1) }
    }
    func start() {
        TerminalSession.pageURL = URL(fileURLWithPath: CommandLine.arguments[1])
        session = TerminalSession(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
        let web = session.webView
        web.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        web.configuration.userContentController.add(self, name: "terminal")
        // Capture the public Terminal instance without adding test hooks to the shipping page.
        web.configuration.userContentController.addUserScript(WKUserScript(source: """
            Object.defineProperty(window, 'MVTerm', { configurable: true, set(v) {
                const Original = v.Terminal;
                v.Terminal = class extends Original { constructor(o) { super(o); window.testTerm = this; } };
                Object.defineProperty(window, 'MVTerm', { value: v, writable: true, configurable: true });
            }});
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "MarkView terminal layout tests"
        window.contentView = web
        window.orderFrontRegardless()
        web.loadFileURL(TerminalSession.pageURL!, allowingReadAccessTo: TerminalSession.pageURL!.deletingLastPathComponent())
        Task { await pause(45_000); print("TIMEOUT"); session.terminate(); exit(2) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let tests = MainActor.assumeIsolated { let t = TerminalLayoutTests(); t.start(); return t }
app.run()
