import AppKit
import WebKit

// AR-04 on the terminal paths, in real WebKit (hidden window, the shipping terminal.html and the real TerminalSession): the values
// the session sends to its page (the window theme, the file names it resolved for the page's link detection) are hostile
// (quotes, backslashes, U+2028/U+2029, `</script>`, code in a quote, a template literal, a very long string) and the page must
// receive each unchanged and run nothing. Recorders replace the page's own functions; `window.__evil` counts code that ran.
// Run through tools/tests/js-call-web-tests.sh (argument 1: terminal.html, argument 2: a folder for the fixture files).

// The terminal's unrelated assistant/dictation dependencies are not exercised here.
enum CLITool { case claude, codex, cline, copilot, antigravity }
final class WhisperClient {}

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail.prefix(700)))")
}
DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
    print("TIMEOUT: no result after 120 s")
    exit(1)
}

@MainActor final class Run: NSObject {
    let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    var session: TerminalSession!
    var window: NSWindow!

    func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    func page(_ body: String, _ arguments: [String: Any] = [:]) async -> String {
        do {
            let value = try await session.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
            return value as? String ?? "\(String(describing: value))"
        } catch {
            return "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
        }
    }

    func start() {
        TerminalSession.pageURL = URL(fileURLWithPath: CommandLine.arguments[1])
        BridgeContract.bundledURL = TerminalSession.pageURL!.deletingLastPathComponent().appendingPathComponent("js/bridge-contract.json")
        session = TerminalSession(directory: root)
        let web = session.webView
        web.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = web
        Task { await run() }
    }

    func run() async {
        // The page has loaded and told the session it is ready (`pageReady`): the session sends nothing before that.
        await pause(2)
        session.refit()
        await pause(2.5)
        check(await page("return typeof window.mvSetTheme + typeof window.mvResolvedLinks;") == "functionfunction", "the shipping terminal page is loaded")

        let hostile: [(String, String)] = [
            ("an apostrophe", "it's an o'brien"),
            ("double quotes", "say \"hi\" and \"\""),
            ("backslashes", "back\\slash and \\' and \\\" and trailing \\"),
            ("U+2028 and U+2029", "separators \u{2028} and \u{2029} inside"),
            ("a closing script tag", "</script><script>window.__evil++</script>"),
            ("code in a quote", "'); window.__evil++; ('"),
            ("code in a double quote", "\"); window.__evil++; (\""),
            ("a template literal", "`${window.__evil++}`"),
            ("emoji and a joiner", "emoji \u{1F600} and \u{1F468}\u{200D}\u{1F469}"),
            ("a very long string", String(repeating: "ab'\"\\\u{2028}</script>", count: 70_000)),
        ]
        _ = await page("""
        window.__evil = 0; window.__spy = [];
        for (const name of ['mvSetTheme', 'mvResolvedLinks']) {
          window[name] = function () { window.__spy.push({ name: name, args: Array.prototype.slice.call(arguments) }); };
        }
        return 'ok';
        """)

        // The window theme: appearance id and accent.
        for (name, value) in hostile {
            session.applyTheme(arguments: [value, value], firstPaint: "")
            await pause(0.3)
            let result = await page("""
            const got = window.__spy; window.__spy = [];
            return got.length === 1 && got[0].name === 'mvSetTheme' && got[0].args.length === 2 && got[0].args[0] === value && got[0].args[1] === value
              ? 'ok' : 'got ' + JSON.stringify(got).slice(0, 200);
            """, ["value": value])
            check(result == "ok", "applyTheme sends \(name) unchanged", result)
        }

        // The file names the session resolved for the page's link detection: files that exist, named with hostile characters.
        var names: [(String, String)] = []
        for (index, item) in hostile.enumerated() where item.1.utf8.count < 200 {
            let fileName = "f\(index) " + item.1.replacingOccurrences(of: "/", with: "_") + ".txt"
            if (try? "x".write(to: root.appendingPathComponent(fileName), atomically: true, encoding: .utf8)) != nil { names.append((item.0, fileName)) }
        }
        check(names.count >= 8, "the fixture files with hostile names were created", "\(names.count)")
        let paths = names.map { $0.1 }
        // The names the session itself resolves as files (it refuses some, such as one with a joiner); the page must get exactly those.
        let expectedPaths = paths.filter { if case .file = TerminalLink.resolve($0, directory: root) { return true }; return false }
        check(expectedPaths.count >= 7, "most of the hostile names are files for the session", "\(expectedPaths.count) of \(paths.count)")
        _ = await page("window.__spy = []; mvBridge.send('resolveLinks', { request: 41, paths: paths }, 'terminal'); return 'sent';", ["paths": paths])
        await pause(1.5)
        let resolved = await page("""
        const got = window.__spy; window.__spy = [];
        if (got.length !== 1 || got[0].name !== 'mvResolvedLinks') return 'got ' + JSON.stringify(got).slice(0, 200);
        const sorted = (list) => list.slice().sort();
        return got[0].args[0] === 41 && JSON.stringify(sorted(got[0].args[1])) === JSON.stringify(sorted(expected)) ? 'ok' : 'args ' + JSON.stringify(got[0].args).slice(0, 300);
        """, ["expected": expectedPaths])
        check(resolved == "ok", "the resolved file names reach the page unchanged and as an array", resolved)

        // The tail request is an integer the session clamps; the page function has been replaced above, so ask the real one.
        check(await page("return String(window.__evil);") == "0", "no value ran code in the terminal page")
        print("\(failures) failures")
        session.terminate()
        exit(failures == 0 ? 0 : 1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let run = MainActor.assumeIsolated { let r = Run(); r.start(); return r }
_ = run
app.run()
