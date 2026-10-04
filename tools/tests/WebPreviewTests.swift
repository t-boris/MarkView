// Checks the browser tab's pure rules (MarkView/Models/WebAppPreview.swift, WebClip.swift,
// BrowserAddress in BrowserSession.swift) and runs the page-to-Markdown converter
// (Resources/Editor/vendor/js/markview-page-markdown.js) in a real WKWebView.
import AppKit
import Foundation
import WebKit

/// Stand-in for the app's terminal (the bridge only needs its id and handler).
@MainActor final class TerminalSession {
    let id = UUID()
    var openInAppBrowser: ((URL) -> Void)?
    var openFile: ((URL, Int?) -> Void)?
}

/// Stand-in for the app's file types (DocumentState.swift needs the whole app): what the editor
/// and image viewer open.
enum FileType {
    static func isOpenable(_ url: URL) -> Bool { ["md", "json", "png"].contains(url.pathExtension.lowercased()) }
}

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { print("ok  \(name)") } else {
        failures += 1
        let more = detail()
        print("FAIL \(name)" + (more.isEmpty ? "" : "\n     \(more)"))
    }
}

// MARK: Dev server output

let vite = "\u{1B}[32m\u{1B}[1mVITE\u{1B}[22m v5.0.0\u{1B}[39m  ready in 312 ms\n\n  \u{1B}[32m➜\u{1B}[39m  \u{1B}[1mLocal\u{1B}[22m:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m\n"
check("vite address through colour codes", WebAppPreview.firstLocalURL(in: vite)?.absoluteString == "http://localhost:5173/")
check("next address", WebAppPreview.firstLocalURL(in: "- ready started server on 0.0.0.0:3000, url: http://localhost:3000")?.absoluteString == "http://localhost:3000")
check("0.0.0.0 becomes localhost", WebAppPreview.firstLocalURL(in: "Listening on http://0.0.0.0:8000/.")?.absoluteString == "http://localhost:8000/")
check("127.0.0.1 kept", WebAppPreview.firstLocalURL(in: "Starting development server at http://127.0.0.1:8000/")?.absoluteString == "http://127.0.0.1:8000/")
check("remote address ignored", WebAppPreview.firstLocalURL(in: "see https://vitejs.dev/config") == nil)
check("angular", WebAppPreview.firstLocalURL(in: "** Angular Live Development Server is listening on localhost:4200, open your browser on http://localhost:4200/ **")?.absoluteString == "http://localhost:4200/")

// MARK: Ports

check("--port", WebAppPreview.explicitPorts(in: "vite --port 4000") == [4000])
check("-p and PORT=", WebAppPreview.explicitPorts(in: "PORT=3005 next dev -p 3006") == [3005, 3006])
check("--port=", WebAppPreview.explicitPorts(in: "astro dev --port=4555") == [4555])
check("config port", WebAppPreview.configPorts(in: "export default defineConfig({ server: { port: 5199 } })") == [5199])

// MARK: Discovery

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("markview-web-preview-\(UUID().uuidString)")
func write(_ path: String, _ text: String) {
    let url = tmp.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}
write("package.json", #"{"name":"lib","scripts":{"build":"tsc","start":"node cli.js"},"dependencies":{"chalk":"5"}}"#)
write("apps/site/package.json", #"{"scripts":{"dev":"vite --port 4100"},"devDependencies":{"vite":"5"}}"#)
write("apps/site/pnpm-lock.yaml", "")
write("web/package.json", #"{"scripts":{"dev":"next dev"},"dependencies":{"next":"14","react":"18"}}"#)
write("web/vite.config.ts", "")
write("server/manage.py", "")
write("docs/notes/a.md", "# A")
write("notes-free/x.txt", "x")
let targets = WebAppPreview.targets(root: tmp)
check("library package skipped", !targets.contains { $0.folder.standardizedFileURL == tmp.standardizedFileURL }, "\(targets.map(\.label))")
let site = targets.first { $0.label == "apps/site" }
check("nested vite app", site?.command == "pnpm run dev" && site?.ports.first == 4100, "\(String(describing: site))")
let web = targets.first { $0.label == "web" }
check("next app", web?.command == "npm run dev" && web?.ports.contains(3000) == true, "\(String(describing: web))")
check("django app", targets.contains { $0.label == "server" && $0.command.contains("manage.py runserver") })

// MARK: Electron apps run as web only

WebAppPreview.webOnlyLauncher = URL(fileURLWithPath: "/Applications/Mark View.app/Contents/Resources/Editor/vendor/js/markview-web-only.mjs")
write("desk-ev/package.json", #"{"scripts":{"dev":"electron-vite dev","start":"electron-vite preview","typecheck:web":"tsc --noEmit"},"devDependencies":{"electron":"31","electron-vite":"2","vite":"5"}}"#)
write("desk-ev/electron.vite.config.ts", "export default { renderer: { server: { port: 5300 } } }")
write("desk-script/package.json", #"{"scripts":{"dev":"concurrently \"vite\" \"wait-on tcp:5173 && electron .\"","dev:renderer":"vite --port 4300"},"devDependencies":{"electron":"31","vite":"5"}}"#)
write("desk-vpe/package.json", #"{"scripts":{"dev":"vite"},"devDependencies":{"electron":"31","vite":"5","vite-plugin-electron":"0.28"}}"#)
write("desk-vpe/vite.config.ts", "export default {}")
write("desk-forge/package.json", #"{"scripts":{"start":"electron-forge start"},"devDependencies":{"electron":"31","@electron-forge/cli":"7"}}"#)
write("desk-forge/vite.renderer.config.mts", "export default {}")
write("desk-none/package.json", #"{"scripts":{"start":"electron ."},"devDependencies":{"electron":"31"}}"#)
let electronTargets = WebAppPreview.targets(root: tmp)
let ev = electronTargets.first { $0.label.hasPrefix("desk-ev") }
check("electron-vite: renderer through the launcher, quoted", ev?.command == "node '/Applications/Mark View.app/Contents/Resources/Editor/vendor/js/markview-web-only.mjs' electron-vite" && ev?.isElectron == true && ev?.label == "desk-ev (web only)" && ev?.ports.first == 5300, "\(String(describing: ev))")
let scripted = electronTargets.first { $0.label.hasPrefix("desk-script") }
check("a web-only script is used as is", scripted?.command == "npm run dev:renderer" && scripted?.ports.first == 4300 && scripted?.isElectron == true, "\(String(describing: scripted))")
let vpe = electronTargets.first { $0.label.hasPrefix("desk-vpe") }
check("vite-plugin-electron: its Vite config without Electron", vpe?.command.hasSuffix("markview-web-only.mjs' vite vite.config.ts") == true, "\(String(describing: vpe))")
let forge = electronTargets.first { $0.label.hasPrefix("desk-forge") }
check("Forge: the renderer config", forge?.command.hasSuffix(" vite vite.renderer.config.mts") == true, "\(String(describing: forge))")
check("Electron without a web part is not offered", !electronTargets.contains { $0.label.hasPrefix("desk-none") })
check("Electron commands never run Electron", electronTargets.filter(\.isElectron).allSatisfy { !$0.command.contains("electron-vite dev") && !$0.command.contains("electron .") })
check("web-only scripts", WebAppPreview.servesWebOnly("vite") && WebAppPreview.servesWebOnly("vite --port 3000") && WebAppPreview.servesWebOnly("cross-env NODE_ENV=development webpack serve --config x.js")
      && !WebAppPreview.servesWebOnly("vite build") && !WebAppPreview.servesWebOnly("electron-vite dev") && !WebAppPreview.servesWebOnly("wait-on tcp:3000 && electron .")
      && !WebAppPreview.servesWebOnly("tsc --noEmit -p tsconfig.web.json"))
check("shell quoting", WebAppPreview.shellQuoted("dev:web") == "dev:web" && WebAppPreview.shellQuoted("it's") == "'it'\\''s'")

// MARK: Web clip

let folders = WebClip.suggestedFolders(root: tmp)
check("research first", folders.first == "docs/research", "\(folders)")
check("existing docs/notes offered", folders.contains("docs/notes"), "\(folders)")
check("folder without Markdown not offered", !folders.contains("notes-free"), "\(folders)")
check("file name", WebClip.fileName(title: "Vite: Getting Started!", url: nil, date: "2026-10-01") == "2026-10-01-vite-getting-started.md")
check("file name from host", WebClip.fileName(title: "", url: URL(string: "http://localhost:5173/"), date: "2026-10-01") == "2026-10-01-localhost.md")
check("sanitized name", WebClip.sanitizedName("../a/b") == "-a-b.md" && WebClip.sanitizedName("  ") == nil && WebClip.sanitizedName("x.md") == "x.md")
let taken: Set<String> = ["a.md", "a-2.md"]
check("free name", WebClip.freeURL(in: tmp, name: "a.md") { taken.contains($0.lastPathComponent) }.lastPathComponent == "a-3.md")
check("inside project", WebClip.isInside(tmp.appendingPathComponent("docs"), root: tmp) && !WebClip.isInside(tmp.deletingLastPathComponent(), root: tmp))
let capture = PageCapture(title: "Guide", url: URL(string: "https://example.com/guide"), markdown: "Some **text**.", hasSelection: true)
let doc = WebClip.document(capture, mode: .selection, title: "Guide", date: "2026-10-01")
check("clip front matter", doc.hasPrefix("---\n") && doc.contains("source: https://example.com/guide") && doc.contains("type: web-clip"), doc)
check("excerpt gets a title and source", doc.contains("# Guide\n\n> Excerpt — [example.com](https://example.com/guide)\n\nSome **text**."), doc)

// MARK: Address field

check("localhost over http", BrowserAddress.url(from: "localhost:5173")?.absoluteString == "http://localhost:5173")
check("host over https", BrowserAddress.url(from: "example.com/docs")?.absoluteString == "https://example.com/docs")
check("full url kept", BrowserAddress.url(from: "http://192.168.1.4:8080/x")?.absoluteString == "http://192.168.1.4:8080/x")
check("words search", BrowserAddress.url(from: "swift concurrency")?.host == "duckduckgo.com")
check("private address is local", BrowserAddress.isLocal("10.0.0.5") && BrowserAddress.isLocal("172.20.1.1") && !BrowserAddress.isLocal("8.8.8.8"))

try? fm.removeItem(at: tmp)
// MARK: Terminal browser bridge

check("request parsed", TerminalBrowserBridge.parse("7C9A1E2B-0000-4000-8000-000000000001\nhttp://localhost:5173/\n")?.url.absoluteString == "http://localhost:5173/")
check("other schemes refused", TerminalBrowserBridge.parse("x\njavascript:alert(1)") == nil
      && TerminalBrowserBridge.parse("x\nnotes.md") == nil && TerminalBrowserBridge.parse("x\n") == nil)
check("file URL parsed as a file", TerminalBrowserBridge.parse("x\nfile:///tmp/a%20b/../r.md\n")?.url.path == "/tmp/r.md")
check("absolute path parsed as a file", TerminalBrowserBridge.parse("x\n/tmp/report.html\n")?.url.isFileURL == true)

let routes = fm.temporaryDirectory.appendingPathComponent("markview-routes-\(UUID().uuidString)")
try! fm.createDirectory(at: routes, withIntermediateDirectories: true)
for name in ["page.html", "notes.md", "data.json", "photo.png", "book.pdf", "tool.bin"] {
    try! "x".write(to: routes.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
check("HTML opens in the browser tab", TerminalBrowserBridge.destination(of: routes.appendingPathComponent("page.html")) == .browserTab)
check("documents open in the editor", ["notes.md", "data.json", "photo.png"].allSatisfy {
    TerminalBrowserBridge.destination(of: routes.appendingPathComponent($0)) == .editor })
check("other files, folders and missing paths go to macOS", ["book.pdf", "tool.bin", "missing.md", ""].allSatisfy {
    TerminalBrowserBridge.destination(of: routes.appendingPathComponent($0)) == .system })
try? fm.removeItem(at: routes)

func run(_ arguments: [String], environment: [String: String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

let bridge = fm.temporaryDirectory.appendingPathComponent("markview-bridge-\(UUID().uuidString)")
let bin = bridge.appendingPathComponent("bin"), zdot = bridge.appendingPathComponent("zsh")
let spool = bridge.appendingPathComponent("spool"), home = bridge.appendingPathComponent("home")
for folder in [bin, zdot, spool, home] { try! fm.createDirectory(at: folder, withIntermediateDirectories: true) }
MainActor.assumeIsolated {
    try! TerminalBrowserBridge.Scripts.browser.write(to: bin.appendingPathComponent("markview-browser"), atomically: true, encoding: .utf8)
    try! TerminalBrowserBridge.Scripts.open.write(to: bin.appendingPathComponent("open"), atomically: true, encoding: .utf8)
    for (name, text) in TerminalBrowserBridge.Scripts.zshFiles {
        try! text.write(to: zdot.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
for name in ["markview-browser", "open"] {
    try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.appendingPathComponent(name).path)
}
// The user's startup files put the system folders first, as path_helper does.
try! "export PATH=/usr/bin:/bin:$PATH\nexport MV_USER_RC=1\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
try! "export PATH=/usr/bin:$PATH\n".write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
let env = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin", "ZDOTDIR": zdot.path, "MARKVIEW_BIN": bin.path,
           "MARKVIEW_BROWSER_SPOOL": spool.path, "MARKVIEW_TERMINAL_ID": "7C9A1E2B-0000-4000-8000-000000000001",
           "BROWSER": bin.appendingPathComponent("markview-browser").path, "TERM": "dumb"]
let shellOut = run(["/bin/zsh", "-l", "-i", "-c", "echo \"open=$(command -v open) rc=$MV_USER_RC zdotdir=${ZDOTDIR-unset}\"; open http://localhost:4321/x"], environment: env)
check("wrapper first after the user's rc files", shellOut.contains("open=\(bin.path)/open"), shellOut)
check("user's .zshrc ran", shellOut.contains("rc=1"), shellOut)
check("ZDOTDIR restored for child shells", shellOut.contains("zdotdir=unset"), shellOut)
let requests = (try? fm.contentsOfDirectory(atPath: spool.path)) ?? []
let request = requests.first.flatMap { try? String(contentsOf: spool.appendingPathComponent($0), encoding: .utf8) } ?? ""
check("open URL dropped one request", requests.count == 1 && requests[0].hasSuffix(".url") && request.hasSuffix("http://localhost:4321/x\n"), "\(requests) \(request)")
let passOut = run([bin.appendingPathComponent("open").path, "-R", "/nonexistent-markview-path"], environment: env)
check("other uses go to /usr/bin/open", passOut.contains("does not exist") || passOut.contains("nonexistent"), passOut)
let missingOut = run([bin.appendingPathComponent("open").path, "/nonexistent-markview-notes.md"], environment: env)
check("a missing file goes to /usr/bin/open", missingOut.contains("does not exist") || missingOut.contains("nonexistent"), missingOut)
for name in (try? fm.contentsOfDirectory(atPath: spool.path)) ?? [] { try? fm.removeItem(at: spool.appendingPathComponent(name)) }
try! "# n".write(to: home.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
_ = run(["/bin/zsh", "-l", "-i", "-c", "cd \"$HOME\" && open notes.md"], environment: env)
let fileRequests = (try? fm.contentsOfDirectory(atPath: spool.path)) ?? []
let fileRequest = fileRequests.first.flatMap { try? String(contentsOf: spool.appendingPathComponent($0), encoding: .utf8) } ?? ""
let parsedFile = TerminalBrowserBridge.parse(fileRequest)?.url
check("open FILE drops a request with its absolute path", fileRequests.count == 1
      && parsedFile?.standardizedFileURL.resolvingSymlinksInPath().path == home.appendingPathComponent("notes.md").resolvingSymlinksInPath().path,
      "\(fileRequests) \(fileRequest)")
try? fm.removeItem(at: bridge)


// MARK: Probing a real server

let port = 47_000 + Int.random(in: 0..<2_000)
let server = Process()
server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
server.standardOutput = FileHandle.nullDevice
server.standardError = FileHandle.nullDevice
try! server.run()
var probed: URL?
var probeDone = false
var deadPort: URL?
Task {
    for _ in 0..<40 {
        probed = await WebAppPreview.firstAnswering([port - 1, port])
        if probed != nil { break }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
    deadPort = await WebAppPreview.firstAnswering([port - 1])
    probeDone = true
}
let probeEnd = Date().addingTimeInterval(20)
while !probeDone && Date() < probeEnd { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
server.terminate()
check("answering port found", probed?.absoluteString == "http://localhost:\(port)/", "\(String(describing: probed))")
check("silent port not reported", probeDone && deadPort == nil)

// MARK: Converter in WebKit

func spin(until done: () -> Bool, timeout: TimeInterval = 15) {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
}

let html = """
<html><head><title>Sample Page</title></head><body>
<nav><a href="/">Home</a> <a href="/blog">Blog</a></nav>
<header><h1>Site name</h1></header>
<article>
<h1>Main title</h1>
<p>Intro with <strong>bold</strong>, <em>italic</em>, <code>x = 1</code> and a <a href="/docs/a b">link</a>.</p>
<h2>List</h2>
<ul><li>One</li><li>Two<ul><li>Two A</li></ul></li><li><input type="checkbox" checked> Done</li></ul>
<ol start="3"><li>Third</li><li>Fourth</li></ol>
<pre><code class="language-swift">let a = 1
print(a)</code></pre>
<blockquote><p>Quoted line</p></blockquote>
<table><tr><th>Name</th><th>Value</th></tr><tr><td>a|b</td><td>2</td></tr></table>
<p id="sel">Selected <b>words</b> here.</p>
<img src="/img/logo.png" alt="Logo">
<div style="display:none">hidden text</div>
<script>var secret = 1;</script>
</article>
<footer>Copyright</footer>
</body></html>
"""

MainActor.assumeIsolated {
    BrowserSession.captureScriptURL = URL(fileURLWithPath: "MarkView/Resources/Editor/vendor/js/markview-page-markdown.js")
    let session = BrowserSession(url: nil)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = session.webView
    session.webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/post/")!)
    spin(until: { !session.webView.isLoading && session.title == "Sample Page" })

    func capture(_ mode: PageCapture.Mode) -> PageCapture? {
        var result: PageCapture?
        var done = false
        Task { @MainActor in
            result = try? await session.capture(mode)
            done = true
        }
        spin(until: { done })
        return result
    }

    guard let page = capture(.page) else { check("page captured", false); return }
    let md = page.markdown
    check("page title", page.title == "Sample Page")
    check("article chosen, chrome dropped", md.hasPrefix("# Main title") && !md.contains("Home") && !md.contains("Copyright") && !md.contains("Site name"), md)
    check("inline marks", md.contains("Intro with **bold**, *italic*, `x = 1` and a [link](https://example.com/docs/a%20b)."), md)
    check("nested list", md.contains("- One\n- Two\n  - Two A\n- [x] Done"), md)
    check("ordered list start", md.contains("3. Third\n4. Fourth"), md)
    check("fenced code with language", md.contains("```swift\nlet a = 1\nprint(a)\n```"), md)
    check("blockquote", md.contains("> Quoted line"), md)
    check("table", md.contains("| Name | Value |\n| --- | --- |\n| a\\|b | 2 |"), md)
    check("image absolute", md.contains("![Logo](https://example.com/img/logo.png)"), md)
    check("hidden and script dropped", !md.contains("hidden text") && !md.contains("secret"), md)

    var selected = false
    session.webView.evaluateJavaScript("""
        var r = document.createRange(); r.selectNodeContents(document.getElementById('sel'));
        var s = getSelection(); s.removeAllRanges(); s.addRange(r); true
        """) { _, _ in selected = true }
    spin(until: { selected })
    let excerpt = capture(.selection)
    check("selection", excerpt?.hasSelection == true && excerpt?.markdown == "Selected **words** here.", excerpt?.markdown ?? "nil")
    // The page cannot reach the converter: it lives in the client content world.
    var pageSees: Any?
    var asked = false
    session.webView.evaluateJavaScript("typeof window.markviewPageMarkdown") { value, _ in pageSees = value; asked = true }
    spin(until: { asked })
    check("isolated from the page", (pageSees as? String) == "undefined", "\(String(describing: pageSees))")
}

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all passed")
