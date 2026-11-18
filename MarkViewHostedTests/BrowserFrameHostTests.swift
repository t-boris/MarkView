import AppKit
import Network
import WebKit
import XCTest
import MarkViewCore
@testable import MarkView

private final class FrameServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "frame-fixture")
    private let lock = NSLock()
    private var listener: NWListener?
    private var actualPort: UInt16 = 0
    private var content = ""
    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return actualPort }
    func set(_ html: String) { lock.lock(); content = html; lock.unlock() }
    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [self] state in if case .ready = state { lock.lock(); actualPort = listener.port?.rawValue ?? 0; lock.unlock() } }
        listener.newConnectionHandler = { [self] connection in connection.start(queue: queue); receive(connection, Data()) }
        listener.start(queue: queue)
    }
    func stop() { listener?.cancel() }
    private func receive(_ connection: NWConnection, _ old: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            var request = old; if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                lock.lock(); let html = content; lock.unlock()
                let bytes = Data(html.utf8)
                var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8)
                reply.append(bytes)
                connection.send(content: reply, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil { connection.cancel() } else { receive(connection, request) }
        }
    }
}
final class BrowserFrameHostTests: XCTestCase {
    @MainActor func testCrossOriginFrames() async throws {
        var failures = 0
        var checks = 0
        func check(_ passed: Bool, _ name: String) { checks += 1; XCTAssertTrue(passed, name); if !passed { failures += 1 } }
        let root = FrameServer(), child = FrameServer(), nested = FrameServer()
        try root.start(); try child.start(); try nested.start()
        defer { root.stop(); child.stop(); nested.stop() }
        for _ in 0..<200 { if root.port != 0 && child.port != 0 && nested.port != 0 { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(root.port != 0 && child.port != 0 && nested.port != 0)
        nested.set("<button onclick=\"document.body.dataset.clicked=String(event.isTrusted)\">Nested action</button>")
        child.set("""
        <!doctype html><title>Secure payment fixture</title><style>input,button,select{display:block;margin:12px;height:35px}body{background:white}</style>
        <label>Card number<input aria-label="Card number" name="cardnumber" autocomplete="cc-number"></label>
        <input aria-label="Security code" name="cvc" autocomplete="cc-csc">
        <select aria-label="Country"><option>US</option><option>UK</option></select>
        <button onclick="document.body.dataset.clicked=event.isTrusted?'trusted':'script'">Confirm payment fixture</button>
        <input type="password" aria-label="Secret" value="never-show-this-password">
        <iframe title="Nested controls" style="width:300px;height:90px;transform:scale(.8);transform-origin:top left" src="http://127.0.0.1:\(nested.port)/nested"></iframe>
        <script>document.addEventListener('input',e=>{document.body.dataset.trusted=String(e.isTrusted);if(e.target.name==='cardnumber')e.target.value=e.target.value.replace(/[^0-9]/g,'').match(/.{1,4}/g)?.join(' ')||'';})</script>
        """)
        let intro = String(repeating: "<p>Earlier paragraph and unimportant introductory material.</p>", count: 600)
        root.set("""
        <!doctype html><title>Main fixture</title><style>body{background:white}iframe{width:600px;height:450px;border:3px solid black;transform:scale(.9);transform-origin:top left}input{height:30px}</style>
        <h1>Main page</h1><input aria-label="Main name"><iframe title="Secure payment" src="http://127.0.0.1:\(child.port)/card"></iframe>
        <iframe title="Hidden tracker" style="display:none" src="http://127.0.0.1:\(child.port)/hidden"></iframe>
        \(intro)<h2>Late finance evidence</h2><p>Deposit 100 percent. Remaining balance zero.</p><button>Late action</button>
        """)
        let session = BrowserSession(url: nil, dataStore: .nonPersistent(), prompts: NoPrompts())
        let window = QAWebWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.webView
        window.orderBack(nil)
        defer { session.close(); window.close() }
        session.load(URL(string: "http://127.0.0.1:\(root.port)/page")!)
        var snapshot = ""
        for _ in 0..<100 {
            let reply = await BrowserAgentExecutor.run("browser_snapshot", [:], in: session)
            snapshot = reply.text
            if snapshot.contains("Card number") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(snapshot.contains("Main page") && snapshot.contains("## Frame f"), "the main page and a cross-origin payment frame are both observed")
        check(!snapshot.contains("Hidden tracker"), "hidden frames are not read")
        check(!snapshot.contains("never-show-this-password"), "secure field values are never exposed")
        func ref(_ label: String) -> String? {
            guard let line = snapshot.split(separator: "\n").first(where: { $0.contains("\"\(label)\"") }), let end = line.firstIndex(of: "]") else { return nil }
            return String(line[line.index(after: line.startIndex)..<end])
        }
        guard let card = ref("Card number"), let cvc = ref("Security code"), let button = ref("Confirm payment fixture"), let entry = session.agentFrames.entry(for: card) else {
            XCTFail("frame controls are missing"); return
        }
        check(card.hasPrefix("f") && BrowserAgentExecutor.Frames.validRef(card), "child controls have bounded frame-scoped references")
        check(!BrowserAgentExecutor.Frames.validRef("f1:e1'];alert(1)//"), "references cannot become selector script")
        let filled = await BrowserAgentExecutor.run("browser_type", ["ref": card, "value": "4242424242424242"], in: session)
        check(!filled.isError && filled.text.contains("as keystrokes"), "card entry uses the production native text input in the frame")
        _ = await BrowserAgentExecutor.run("browser_type", ["ref": cvc, "value": "123"], in: session)
        let values = try await session.webView.callAsyncJavaScript("return document.querySelector('[name=cardnumber]').value.replaceAll(' ','')==='4242424242424242' && document.body.dataset.trusted==='true';", arguments: [:], in: entry.info, contentWorld: .page) as? Bool
        check(values == true, "WebKit receives the entire formatted card number and trusted input events")
        let redacted = await BrowserAgentExecutor.run("browser_snapshot", [:], in: session)
        check(!redacted.text.contains("4242424242424242") && !redacted.text.contains("4242 4242 4242 4242") && !redacted.text.contains("value=\"123\""), "card number and CVC values stay out of snapshots")
        let clicked = await BrowserAgentExecutor.run("browser_click", ["ref": button], in: session)
        let trustedClick = try await session.webView.callAsyncJavaScript("return document.body.dataset.clicked;", arguments: [:], in: entry.info, contentWorld: .page) as? String
        check(!clicked.isError && trustedClick == "trusted", "a frame button receives a correctly projected native click through CSS scaling and borders")
        snapshot = (await BrowserAgentExecutor.run("browser_snapshot", [:], in: session)).text
        if let nestedRef = ref("Nested action"), let nestedEntry = session.agentFrames.entry(for: nestedRef) {
            let clicked = await BrowserAgentExecutor.run("browser_click", ["ref": nestedRef], in: session)
            let trusted = try await session.webView.callAsyncJavaScript("return document.body.dataset.clicked==='true';", arguments: [:], in: nestedEntry.info, contentWorld: .page) as? Bool
            check(!clicked.isError && trusted == true, "nested cross-origin clicks project through both embedding frames")
        } else { check(false, "nested cross-origin controls are observed") }
        if let country = ref("Country") {
            let local = BrowserAgentExecutor.Frames.localRef(country)
            let selected = await BrowserAgentExecutor.run("browser_evaluate", ["frame_ref": country, "script": "const el=document.querySelector('[data-mv-ref=\"\(local)\"]');el.value='UK';return el.value;"], in: session)
            check(!selected.isError && selected.text.contains("UK"), "frame-specific evaluation selects the actual child control")
        } else { check(false, "child country is observed") }
        _ = try await session.webView.callAsyncJavaScript("window.scrollTo(0,document.documentElement.scrollHeight);return null;", arguments: [:], in: nil, contentWorld: .page)
        snapshot = (await BrowserAgentExecutor.run("browser_snapshot", [:], in: session)).text
        check(String(snapshot.prefix(8000)).contains("Remaining balance zero"), "late visible financial terms survive the QA prompt's 8000-character limit")
        _ = try await session.webView.callAsyncJavaScript("document.querySelectorAll('iframe').forEach(el=>el.remove());return null;", arguments: [:], in: nil, contentWorld: .page)
        _ = await BrowserAgentExecutor.run("browser_snapshot", [:], in: session)
        let stale = await BrowserAgentExecutor.run("browser_type", ["ref": card, "value": "must not reach another page"], in: session)
        check(stale.isError, "removed frame references are rejected rather than retargeted")
        XCTAssertEqual(failures, 0)
        print("Browser frame hosted checks: \(checks)")
    }
}

extension BrowserFrameHostTests {
    func testPasswordRulesAndIsolatedKeychain() {
        func check(_ name: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, name, line: line)
        }
        // Hosts and eligibility.
        check("host drops www and case", PasswordRules.host(of: URL(string: "https://WWW.Example.com/login")) == "example.com")
        check("host of nothing", PasswordRules.host(of: nil) == nil)
        check("typed bare host", PasswordRules.host(fromInput: "Dev.Example.com") == "dev.example.com")
        check("typed host with port", PasswordRules.host(fromInput: " localhost:3000 ") == "localhost")
        check("typed address", PasswordRules.host(fromInput: "https://www.example.com/login?x=1") == "example.com")
        check("typed nothing", PasswordRules.host(fromInput: "  ") == nil)
        check("typed spaces inside", PasswordRules.host(fromInput: "not a site") == nil)
        check("https eligible", PasswordRules.isEligible(scheme: "https", host: "example.com"))
        check("http remote not eligible", !PasswordRules.isEligible(scheme: "http", host: "example.com"))
        check("http localhost eligible", PasswordRules.isEligible(scheme: "http", host: "localhost"))
        check("file not eligible", !PasswordRules.isEligible(scheme: "file", host: "localhost"))

        // Never-save list, in its own defaults suite.
        let suiteName = "mv-password-tests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        check("never list starts empty", PasswordRules.neverHosts(suite).isEmpty)
        PasswordRules.neverSave(host: "bank.example", suite)
        check("never list adds", PasswordRules.neverHosts(suite) == ["bank.example"])
        PasswordRules.allowSaving(host: "bank.example", suite)
        check("never list removes", PasswordRules.neverHosts(suite).isEmpty)

        // Chrome CSV.
        let chrome = "\u{FEFF}name,url,username,password,note\r\n"
            + "example,https://www.example.com/login,ann@example.com,\"p,\"\"w\"\"d\",\"a note\nover two lines\"\r\n"
            + "plain,http://insecure.example/,bob,secret,\r\n"
            + "dev,http://localhost:3000/,carol,devpass,\r\n"
            + "empty,https://empty.example/,dave,,\r\n"
            + "\r\n"
        let parsed = PasswordCSV.parse(chrome)
        check("csv parsed", parsed != nil)
        check("csv keeps https and local rows", parsed?.rows.map(\.host) == ["example.com", "localhost"])
        check("csv quoted comma and quotes", parsed?.rows.first?.password == "p,\"w\"d")
        check("csv skips insecure and empty", parsed?.skipped == 2)
        check("csv multi-line note does not shift rows", parsed?.rows.last?.username == "carol")
        check("csv without columns is rejected", PasswordCSV.parse("a,b\n1,2\n") == nil)
        check("csv safari-style columns", PasswordCSV.parse("Title,URL,Username,Password,Notes,OTPAuth\nx,https://a.example,u,p,,\n")?.rows.count == 1)
        check("csv records without trailing newline", PasswordCSV.records("a,b\nc,d") == [["a", "b"], ["c", "d"]])

        // Download names.
        let folder = URL(fileURLWithPath: "/tmp/dl")
        var taken: Set<String> = ["/tmp/dl/report.pdf", "/tmp/dl/report 2.pdf"]
        check("free name", BrowserDownloads.freeURL(in: folder, suggestedName: "new.zip") { taken.contains($0.path) }.lastPathComponent == "new.zip")
        check("numbered name", BrowserDownloads.freeURL(in: folder, suggestedName: "report.pdf") { taken.contains($0.path) }.lastPathComponent == "report 3.pdf")
        check("no extension", BrowserDownloads.freeURL(in: folder, suggestedName: "LICENSE") { taken.contains($0.path) }.lastPathComponent == "LICENSE")
        check("server cannot pick a folder", BrowserDownloads.freeURL(in: folder, suggestedName: "../../etc/passwd") { _ in false }.path == "/tmp/dl/passwd")
        check("empty name", BrowserDownloads.freeURL(in: folder, suggestedName: "") { _ in false }.lastPathComponent == "download")
        taken = []

        // The Keychain store, under a throwaway domain.
        let store = BrowserPasswordStore(domain: "MarkView browser tests \(UUID().uuidString)")
        defer { for login in store.all() { store.delete(host: login.host, username: login.username) } }
        check("store starts empty", store.all().isEmpty)
        check("store saves", store.save(host: "a.example", username: "ann", password: "one"))
        check("store saves a second user", store.save(host: "a.example", username: "bob", password: "two"))
        check("store saves another site", store.save(host: "b.example", username: "ann", password: "three"))
        check("store lists all", store.all().count == 3)
        check("store lists without passwords", store.all().allSatisfy { $0.password.isEmpty })
        check("store reads by site", Set(store.logins(for: "a.example").map(\.username)) == ["ann", "bob"])
        check("store never mixes sites", store.logins(for: "b.example").map(\.password) == ["three"])
        check("store has host", store.has(host: "a.example") && !store.has(host: "c.example"))
        check("store keeps a login without a user name", store.save(host: "c.example", username: "", password: "nameless")
              && store.logins(for: "c.example").map(\.password) == ["nameless"] && store.all().contains { $0.host == "c.example" && $0.username.isEmpty })
        check("store deletes it", store.delete(host: "c.example", username: "") && !store.has(host: "c.example"))
        check("store updates", store.save(host: "a.example", username: "ann", password: "uno") && store.password(host: "a.example", username: "ann") == "uno")
        check("update keeps the count", store.all().count == 3)
        check("store deletes", store.delete(host: "a.example", username: "ann") && store.password(host: "a.example", username: "ann") == nil)
        check("store delete of nothing is fine", store.delete(host: "zzz.example", username: "x"))
        for login in store.all() { store.delete(host: login.host, username: login.username) }
        check("store cleaned up", store.all().isEmpty)
    }
}

@MainActor final class FileUploadFixturePrompts: UserPrompts {
    var answer: [URL]?
    var calls = 0
    func ask(_ prompt: UserPrompt) -> Int? { nil }
    func chooseFiles(allowsMultiple: Bool, allowsDirectories: Bool) -> [URL]? { calls += 1; return answer }
}


extension BrowserFrameHostTests {
    @MainActor func testQAFileUploadInFixtureWindow() {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
            XCTAssertTrue(condition, name + " " + detail(), line: line)
        }
        func spin(_ seconds: Double = 10, until done: () -> Bool) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
    let html = """
    <!doctype html><title>Upload fixture</title>
    <p>Avatar</p><input type="file" id="direct" name="avatar">
    <label for="hidden" id="pick">Upload photo</label><input type="file" id="hidden" style="display:none">
    <p id="result">nothing chosen</p>
    <script>
    async function report(input) {
      const file = input.files[0];
      if (!file) { document.getElementById('result').textContent = 'empty'; return; }
      const bitmap = await createImageBitmap(file);
      document.getElementById('result').textContent = JSON.stringify({id: input.id, name: file.name, type: file.type, size: file.size, w: bitmap.width, h: bitmap.height});
    }
    for (const input of document.querySelectorAll('input[type=file]')) input.addEventListener('change', () => report(input));
    </script>
    """

        let prompts = FileUploadFixturePrompts()
        let session = BrowserSession(url: nil, dataStore: .nonPersistent(), prompts: prompts)
        let window = QAWebWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { session.close(); window.contentView = nil; window.close() }
        session.webView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window.contentView = session.webView
        window.orderBack(nil)
        session.webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/upload/")!)
        spin { !session.webView.isLoading && session.title == "Upload fixture" }
        check("the fixture page loads", session.title == "Upload fixture")

        @MainActor func tool(_ name: String, _ args: [String: Any]) -> BrowserAgentTools.Reply {
            var reply = BrowserAgentTools.Reply(text: "", pngBase64: nil)
            var done = false
            Task { @MainActor in reply = await BrowserAgentExecutor.run(name, args, in: session); done = true }
            spin { done }
            return reply
        }
        @MainActor func pageText(_ script: String) -> String {
            var value = ""
            var done = false
            session.webView.evaluateJavaScript(script) { result, _ in value = result as? String ?? ""; done = true }
            spin { done }
            return value
        }
        @MainActor func result() -> String { pageText("document.getElementById('result').textContent") }
        @MainActor func reset() { _ = pageText("document.getElementById('result').textContent='nothing chosen'; for (const i of document.querySelectorAll('input[type=file]')) i.value=''; 'ok'") }
        @MainActor func ref(_ line: String, in snapshot: String) -> String? {
            snapshot.split(separator: "\n").first { $0.contains(line) }.flatMap { text in
                text.range(of: "\\[(e[0-9]+)\\]", options: .regularExpression).map { String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
            }
        }

        // The picture the production runner hands out, as a file (the actor writes it with AtomicFile; here the bytes are the same).
        guard let png = QATestImage.pngData() else { check("the built-in picture is drawn", false); return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qa-file-upload-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pictureURL = folder.appendingPathComponent(QATestImage.fileName)
        try? png.write(to: pictureURL)
        prompts.answer = [pictureURL]

        // What the assistant is shown: the visible field, and the label that opens the hidden one (the hidden field itself is not shown).
        let snapshot = tool("browser_snapshot", [:]).text
        let direct = ref("input:file", in: snapshot)
        let label = ref("label \"Upload photo\"", in: snapshot)
        check("the snapshot shows the visible file field", direct != nil, snapshot)
        check("the snapshot shows the label of the hidden file field", label != nil, snapshot)
        check("the hidden file field itself is not listed", snapshot.components(separatedBy: "input:file").count - 1 == 1, snapshot)

        @MainActor func decoded() -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(result().utf8))) as? [String: Any] }

        // A click on the visible field: the page gets the picture, byte for byte, and decodes it at its own size.
        if let direct {
            let clicked = tool("browser_click", ["ref": direct])
            check("the click on the file field succeeds", !clicked.isError, clicked.text)
            spin { result() != "nothing chosen" }
            let file = decoded()
            check("the page receives the built-in picture named as the prompt says", file?["name"] as? String == QATestImage.fileName, result())
            check("the page sees a PNG of the size of the built-in picture", file?["type"] as? String == "image/png" && file?["size"] as? Int == png.count, result())
            check("the page decodes it at \(QATestImage.width) by \(QATestImage.height)", file?["w"] as? Int == QATestImage.width && file?["h"] as? Int == QATestImage.height, result())
            check("the chooser was asked exactly once", prompts.calls == 1, "\(prompts.calls)")
            check("the next snapshot shows the file name in the field's value", tool("browser_snapshot", [:]).text.contains(QATestImage.fileName))
        }

        // A click on the label: the hidden field gets the same picture.
        reset()
        if let label {
            let clicked = tool("browser_click", ["ref": label])
            check("the click on the label succeeds", !clicked.isError, clicked.text)
            spin { result() != "nothing chosen" }
            check("the hidden field received the picture through its label", decoded()?["id"] as? String == "hidden" && decoded()?["name"] as? String == QATestImage.fileName, result())
            check("the chooser was asked a second time", prompts.calls == 2, "\(prompts.calls)")
        }

        // No answer is a cancelled chooser, as a person closing the panel: the page gets nothing and nothing hangs.
        reset()
        prompts.answer = nil
        if let direct {
            _ = tool("browser_click", ["ref": direct])
            spin(2) { false }
            check("a refused chooser leaves the field empty", result() == "nothing chosen", result())
            check("and the chooser was still asked", prompts.calls == 3, "\(prompts.calls)")
        }
    }
}

@MainActor private func qaWindowFixtureSpin(_ seconds: Double, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}

@MainActor private final class QAWindowFixturePlayer {
    private var closed = false
    let output: String?
    let useSystemWindow: Bool
    let web: WKWebView
    let window: NSWindow
    init(useSystemWindow: Bool, output: String?) {
        self.useSystemWindow = useSystemWindow
        self.output = output
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        let type: NSWindow.Type = useSystemWindow ? NSWindow.self : QAWebWindow.self
        window = type.init(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 800),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
    }
    func eval(_ script: String) -> Any? {
        var done = false
        var value: Any?
        web.evaluateJavaScript(script) { result, error in
            if let error { print("JavaScript error:", error.localizedDescription); XCTFail(error.localizedDescription) }
            value = result
            done = true
        }
        qaWindowFixtureSpin(5) { done }
        XCTAssertTrue(done, "JavaScript completes")
        return value
    }
    func capture(_ name: String) -> Int {
        var done = false
        var green = 0
        web.takeSnapshot(with: nil) { image, _ in
            if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                // Sample a coarse grid: a transparent dialog has zero green samples.
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 16) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
                        if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           c.greenComponent > 0.9, c.redComponent < 0.1, c.blueComponent < 0.1 { green += 1 }
                    }
                }
                if let output = self.output, let png = bitmap.representation(using: .png, properties: [:]) {
                    try! png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
                }
            }
            done = true
        }
        qaWindowFixtureSpin(5) { done }
        XCTAssertTrue(done, "snapshot completes")
        return green
    }
    func close() {
        guard !closed else { return }
        closed = true
        web.stopLoading()
        window.contentView = nil
        window.close()
    }
}

extension BrowserFrameHostTests {
    @MainActor func testQAOffscreenWebWindows() throws {
        let application = NSApplication.shared
        let originalKeyWindow = application.keyWindow
        let useSystemWindow = ProcessInfo.processInfo.environment["MARKVIEW_QA_SYSTEM_WINDOW"] == "1"
        let output = ProcessInfo.processInfo.environment["MARKVIEW_QA_SCREENSHOT_DIR"]
        if let output { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }
        func check(_ condition: Bool, _ name: String, line: UInt = #line) {
            XCTAssertTrue(condition, name, line: line)
        }
        let html = """
        <!doctype html><style>
        body { background: white; color: black }
        dialog { width: 500px; height: 400px; background: #00ff00; color: black }
        dialog::backdrop { background: rgba(20,12,10,.6) }
        @keyframes panel-in { from { opacity: 0; transform: scale(.98) translateY(-4px) }
         to { opacity: 1; transform: scale(1) translateY(0) } }
        dialog[open] { animation: panel-in 220ms cubic-bezier(.16,1,.3,1) }
        </style><h1>Package page</h1><button id="open" onclick="document.querySelector('dialog').showModal()">Choose date</button>
        <dialog><h1>Calendar</h1><button id="day" onclick="document.querySelector('#chosen').textContent='25 November 2026'">25</button>
        <p id="chosen">No date selected</p><button onclick="document.querySelector('dialog').close()">Done</button></dialog>
        <script>window.framesSeen=0;function tick(){framesSeen++;requestAnimationFrame(tick)}requestAnimationFrame(tick)</script>
        """
        let first = QAWindowFixturePlayer(useSystemWindow: useSystemWindow, output: output)
        let second = QAWindowFixturePlayer(useSystemWindow: useSystemWindow, output: output)
        defer { first.close(); second.close() }
        for player in [first, second] {
            player.web.loadHTMLString(html, baseURL: URL(string: "https://qa.invalid/"))
        }
        qaWindowFixtureSpin(1)
        for (index, player) in [first, second].enumerated() {
            check(player.eval("document.readyState") as? String == "complete", "player \(index + 1) loads")
            check(player.eval("document.hidden") as? Bool == false, "offscreen page is visible to WebKit")
            check(player.eval("framesSeen > 0") as? Bool == true, "requestAnimationFrame advances")
            check(NSScreen.screens.allSatisfy { !$0.frame.intersects(player.window.frame) }, "host remains outside every screen")
            check(!player.window.isKeyWindow && !player.window.isMainWindow, "host never takes focus")
        }
        for attempt in 1...2 {
            _ = first.eval("document.querySelector('#open').click(); true")
            let animationFinished = "document.getAnimations().length === 0 && getComputedStyle(document.querySelector('dialog')).opacity === '1'"
            qaWindowFixtureSpin(5) { first.eval(animationFinished) as? Bool == true }
            check(first.eval(animationFinished) as? Bool == true, "dialog entrance finishes on open \(attempt)")
            check(first.capture("dialog-\(attempt)") > 500, "screenshot contains the dialog on open \(attempt)")
            check(second.capture("other-player-\(attempt)") == 0, "other player is unaffected")
            // Use the same native event path as BrowserAgentExecutor, not a script click.
            let point = first.eval("JSON.stringify((()=>{let r=document.querySelector('#day').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})())") as? String ?? "{}"
            let coords = (try? JSONSerialization.jsonObject(with: Data(point.utf8))) as? [String: Double] ?? [:]
            var local = CGPoint(x: coords["x"] ?? 0, y: coords["y"] ?? 0)
            if !first.web.isFlipped { local.y = first.web.bounds.height - local.y }
            let location = first.web.convert(local, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: first.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { first.web.mouseDown(with: event) } else { first.web.mouseUp(with: event) }
            }
            qaWindowFixtureSpin(0.1)
            check(first.eval("document.querySelector('#chosen').textContent") as? String == "25 November 2026", "native input selects a date")
            _ = first.eval("document.querySelector('dialog').close(); document.querySelector('#chosen').textContent='No date selected'; true")
        }
        first.window.orderOut(nil)
        qaWindowFixtureSpin(0.2)
        check(!first.window.occlusionState.contains(.visible), "ordered-out window does not claim visibility")
        first.close()
        second.close()
        check(application.keyWindow === originalKeyWindow, "original key window is unchanged")
    }
}
