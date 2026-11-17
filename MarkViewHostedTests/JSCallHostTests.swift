import AppKit
import WebKit
import XCTest
import MarkViewCore
@testable import MarkView

@MainActor private final class JSCallTerminalChecks: NSObject {
    let root: URL
    init(root: URL) { self.root = root }
    var failures = 0
    var checks = 0
    var finish: (() -> Void)?
    private var runningTask: Task<Void, Never>?
    func check(_ ok: Bool, _ message: String, _ detail: String = "") {
        checks += 1
        if !ok { failures += 1; print("FAIL \(message) \(detail)") }
    }
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

    func start(entry: URL) {
        TerminalSession.pageURL = entry
        BridgeContract.bundledURL = TerminalSession.pageURL!.deletingLastPathComponent().appendingPathComponent("js/bridge-contract.json")
        session = TerminalSession(directory: root)
        let web = session.webView
        web.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = web
        runningTask = Task { await run() }
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

        // The window theme: appearance id, accent and the theme's data (a JSON text the page receives parsed).
        for (name, value) in hostile {
            session.applyTheme(arguments: WebThemeArguments(id: value, accent: value, payload: #"{"id":"x","note":"\#(value.count)"}"#), firstPaint: "")
            await pause(0.3)
            let result = await page("""
            const got = window.__spy; window.__spy = [];
            return got.length === 1 && got[0].name === 'mvSetTheme' && got[0].args.length === 3 && got[0].args[0] === value && got[0].args[1] === value && got[0].args[2].id === 'x'
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
        finish?()
    }
    func stop() {
        finish = nil
        runningTask?.cancel()
        session?.terminate()
        window?.close()
    }

}

final class JSCallHostTests: XCTestCase {
    @MainActor func testEditorHostileValues() throws {
let editor = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor")).deletingLastPathComponent().path
var failures = 0
var checks = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    checks += 1
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail.prefix(700)))")
}
let oldContract = BridgeContract.bundledURL
defer { BridgeContract.bundledURL = oldContract }
BridgeContract.bundledURL = URL(fileURLWithPath: editor + "/js/bridge-contract.json")
let contract = try! BridgeContract(contentsOf: BridgeContract.bundledURL!)

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

final class Loaded: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

let delegate = RecordingDelegate()
let bridge = WebViewBridge(contract: contract)
bridge.delegate = delegate
let config = WKWebViewConfiguration()
config.userContentController.add(bridge.messages, name: "bridge")
config.userContentController.addUserScript(MainActor.assumeIsolated { contract.userScript })
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.alphaValue = 0
defer { web.stopLoading(); window.close() }
window.contentView = web
let loaded = Loaded()
web.navigationDelegate = loaded
web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

func page(_ body: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 30) -> String {
    var out: String?
    web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
        switch result {
        case .success(let value): out = value as? String ?? "\(String(describing: value))"
        case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
        }
    }
    spin(timeout) { out != nil }
    return out ?? "TIMEOUT"
}

spin(30) { loaded.done }
check(loaded.done, "the shipping editor page loaded")
spin(2)

let hostile: [(name: String, value: String)] = [
    ("an apostrophe", "it's an o'brien folder"),
    ("double quotes", "say \"hi\" and \"\""),
    ("backslashes", "back\\slash and \\' and \\\" and trailing \\"),
    ("U+2028 and U+2029", "separators \u{2028} and \u{2029} inside"),
    ("a closing script tag", "</script><script>window.__evil++</script>"),
    ("code in a quote", "'); window.__evil++; ('"),
    ("code in a double quote", "\"); window.__evil++; (\""),
    ("a template literal", "`${window.__evil++}`"),
    ("control characters", "tab\there\u{1}\u{1F}\u{7F}"),
    ("emoji and a joiner", "emoji \u{1F600} and \u{1F468}\u{200D}\u{1F469}"),
    ("comment markers", "// comment /* block */ <!-- html comment -->"),
    ("a very long string", String(repeating: "ab'\"\\\u{2028}</script>", count: 70_000)),
    ("an empty string", ""),
]

// MARK: - A document loaded the way the app loads it

_ = page("window.__evil = 0; return 'ok';")
for item in hostile where !item.value.contains("\u{1}") && item.value != "" {
    let tab = UUID()
    delegate.lastContent = nil
    var completed = false
    bridge.loadContent(item.value, documentID: tab, into: web) { completed = true }
    spin(20) { completed && delegate.lastContent == item.value }
    check(delegate.lastContent == item.value && delegate.documentIDs.last == tab,
          "loadContent: \(item.name) comes back from the page as the same markdown", "\(delegate.lastContent?.count ?? -1) of \(item.value.count) characters")
}
check(page("return String(window.__evil);") == "0", "no markdown ran code in the page")

// MARK: - Every other command, against recorders

let commands = ["mvSetDocument", "setContent", "setCodeContent", "setStructuredContent", "setDocumentBase", "scrollToHeading", "setTheme",
                "updateInsightSection", "setInsightStatus", "setInsightError", "revealStructure", "documentGotoLine", "codeGotoLine",
                "mvResearchMapSet", "showArchitecture", "setArchitectureProgress", "setProjectOperations", "setCodeNotes", "onCodeNavEvent",
                "setDataContent", "loadInsightSkeleton", "releaseInsightBlobs"]
_ = page("""
window.__spy = [];
for (const name of names) {
  window[name] = function () { window.__spy.push({ name: name, args: Array.prototype.slice.call(arguments) }); };
}
return 'ok';
""", ["names": commands])

/// What the recorders hold, compared with `expected` (name and arguments, in order) inside the page. "ok" when equal.
func compare(_ expected: [[String: Any]]) -> String {
    page("""
    const canon = (v) => Array.isArray(v) ? v.map(canon) : (v && typeof v === 'object') ? Object.keys(v).sort().reduce((o, k) => { o[k] = canon(v[k]); return o; }, {}) : v;
    const same = (a, b) => JSON.stringify(canon(a)) === JSON.stringify(canon(b));
    const got = window.__spy; window.__spy = [];
    if (got.length !== expected.length) return 'count ' + got.length + ' of ' + expected.length + ': ' + got.map(g => g.name).join(',');
    for (let i = 0; i < got.length; i++) {
      if (got[i].name !== expected[i].name) return 'name ' + got[i].name + ' != ' + expected[i].name;
      if (!same(got[i].args, expected[i].args)) return 'args of ' + got[i].name + ': ' + JSON.stringify(got[i].args).slice(0, 300);
    }
    return 'ok';
    """, ["expected": expected])
}

let documentID = UUID()
for item in hostile {
    let text = item.value
    // A JSON text that holds the hostile value: the page parses it and must see the same value.
    let objectJSON = String(data: try! JSONSerialization.data(withJSONObject: ["title": text, "list": [text, 1, true]]), encoding: .utf8)!
    let url = URL(fileURLWithPath: "/tmp/" + text.prefix(200).replacingOccurrences(of: "/", with: "_") + "/")
    var base = url.absoluteString
    if !base.hasSuffix("/") { base += "/" }
    let skeleton = InsightSkeleton(title: text, suggestedTheme: nil, sections: [])

    bridge.loadCodeContent(text, language: text, fileName: text, returnLabel: text, documentID: documentID, into: web)
    bridge.loadStructuredContent(text, fileType: text, documentID: documentID, into: web) {}
    bridge.setDocumentBase(url, in: web)
    bridge.scrollToHeading(text, in: web)
    bridge.setTheme(WebThemeArguments(id: text, accent: text, payload: objectJSON), in: web)
    bridge.updateInsightSection(sessionId: text, sectionId: text, htmlChunk: text, into: web)
    bridge.setInsightStatus(sessionId: text, message: text, phase: text, into: web)
    bridge.setInsightError(sessionId: text, message: text, retryable: true, into: web)
    bridge.revealStructure(pathJSON: text, line: 7, in: web)
    bridge.setResearchMap(objectJSON, documentID: documentID, in: web)
    bridge.showArchitecture(objectJSON, in: web)
    bridge.setArchitectureProgress(objectJSON, in: web)
    bridge.setProjectOperations(objectJSON, in: web)
    bridge.setCodeNotes(objectJSON, in: web)
    bridge.sendCodeNavEvent(objectJSON, in: web)
    bridge.loadInsightSkeleton(skeleton: skeleton, sessionId: text, nodeId: text, breadcrumbs: [(text, text)], into: web)
    bridge.revealCodeLine(3, endLine: nil, in: web)
    bridge.revealDocumentLine(4, in: web)
    bridge.loadDataContent(url, fileType: text, reload: false, documentID: documentID, into: web)

    let parsed: [String: Any] = ["title": text, "list": [text, 1, true]]
    let docArgs: [String: Any] = ["name": "mvSetDocument", "args": [documentID.uuidString]]
    let source = DataFileSchemeHandler.address(of: url)
    let expected: [[String: Any]] = [
        docArgs, ["name": "setCodeContent", "args": [text, text, text, text]],
        docArgs, ["name": "setStructuredContent", "args": [text, text]],
        ["name": "setDocumentBase", "args": [base]],
        ["name": "scrollToHeading", "args": [text]],
        ["name": "setTheme", "args": [text, text, parsed]],
        ["name": "updateInsightSection", "args": [text, text, text]],
        ["name": "setInsightStatus", "args": [text, text, text]],
        ["name": "setInsightError", "args": [text, text, true]],
        ["name": "revealStructure", "args": [text, 7]],
        ["name": "mvResearchMapSet", "args": [documentID.uuidString, parsed]],
        ["name": "showArchitecture", "args": [parsed]],
        ["name": "setArchitectureProgress", "args": [parsed]],
        ["name": "setProjectOperations", "args": [parsed]],
        ["name": "setCodeNotes", "args": [parsed]],
        ["name": "onCodeNavEvent", "args": [parsed]],
        ["name": "loadInsightSkeleton", "args": [["title": text, "sections": []] as [String: Any], text, text, [["nodeId": text, "title": text]]]],
        ["name": "codeGotoLine", "args": [3, 3]],
        ["name": "documentGotoLine", "args": [4]],
        docArgs, ["name": "setDataContent", "args": [["src": source, "kind": text, "name": url.lastPathComponent, "reload": false] as [String: Any]]],
    ]
    spin(0.3) { false }   // the commands are queued in order; the next call of the page runs after all of them
    let result = compare(expected)
    check(result == "ok", "every bridge command passes \(item.name) unchanged", result)
}
check(page("return String(window.__evil);") == "0", "no value ran code in the page")

// Commands that take no value still reach the page.
bridge.releaseInsightBlobs(into: web)
bridge.clearDocument(in: web)
spin(0.5) { false }
check(compare([["name": "releaseInsightBlobs", "args": [] as [Any]], ["name": "mvSetDocument", "args": [""]]]) == "ok", "a command without a value is a plain call, and clearDocument names no tab")

        print("Editor hostile-value hosted checks: \(checks)")
        XCTAssertEqual(failures, 0)
    }
    @MainActor func testTerminalHostileValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markview-js-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPage = TerminalSession.pageURL, oldContract = BridgeContract.bundledURL
        defer { TerminalSession.pageURL = oldPage; BridgeContract.bundledURL = oldContract }
        let entry = try XCTUnwrap(Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "Editor"))
        let checks = JSCallTerminalChecks(root: root)
        defer { checks.stop() }
        let done = expectation(description: "terminal hostile-value checks completed")
        checks.finish = { done.fulfill() }
        checks.start(entry: entry)
        await fulfillment(of: [done], timeout: 150)
        print("Terminal hostile-value hosted checks: \(checks.checks)")
        XCTAssertEqual(checks.failures, 0)
        XCTAssertGreaterThan(checks.checks, 0)
    }
}
