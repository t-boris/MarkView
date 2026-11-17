import AppKit
import Foundation
import MarkViewCore
import WebKit
import XCTest
@testable import MarkView

final class TailwindPageLoad: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finished = true }
}

extension EditorHostTests {
    @MainActor func testPrototypeTailwindRendering() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mvtailwind-render-\(UUID().uuidString)")
        let site = work.appendingPathComponent("site")
        defer { try? fm.removeItem(at: work) }
        func write(_ path: String, _ text: String) {
            let url = site.appendingPathComponent(path)
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! text.write(to: url, atomically: true, encoding: .utf8)
        }

        write("original/app/globals.css", """
        @import "tailwindcss";
        @import "./base.css";
        @source '../ui/**/*.tsx';
        @theme {
          --color-canvas: #fff8f4;
          --color-ink: #17202b;
          --color-coral: #d0345a;
          --spacing-sp3: 12px;
          --spacing-sp5: 20px;
          --spacing-sp10: 40px;
        }
        @utility tabular-nums { font-variant-numeric: tabular-nums; }
        """)
        write("original/app/base.css", "button { cursor: pointer; }")
        write("styles.css", "#app { padding: 1px; }")
        write("index.html", """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Tailwind render check</title>
        <link rel="stylesheet" href="original/app/base.css">
        <link rel="stylesheet" href="styles.css">
        </head>
        <body>
        <div id="app">
          <main id="probe" class="flex items-center gap-sp3 mt-sp10 rounded-lg bg-canvas text-ink p-sp5 tabular-nums">Hello</main>
          <span id="late">later</span>
        </div>
        <script>
        window.__errors = [];
        window.addEventListener('error', function (e) { window.__errors.push(String(e.message)); });
        setTimeout(function () { document.getElementById('late').className = 'mt-sp3 bg-coral block'; }, 400);
        </script>
        </body>
        </html>
        """)

        _ = NSApplication.shared
        let page = TailwindPageLoad()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PrototypeSchemeHandler(root: site), forURLScheme: PrototypeSchemeHandler.scheme)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        view.navigationDelegate = page
        defer { view.stopLoading(); view.navigationDelegate = nil }
        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func js(_ source: String) -> Any? {
            var result: Any?, done = false
            view.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { outcome in
                if case .success(let value) = outcome { result = value } else if case .failure(let error) = outcome { result = "ERROR \(error)" }
                done = true
            }
            let deadline = Date().addingTimeInterval(30)
            while !done && Date() < deadline { spin(0.05) }
            return result
        }
        func style(_ id: String, _ property: String) -> String { js("return getComputedStyle(document.getElementById('\(id)')).\(property)") as? String ?? "?" }
        func open() {
            page.finished = false
            view.load(URLRequest(url: PrototypeSchemeHandler.address(of: "index.html")!))
            let deadline = Date().addingTimeInterval(15)
            while !page.finished && Date() < deadline { spin(0.05) }
            spin(1.5)
        }

        // Without Tailwind the utility classes have no rule: the control that shows the check can fail.
        open()
        check(page.finished, "the page loads")
        check(style("probe", "display") == "block" && style("probe", "marginTop") == "0px", "before: the classes have no rule (display \(style("probe", "display")), margin-top \(style("probe", "marginTop")))")

        // MarkView adds Tailwind, with the browser build the app ships.
        let vendorURL = try XCTUnwrap(Bundle.main.url(forResource: "tailwind-browser", withExtension: "js", subdirectory: "Editor/vendor/js"))
        let vendor = try Data(contentsOf: vendorURL)
        check((try? PrototypeTailwind.ensure(site: site, vendor: { vendor })) == .applied, "ensure adds Tailwind to the site")
        open()
        check(style("probe", "display") == "flex", "after: flex is a rule (display \(style("probe", "display")))")
        check(style("probe", "marginTop") == "40px", "the theme's spacing names work: mt-sp10 is \(style("probe", "marginTop"))")
        check(style("probe", "paddingTop") == "20px" && style("probe", "columnGap") == "12px", "padding and gap come from the theme: \(style("probe", "paddingTop")), \(style("probe", "columnGap"))")
        check(style("probe", "backgroundColor") == "rgb(255, 248, 244)", "bg-canvas takes the theme's colour: \(style("probe", "backgroundColor"))")
        check(style("probe", "color") == "rgb(23, 32, 43)", "text-ink takes the theme's colour: \(style("probe", "color"))")
        check(style("probe", "borderTopLeftRadius") != "0px", "rounded-lg rounds the corners: \(style("probe", "borderTopLeftRadius"))")
        check(style("probe", "fontVariantNumeric") == "tabular-nums", "an @utility of the source is a rule: \(style("probe", "fontVariantNumeric"))")
        check(style("late", "marginTop") == "12px" && style("late", "backgroundColor") == "rgb(208, 52, 90)",
              "a class the page adds later is compiled too: \(style("late", "marginTop")), \(style("late", "backgroundColor"))")
        check(style("app", "paddingTop") == "1px", "the prototype's own styles.css still applies")
        check((js("return window.__errors.length") as? Int) == 0, "the page raised no error: \(String(describing: js("return window.__errors.join(' | ')")))")
    }
}

final class PrototypeSchemePage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var messages: [String] = []
    var finished = false
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { messages.append("\(m.body)") }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finished = true }
}


extension EditorHostTests {
    @MainActor func testPrototypeSchemePathsAndErrors() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mvproto-tests-\(UUID().uuidString)")
        let site = work.appendingPathComponent("site")
        func write(_ path: String, _ text: String) {
            let url = site.appendingPathComponent(path)
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! text.write(to: url, atomically: true, encoding: .utf8)
        }
        defer { try? fm.removeItem(at: work) }

        write("index.html", """
        <!doctype html><html><head><meta charset="utf-8"></head><body><div id="app"></div>
        <script src="data.js"></script>
        <script src="app.js"></script>
        <script src="screens/home.js"></script>
        <script src="screens/broken.js"></script>
        <script>App.start()</script>
        </body></html>
        """)
        write("data.js", "var DB = {items:[1,2,3]};")
        write("app.js", "var App = {screens:[], register:function(s){this.screens.push(s)}, start:function(){document.getElementById('app').textContent='started '+this.screens.length}};")
        write("screens/home.js", "App.register({id:'home'});")
        write("screens/broken.js", "App.register({id:'broken'});\nundefinedFunction();\n")
        write("components/card.html", "<!doctype html><title>card</title>")
        write("my file.js", "window.spaced = true;")
        write("data.json", "{\"ok\":true}")
        write("fetcher.html", """
        <!doctype html><html><body><script>
        fetch('data.json').then(r => r.json()).then(j => window.webkit.messageHandlers.mvError.postMessage('FETCHED ' + j.ok))
          .catch(e => window.webkit.messageHandlers.mvError.postMessage('FETCH FAILED ' + e));
        </script></body></html>
        """)
        let secret = work.appendingPathComponent("secret.txt")
        try! "secret".write(to: secret, atomically: true, encoding: .utf8)
        try! fm.createSymbolicLink(at: site.appendingPathComponent("escape.txt"), withDestinationURL: secret)
        try! fm.createSymbolicLink(at: site.appendingPathComponent("inside.js"), withDestinationURL: site.appendingPathComponent("data.js"))

        // MARK: Path rules

        func file(_ path: String) -> String? {
            if case .file(let url) = PrototypeSchemeHandler.lookup(path: path, in: site) { return url.lastPathComponent }
            return nil
        }
        check(file("/") == "index.html", "root serves index.html")
        check(file("") == "index.html", "empty path serves index.html")
        check(file("/index.html") == "index.html", "index.html by name")
        check(file("/screens/broken.js") == "broken.js", "screen script")
        check(file("/components/card.html") == "card.html", "component page")
        check(file("/my%20file.js") == "my file.js", "percent-encoded name")
        check(file("/inside.js") == "data.js", "symlink that stays inside is served")
        check(PrototypeSchemeHandler.lookup(path: "/../secret.txt", in: site) == .forbidden, "parent traversal is forbidden")
        check(PrototypeSchemeHandler.lookup(path: "/%2e%2e/secret.txt", in: site) == .forbidden, "encoded parent traversal is forbidden")
        check(PrototypeSchemeHandler.lookup(path: "/screens/../app.js", in: site) == .forbidden, "inner .. is forbidden")
        check(PrototypeSchemeHandler.lookup(path: "/escape.txt", in: site) == .forbidden, "symlink out of the site is forbidden")
        check(PrototypeSchemeHandler.lookup(path: "/a%00b", in: site) == .forbidden, "NUL byte is forbidden")
        check(PrototypeSchemeHandler.lookup(path: "/nope.js", in: site) == .missing, "missing file")
        check(PrototypeSchemeHandler.lookup(path: "/screens", in: site) == .missing, "directory without index.html")
        check(PrototypeSchemeHandler.address(of: "index.html")?.absoluteString == "mvproto://site/index.html", "address of the index")
        check(PrototypeSchemeHandler.address(of: "components/card.html", fragment: "#home")?.absoluteString
              == "mvproto://site/components/card.html#home", "address with a fragment")
        check(PrototypeSchemeHandler.address(of: "my file.js")?.absoluteString == "mvproto://site/my%20file.js", "address encodes a space")
        check(PrototypeSchemeHandler.contentType(of: URL(fileURLWithPath: "/a/app.js")) == "text/javascript; charset=utf-8", "js type")
        check(PrototypeSchemeHandler.contentType(of: URL(fileURLWithPath: "/a/index.html")) == "text/html; charset=utf-8", "html type")
        check(PrototypeSchemeHandler.contentType(of: URL(fileURLWithPath: "/a/styles.css")) == "text/css; charset=utf-8", "css type")
        check(PrototypeSchemeHandler.contentType(of: URL(fileURLWithPath: "/a/logo.png")) == "image/png", "png type")
        check(PrototypeSchemeHandler.contentType(of: URL(fileURLWithPath: "/a/x.zzzunknown")) == "application/octet-stream", "unknown type")

        // MARK: End to end in WebKit

        let viewSourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MarkView/Views/Prototype/PrototypeStudioView.swift")
        let viewSource = try String(contentsOf: viewSourceURL, encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"(?s)( *window\.addEventListener\('error'.*?\n *\}\);)"#)
        let sourceRange = NSRange(viewSource.startIndex..., in: viewSource)
        let match = try XCTUnwrap(expression.firstMatch(in: viewSource, range: sourceRange))
        let listener = (viewSource as NSString).substring(with: match.range(at: 1)).replacingOccurrences(of: #"\\"#, with: #"\"#)
        check(listener.contains("addEventListener('error'"), "the preview's error listener was extracted")

        _ = NSApplication.shared
        let handler = PrototypeSchemeHandler(root: site)

        func run(_ name: String, settle: TimeInterval = 1.0, _ load: (WKWebView) -> Void) -> [String] {
            let page = PrototypeSchemePage()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(handler, forURLScheme: PrototypeSchemeHandler.scheme)
            configuration.userContentController.add(page, name: "mvError")
            configuration.userContentController.addUserScript(WKUserScript(source: listener, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            view.navigationDelegate = page
            defer { view.stopLoading(); view.navigationDelegate = nil; configuration.userContentController.removeScriptMessageHandler(forName: "mvError") }
            load(view)
            let deadline = Date().addingTimeInterval(15)
            while !page.finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            RunLoop.current.run(until: Date().addingTimeInterval(settle))
            check(page.finished, "\(name): page finished loading")
            return page.messages
        }

        let served = run("scheme") { $0.load(URLRequest(url: PrototypeSchemeHandler.address(of: "index.html")!)) }
        print("     reported through mvproto://: \(served)")
        check(served.count == 1, "one error reported through the scheme")
        check(served.first?.contains("undefinedFunction") == true, "the real error text arrives, not 'Script error.'")
        check(served.first?.contains("screens/broken.js:2") == true, "the error names the screen file and line")

        let fetched = run("fetch") { $0.load(URLRequest(url: PrototypeSchemeHandler.address(of: "fetcher.html")!)) }
        check(fetched == ["FETCHED true"], "a page can fetch its own data file")

        let baseline = run("file") { $0.loadFileURL(site.appendingPathComponent("index.html"), allowingReadAccessTo: site) }
        print("     reported through file:// (the old way): \(baseline)")
        check(baseline.first?.contains("undefinedFunction") == false, "baseline: file:// hides the text (the cause of BUG-047)")
    }
}
