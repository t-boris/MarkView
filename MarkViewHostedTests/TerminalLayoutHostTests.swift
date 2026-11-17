import AppKit
import WebKit
import XCTest
import MarkViewCore
@testable import MarkView

@MainActor private final class TerminalLayoutChecks: NSObject, WKScriptMessageHandler {
    var session: TerminalSession!
    var window: NSWindow!
    var launched = false
    var readySize: (cols: Int, rows: Int)?
    var checks = 0
    var failures = 0
    var finish: ((String?) -> Void)?
    private var runningTask: Task<Void, Never>?

    func check(_ passed: Bool, _ name: String) {
        checks += 1
        if !passed { failures += 1; print("FAIL: \(name)") }
    }
    func js(_ source: String) async throws -> Any? { try await session.webView.evaluateJavaScript(source) }
    func pause(_ ms: UInt64 = 150) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        session.messages.userContentController(controller, didReceive: message)
        if let body = message.body as? [String: Any], body["type"] as? String == "ready", !launched {
            let payload = body["payload"] as? [String: Any] ?? [:]
            readySize = (payload["cols"] as? Int ?? 0, payload["rows"] as? Int ?? 0)
            launched = true
            runningTask = Task { await run() }
        }
    }
    func run() async {
        do {
            await pause(1500)
            // Simulate xterm cell metrics arriving after the initial fit and the
            // first ResizeObserver callback. No native resize should be needed.
            let initialFit = try await js("testFit.proposeDimensions()") as! [String: Int]
            check(readySize?.cols == initialFit["cols"] && readySize?.rows == initialFit["rows"],
                  "initial ready waits for valid cell metrics and reports the fitted grid")
            // WebKit being ready does not mean the login shell has finished starting.
            // Wait for a command executed by the real shell before testing PTY resizing.
            session.write("printf 'MV_LAYOUT_%s\\n' SHELL_READY\r")
            var shellReady = false
            for _ in 0..<150 {
                if try await js("mvText().includes('MV_LAYOUT_SHELL_READY')") as? Bool == true {
                    shellReady = true; break
                }
                await pause(100)
            }
            guard shellReady else { throw NSError(domain: "TerminalLayoutTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "The shell did not become ready"]) }
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
                if !matched {
                    let sizes = try await js("mvText().match(/SIZE:[0-9]+:[0-9]+/g) || []") ?? []
                    print("PTY size diagnostic: xterm=\(cols), reported=\(sizes), running=\(session.isRunning)")
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
                                hostRight: host.right, screenBottom: screen.bottom, hostBottom: host.bottom};
                        })()
                        """) as! [String: Double]
                    check(metrics["left"] == 8 && metrics["right"] == 4, "\(width)px: page insets, alt=\(alternate)")
                    check(metrics["lastRight"]! <= metrics["rowRight"]! && metrics["lastRight"]! <= metrics["hostRight"]!,
                          "\(width)px: final TUI cell fully visible, alt=\(alternate), metrics=\(metrics)")
                    check(metrics["screenBottom"]! <= metrics["hostBottom"]!,
                          "\(width)px: bottom TUI row fits, alt=\(alternate), metrics=\(metrics)")
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
            finish?(nil)
        } catch { finish?(error.localizedDescription) }
    }
    func start(entry: URL, directory: URL) {
        TerminalSession.pageURL = entry
        BridgeContract.bundledURL = TerminalSession.pageURL!.deletingLastPathComponent().appendingPathComponent("js/bridge-contract.json")
        session = TerminalSession(directory: directory)
        let web = session.webView
        web.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        web.configuration.userContentController.add(self, name: "terminal")
        // Capture the public Terminal instance without adding test hooks to the shipping page.
        web.configuration.userContentController.addUserScript(WKUserScript(source: """
            Object.defineProperty(window, 'MVTerm', { configurable: true, set(v) {
                const Original = v.Terminal;
                v.Terminal = class extends Original { constructor(o) { super(o); window.testTerm = this; } };
                const OriginalFit = v.FitAddon;
                let attempts = 0;
                v.FitAddon = class extends OriginalFit {
                    constructor() { super(); window.testFit = this; }
                    proposeDimensions() {
                        if (++attempts <= 2) return undefined;
                        return super.proposeDimensions();
                    }
                };
                Object.defineProperty(window, 'MVTerm', { value: v, writable: true, configurable: true });
            }});
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "MarkView terminal layout tests"
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
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
final class TerminalLayoutHostTests: XCTestCase {
    @MainActor func testLayoutAndLivePTY() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markview-terminal-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPage = TerminalSession.pageURL
        let oldContract = BridgeContract.bundledURL
        defer { TerminalSession.pageURL = oldPage; BridgeContract.bundledURL = oldContract }
        let entry = try XCTUnwrap(Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "Editor"))
        let checks = TerminalLayoutChecks()
        defer { checks.stop() }
        let done = expectation(description: "terminal layout checks completed")
        checks.finish = { error in
            if let error { XCTFail("Terminal layout failed: \(error)") }
            done.fulfill()
        }
        checks.start(entry: entry, directory: root)
        await fulfillment(of: [done], timeout: 60)
        XCTAssertEqual(checks.failures, 0)
        XCTAssertEqual(checks.checks, 61)
    }
}
