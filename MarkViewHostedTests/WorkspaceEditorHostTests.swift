import AppKit
import Combine
import MarkViewCore
import SwiftUI
import WebKit
import XCTest
@testable import MarkView

extension EditorHostTests {
    @MainActor func testDataViewersWithRealSchemeHandler() throws {
        let editor = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent().path
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/tests/fixtures/data", isDirectory: true).standardizedFileURL.path
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, "\(message): \(detail.prefix(400))", line: line)
        }
        final class Bridge: NSObject, WKScriptMessageHandler {
            var messages: [[String: Any]] = []
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                if let body = message.body as? [String: Any] { messages.append(body) }
            }
        }
        final class Loaded: NSObject, WKNavigationDelegate {
            var done = false
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        }

        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        let handler = DataFileSchemeHandler()
        handler.isAllowed = { $0.standardizedFileURL.path.hasPrefix(fixtures + "/") }
        config.setURLSchemeHandler(handler, forURLScheme: "markview-data")
        let bridge = Bridge()
        config.userContentController.add(bridge, name: "bridge")
        config.userContentController.addUserScript(try BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json")).userScript)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = web
        defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "bridge"); window.close() }
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

        func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }

        /// Run `body` (an async function body) in the page and return its string result.
        func js(_ body: String, timeout: TimeInterval = 20) -> String {
            var out: String?
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): out = value as? String ?? "\(String(describing: value))"
                case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
                }
            }
            spin(timeout) { out != nil }
            return out ?? "TIMEOUT"
        }

        /// Open a fixture in the data viewer and wait until its grid or log is shown.
        func open(_ name: String, _ kind: String) -> String {
            let src = "markview-data://" + fixtures + "/" + name
            return js("""
            window.setDataContent({ src: \(String(reflecting: src)), kind: '\(kind)', name: '\(name)', reload: false });
            const c = document.getElementById('data-container');
            for (let i = 0; i < 200; i++) {
              if (c.querySelector('.dv-grid tbody tr[data-row], .dv-log .ln[data-pos], .dv-msg.error:not(:empty)')) break;
              await new Promise(r => setTimeout(r, 50));
            }
            return c.innerText;
            """)
        }

        spin(15) { loaded.done }
        check(js("return typeof window.setDataContent") == "function", "the data viewers are on the page")

        var text = open("plants.csv", "table")
        check(text.contains("40 rows") && text.contains("height_cm") && text.contains("Basil"), "CSV: rows and header", text)
        text = js("""
        const c = document.getElementById('data-container');
        c.querySelector('.dv-sqlbtn').click();
        c.querySelector('.dv-sql textarea').value = 'SELECT plant, COUNT(*) AS n FROM data GROUP BY plant ORDER BY plant';
        c.querySelector('.dv-run').click();
        await new Promise(r => setTimeout(r, 300));
        return c.querySelector('.dv-grid').innerText;
        """)
        check(text.contains("Basil\t10") && text.contains("Tomato\t10"), "CSV: SQL with GROUP BY", text)
        _ = open("plants.csv", "table")
        text = js("""
        const c = document.getElementById('data-container');
        const input = c.querySelectorAll('thead input')[2]; input.value = '>45'; input.dispatchEvent(new Event('change'));
        await new Promise(r => setTimeout(r, 200));
        c.querySelectorAll('thead tr:first-child th[data-col]')[2].click(); await new Promise(r => setTimeout(r, 200));
        c.querySelectorAll('thead tr:first-child th[data-col]')[2].click(); await new Promise(r => setTimeout(r, 200));
        return c.querySelector('.dv-count').textContent + '|' + c.querySelector('tbody tr[data-row] td:nth-child(4)').textContent;
        """)
        check(text.hasPrefix("5 rows") && text.hasSuffix("|50"), "CSV: numeric filter >45 and descending sort", text)
        text = js("""
        const c = document.getElementById('data-container');
        c.querySelectorAll('thead tr:first-child th[data-col]')[2].click();
        await new Promise(r => setTimeout(r, 200));
        c.querySelector('.dv-stats').click();
        return c.querySelector('.dv-side').innerText;
        """)
        check(text.contains("Distinct") && text.contains("Max"), "CSV: column statistics", text)

        text = open("plants.tsv", "table")
        check(text.contains("5 rows") && text.contains("Mint"), "TSV", text)
        text = open("events.jsonl", "table")
        check(text.contains("meta.h") && text.contains("6 rows"), "JSON Lines: nested objects become dotted columns", text)
        text = open("plants.parquet", "parquet")
        check(text.contains("40 rows") && text.contains("Rosemary"), "Parquet (snappy)", text)
        text = open("plants-zstd.parquet", "parquet")
        check(text.contains("40 rows") && text.contains("Rosemary"), "Parquet (zstd)", text)
        text = open("garden.sqlite", "sqlite")
        check(text.contains("40 rows") && text.contains("height_cm"), "SQLite: first table", text)
        text = js("""
        const c = document.getElementById('data-container');
        const s = c.querySelector('.dv-table'); s.value = 'tall'; s.dispatchEvent(new Event('change'));
        await new Promise(r => setTimeout(r, 200));
        return c.querySelector('.dv-count').textContent;
        """)
        check(text.hasPrefix("10 rows"), "SQLite: a view from the table list", text)
        text = open("garden.xlsx", "table")
        check(text.contains("2026-03-01") && text.contains("Basil") && text.contains("2 sheets"), "Excel: first sheet, dates read", text)
        text = open("session.har", "table")
        check(text.contains("GET") && text.contains("https://garden.example/api/plants") && text.contains("200"), "HAR: one row per request", text)

        text = open("plants.feather", "table")
        check(text.contains("3 rows") && text.contains("Kale") && text.contains("71.2"), "Arrow IPC / Feather", text)
        text = open("plants.avro", "table")
        check(text.contains("3 rows") && text.contains("Mint") && text.contains("2026-03-02") && text.contains("VEG") && text.contains("-3"),
              "Avro (null codec): records, enum, union, negative long, date", text)
        text = open("plants-deflate.avro", "table")
        check(text.contains("3 rows") && text.contains("spreads") && text.contains("[\"shade\",\"wet\"]"), "Avro (deflate codec): arrays and unions", text)
        text = open("readings-snappy.avro", "table")
        check(text.contains("2 rows") && text.contains("labels.bed") && text.contains("north") && text.contains("12.34") && text.contains("-2.5")
              && text.contains("2026-10-05T00:01:00.000Z"), "Avro (snappy codec): map, decimal, timestamp", text)
        text = open("harvest.ods", "table")
        check(text.contains("3 rows") && text.contains("Tomato") && text.contains("2026-08-01") && text.contains("Pepper"),
              "OpenDocument spreadsheet: repeated rows expanded, a million empty rows ignored", text)

        text = open("app.log", "log")
        check(text.contains("Error3") && text.contains("Warn1"), "Log: levels counted (stack trace and JSON line are errors)", text)
        text = js("""
        const c = document.getElementById('data-container');
        const q = c.querySelector('.dv-q'); q.value = 'water'; q.dispatchEvent(new Event('input'));
        await new Promise(r => setTimeout(r, 400));
        c.querySelector('.dv-only').click();
        await new Promise(r => setTimeout(r, 100));
        return c.querySelector('.dv-mcount').textContent + '|' + c.querySelector('.dv-log').innerText;
        """)
        check(text.contains("failed to water") && !text.contains("slow disk"), "Log: search with only matching lines", text)

        // JSON / YAML editing in the tree
        let edit = """
        const nodes = () => [...DOM.rendered.querySelectorAll('.struct-node[data-path]')];
        const at = (p) => nodes().find(n => n.dataset.path === JSON.stringify(p));
        at(['version']).querySelector('.struct-value').dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
        let input = DOM.rendered.querySelector('.struct-inline-input'); input.value = '2';
        input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
        await new Promise(r => setTimeout(r, 400));
        at(['name']).querySelector('.struct-key').dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
        input = DOM.rendered.querySelector('.struct-inline-input'); input.value = 'title';
        input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
        await new Promise(r => setTimeout(r, 400));
        at(['plants', 0]).querySelector('.struct-act[data-act=delete]').click();
        await new Promise(r => setTimeout(r, 400));
        return DOM.editor.value;
        """
        func structured(_ name: String, _ type: String) {
            let content = try! String(contentsOfFile: fixtures + "/" + name, encoding: .utf8)
            let literal = String(data: try! JSONSerialization.data(withJSONObject: [content]), encoding: .utf8)!
            _ = js("window.setStructuredContent(\(literal)[0], '\(type)'); return 'ok';")
        }
        structured("config.json", "json")
        text = js(edit)
        check(text == "{\n    \"title\": \"garden\",\n    \"version\": 2,\n    \"plants\": [\n        \"mint\"\n    ]\n}\n",
              "JSON: edit a value, rename a key, delete an item; indentation kept", text)
        structured("config.yaml", "yaml")
        text = js(edit)
        check(text.hasPrefix("# Garden config\ntitle: garden") && text.contains("# the project") && text.contains("version: 2") && !text.contains("basil"),
              "YAML: the same edits keep the comments", text)
        structured("config.json", "json")
        text = js("""
        toggleStructMode();
        const ok = document.getElementById('struct-source-status').textContent;
        DOM.editor.value = '{ "broken": '; DOM.editor.dispatchEvent(new Event('input'));
        await new Promise(r => setTimeout(r, 400));
        return ok + '|' + document.getElementById('struct-source-status').className;
        """)
        check(text == "Valid JSON|struct-source-status bad", "JSON: the source view checks the syntax as you type", text)

        // All text-file viewers use the same Explain request and line-aligned notes.
        bridge.messages.removeAll()
        structured("config.yaml", "yaml")
        _ = js("document.querySelector('.doc-explain-btn').click(); return 'ok';")
        spin(0.2)
        var request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
        check(request?["action"] as? String == "notesView" && request?["show"] as? Bool == true && request?["explain"] as? Bool == true,
              "YAML: Explain requests its own source notes and starts AI")
        text = js("""
        window.setCodeContent('server:\\n  port: 8080\\ndatabase:\\n  pool: 5', 'yaml', 'config.yaml', 'Viewer');
        for (let i = 0; i < 100 && !document.querySelector('.code-main .cm-content'); i++) await new Promise(r => setTimeout(r, 30));
        window.setCodeNotes({ explanation: { summary: 'Service settings', sections: [
          { startLine: 1, endLine: 2, title: 'HTTP listener', explanation: 'Sets the server port.', importance: 'high' },
          { startLine: 3, endLine: 4, title: 'Database pool', explanation: 'Sets the connection pool size.', importance: 'normal' }
        ] }, filters: [] });
        await new Promise(r => setTimeout(r, 150));
        return [document.getElementById('status-mode').textContent, document.querySelector('.code-document-btn').textContent,
                document.querySelector('.code-edit-btn').hidden, document.querySelector('.code-notes-track').textContent,
                document.querySelectorAll('.code-main .cm-line').length].join('|');
        """)
        check(text.contains("YAML|← Viewer|true") && text.contains("HTTP listener") && text.contains("Database pool") && text.hasSuffix("|4"),
              "YAML: highlighted source, line-aligned section notes and return to viewer", text)
        text = js("""
        document.querySelector('.code-notes-close').click();
        const hiddenBefore = document.querySelector('.code-notes').hidden;
        window.explainCurrentFile();
        window.setCodeContent('server: 8080', 'yaml', 'reopened.yaml', 'Viewer');
        window.setCodeNotes({ explanation: { summary: 'Server settings', sections: [
          { startLine: 1, endLine: 1, title: 'Server', explanation: 'Port setting.', importance: 'normal' }
        ] }, filters: [] });
        return hiddenBefore + '|' + document.querySelector('.code-notes').hidden;
        """)
        check(text == "true|false", "Explain from source/data reopens notes after they were hidden", text)
        bridge.messages.removeAll()
        _ = js("document.querySelector('.code-document-btn').click(); return 'ok';")
        spin(0.1)
        request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
        check(request?["action"] as? String == "notesView" && request?["show"] as? Bool == false, "notes return to the dedicated viewer")
        text = js("""
        window.setCodeContent('# just text\\nkey=value', '', 'anything.mystery');
        await new Promise(r => setTimeout(r, 150));
        return [document.getElementById('status-mode').textContent, document.querySelector('.code-main .cm-content').textContent,
                document.querySelector('.code-edit-btn').hidden, document.querySelector('.code-document-btn').hidden].join('|');
        """)
        check(text.hasPrefix("TEXT|# just textkey=value|false|true"), "unknown files are plain editable text with Explain", text)
        bridge.messages.removeAll()
        _ = js("document.querySelector('.code-main .code-explain-btn').click(); return 'ok';")
        spin(0.1)
        request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
        check(request?["action"] as? String == "explain", "plain text Explain reaches the shared AI action")
        structured("config.json", "json")
        _ = js("toggleStructMode(); document.querySelector('#editor-pane .code-explain-btn').click(); return 'ok';")
        spin(0.1)
        request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
        check(request?["action"] as? String == "notesView" && request?["explain"] as? Bool == true, "structured source mode also exposes Explain")
        _ = open("plants.csv", "table")
        bridge.messages.removeAll()
        text = js("const b = document.querySelector('.dv-explain'); if (b) b.click(); return String(!!b);")
        spin(0.1)
        request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
        check(text == "true" && request?["explain"] as? Bool == true, "CSV: Explain opens the original textual source")
        _ = open("app.log", "log")
        check(js("return String(!!document.querySelector('.dv-explain'))") == "true", "logs expose Explain")
        _ = open("plants.parquet", "parquet")
        check(js("return String(!!document.querySelector('.dv-explain'))") == "false", "binary data is not offered as textual source")

    }
}


extension EditorHostTests {
    func testEditorDocumentRouting() {
        func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition(), message, line: line)
        }
        let sirius = UUID(), myDataCenter = UUID(), daily = UUID()
        let tabs = [sirius, myDataCenter, daily]

        // The reported case: the page still holds the MyDataCenter document while the Sirius Art tab is selected.
        check(EditorDocumentRouting.targetIndex(documentID: myDataCenter, tabIDs: tabs, activeIndex: 0) == 1,
              "a message naming a document goes to that document's tab, not to the selected one")
        check(EditorDocumentRouting.targetIndex(documentID: sirius, tabIDs: tabs, activeIndex: 2) == 0,
              "naming the first tab while the last is selected still reaches the first tab")

        // Reordering tabs changes indexes, never ids.
        let reordered = [daily, sirius, myDataCenter]
        check(EditorDocumentRouting.targetIndex(documentID: myDataCenter, tabIDs: reordered, activeIndex: 1) == 2,
              "a reordered tab list is followed by id")

        // A closed tab must not hand its text to another tab.
        check(EditorDocumentRouting.targetIndex(documentID: myDataCenter, tabIDs: [sirius, daily], activeIndex: 0) == nil,
              "a message for a closed tab is dropped instead of falling back to the selected tab")

        // Messages that name no document keep the earlier behaviour.
        check(EditorDocumentRouting.targetIndex(documentID: nil, tabIDs: tabs, activeIndex: 1) == 1,
              "an unnamed message applies to the selected tab")
        check(EditorDocumentRouting.targetIndex(documentID: nil, tabIDs: tabs, activeIndex: -1) == nil,
              "no selected tab: nothing to apply to")
        check(EditorDocumentRouting.targetIndex(documentID: nil, tabIDs: tabs, activeIndex: 3) == nil,
              "selected index past the end: nothing to apply to")
        check(EditorDocumentRouting.targetIndex(documentID: nil, tabIDs: [], activeIndex: 0) == nil,
              "no tabs: nothing to apply to")
        check(EditorDocumentRouting.targetIndex(documentID: myDataCenter, tabIDs: [], activeIndex: 0) == nil,
              "no tabs: a named message is dropped")

        // BUG-043: text of a document the page was just switched away from must not pass for the shown document's text.
        check(EditorDocumentRouting.reportsShownDocument(documentID: myDataCenter, shown: myDataCenter),
              "text of the document on screen is remembered by the reload check")
        check(!EditorDocumentRouting.reportsShownDocument(documentID: sirius, shown: myDataCenter),
              "unsaved text of the document left behind is not remembered as the one on screen")
        check(!EditorDocumentRouting.reportsShownDocument(documentID: sirius, shown: nil),
              "a named message while no tab's document is shown is not remembered")
        check(EditorDocumentRouting.reportsShownDocument(documentID: nil, shown: myDataCenter),
              "an unnamed message is remembered, as before")
        check(EditorDocumentRouting.reportsShownDocument(documentID: nil, shown: nil),
              "an unnamed message with nothing shown is remembered, as before")

        // What the page sends.
        check(EditorDocumentRouting.documentID(from: sirius.uuidString) == sirius, "a valid id is parsed")
        check(EditorDocumentRouting.documentID(from: sirius.uuidString.lowercased()) == sirius, "a lowercase id is parsed")
        check(EditorDocumentRouting.documentID(from: "") == nil, "an empty id means not named")
        check(EditorDocumentRouting.documentID(from: "not-a-uuid") == nil, "a malformed id means not named")
        check(EditorDocumentRouting.documentID(from: nil) == nil, "a missing id means not named")
        check(EditorDocumentRouting.documentID(from: 42) == nil, "a non-string id means not named")

    }

    @MainActor func testEditorMessagesCarryDocumentIdentity() throws {
        let editor = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent().path
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, "\(message): \(detail.prefix(600))", line: line)
        }
        struct Message { let type: String; let doc: String; let payload: [String: Any] }
        final class Bridge: NSObject, WKScriptMessageHandler {
            var messages: [Message] = []
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
                messages.append(Message(type: type, doc: body["doc"] as? String ?? "<missing>", payload: body["payload"] as? [String: Any] ?? [:]))
            }
        }
        final class Loaded: NSObject, WKNavigationDelegate {
            var done = false
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        }

        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        let bridge = Bridge()
        config.userContentController.add(bridge, name: "bridge")
        config.userContentController.addUserScript(try BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json")).userScript)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = web
        defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "bridge"); window.close() }
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

        func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }

        func js(_ body: String, timeout: TimeInterval = 20) -> String {
            var out: String?
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): out = value as? String ?? "\(String(describing: value))"
                case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
                }
            }
            spin(timeout) { out != nil }
            return out ?? "TIMEOUT"
        }

        /// Messages of `type` that arrived since `mark`, after giving the page a moment to send them.
        func messages(_ type: String, since mark: Int, wait: TimeInterval = 3) -> [Message] {
            spin(wait) { bridge.messages[mark...].contains { $0.type == type } }
            spin(0.2)
            return bridge.messages[mark...].filter { $0.type == type }
        }

        let tabA = UUID().uuidString, tabB = UUID().uuidString

        spin(30) { loaded.done }
        check(loaded.done, "shipping editor loaded")
        spin(2)

        // The app loads a document and names its tab in the same script (WebViewBridge.documentIDScript: mvSetDocument, then the load).
        var mark = bridge.messages.count
        var result = js("window.mvSetDocument(\"\(tabA)\"); window.setContent('# Alpha\\n\\nfirst document'); return 'ok';")
        check(result == "ok", "document A loads", result)
        var sent = messages("contentChanged", since: mark)
        check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabA }, "text reported after loading A names tab A", sent.map { $0.doc }.joined(separator: ","))
        check(sent.contains { ($0.payload["markdown"] as? String)?.contains("Alpha") == true }, "that text is document A's")

        mark = bridge.messages.count
        result = js("window.mvSetDocument(\"\(tabB)\"); window.setContent('# Beta\\n\\nsecond document'); return 'ok';")
        sent = messages("contentChanged", since: mark)
        check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabB }, "after switching to B, text names tab B", sent.map { $0.doc }.joined(separator: ","))

        // The reported failure: the page still shows B, typed into, while the app believes another tab is selected.
        // Cmd+S must send B's text and name B, so the app can write B's file and leave the selected tab alone.
        mark = bridge.messages.count
        result = js("""
        const rendered = document.getElementById('editor-rendered');
        rendered.querySelector('h1').textContent = 'Beta edited';
        rendered.dispatchEvent(new Event('input', {bubbles: true}));
        rendered.dispatchEvent(new KeyboardEvent('keydown', {key: 's', metaKey: true, bubbles: true, cancelable: true}));
        return 'ok';
        """)
        check(result == "ok", "Cmd+S is sent from the WYSIWYG view", result)
        let content = messages("contentChanged", since: mark)
        let saves = messages("saveRequested", since: mark)
        check(content.last.map { $0.doc == tabB && (($0.payload["markdown"] as? String) ?? "").contains("Beta edited") } == true,
              "Cmd+S sends the edited text of the shown document and names it", content.map { "\($0.doc):\($0.payload["markdown"] ?? "")" }.joined(separator: " | "))
        check(saves.count == 1 && saves[0].doc == tabB, "the save request names the shown document", saves.map { $0.doc }.joined(separator: ","))
        if let a = bridge.messages[mark...].firstIndex(where: { $0.type == "contentChanged" }),
           let b = bridge.messages[mark...].firstIndex(where: { $0.type == "saveRequested" }) {
            check(a < b, "the text arrives before the save request")
        }

        // No tab's document (the app clears the id for an insight or the X-Ray): messages carry an empty id.
        mark = bridge.messages.count
        result = js("window.mvSetDocument(''); window.setContent('# Loose'); return 'ok';")
        sent = messages("contentChanged", since: mark)
        check(!sent.isEmpty && sent.allSatisfy { $0.doc == "" }, "with the id cleared, messages name no document", sent.map { $0.doc }.joined(separator: ","))

        // BUG-043: unsaved WYSIWYG edits survive a switch to another document.
        let tabC = UUID().uuidString
        func load(_ id: String, _ markdown: String) {
            let result = js("window.mvSetDocument(\"\(id)\"); window.setContent('\(markdown)'); return 'ok';")
            check(result == "ok", "document \(markdown.prefix(12)) loads", result)
        }
        func typeInWysiwyg(_ text: String) {
            let result = js("""
            const rendered = document.getElementById('editor-rendered');
            rendered.querySelector('h1').textContent = '\(text)';
            rendered.dispatchEvent(new Event('input', {bubbles: true}));
            return 'ok';
            """)
            check(result == "ok", "typing in the WYSIWYG view", result)
        }
        func markdown(_ message: Message) -> String { (message.payload["markdown"] as? String) ?? "" }

        load(tabA, "# Alpha\\n\\nfirst document")
        typeInWysiwyg("Alpha typed, not saved")
        mark = bridge.messages.count
        load(tabB, "# Beta\\n\\nsecond document")
        sent = messages("contentChanged", since: mark)
        check(sent.first.map { $0.doc == tabA && markdown($0).contains("Alpha typed, not saved") } == true,
              "switching documents first hands over the unsaved edits, under the old id", sent.map { "\($0.doc.prefix(4)):\(markdown($0).prefix(30))" }.joined(separator: " | "))
        check(sent.dropFirst().allSatisfy { $0.doc == tabB && !markdown($0).contains("typed, not saved") },
              "what follows is the new document's own text, under the new id")
        check(sent.contains { $0.doc == tabB && markdown($0).contains("Beta") }, "the new document is reported")

        // Nothing was typed: no hand-over, the first message already belongs to the new document.
        mark = bridge.messages.count
        load(tabC, "# Gamma\\n\\nthird document")
        sent = messages("contentChanged", since: mark)
        check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabC }, "without edits nothing is handed over for the old document", sent.map { $0.doc.prefix(4) }.joined(separator: ","))

        // The same document loading again (a refresh from disk) keeps replacing the edits.
        typeInWysiwyg("Gamma typed, then refreshed")
        mark = bridge.messages.count
        load(tabC, "# Gamma\\n\\nfresh from disk")
        sent = messages("contentChanged", since: mark)
        check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabC && !markdown($0).contains("then refreshed") },
              "reloading the same document does not hand its edits over", sent.map { markdown($0).prefix(30) }.joined(separator: " | "))

        // The edits were synced into the Source view and never sent: they still must not be lost.
        load(tabA, "# Alpha\\n\\nfirst document")
        typeInWysiwyg("Alpha typed, then Source")
        _ = js("switchToSource(); return 'ok';")
        mark = bridge.messages.count
        load(tabB, "# Beta\\n\\nsecond document")
        sent = messages("contentChanged", since: mark)
        check(sent.first.map { $0.doc == tabA && markdown($0).contains("Alpha typed, then Source") } == true,
              "edits seen in the Source view are handed over too", sent.map { "\($0.doc.prefix(4)):\(markdown($0).prefix(30))" }.joined(separator: " | "))

        // Edits are handed over once: coming back and leaving again without typing sends nothing for that document.
        _ = js("switchToPreview(); return 'ok';")
        mark = bridge.messages.count
        load(tabC, "# Gamma\\n\\nthird document")
        sent = messages("contentChanged", since: mark)
        check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabC }, "a second switch hands nothing over again", sent.map { $0.doc.prefix(4) }.joined(separator: ","))

    }
}


@MainActor
private final class DocumentFilesTestLoader: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done?.resume()
        done = nil
    }
}

extension EditorHostTests {
    func testDocumentFilePolicy() throws {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
            XCTAssertTrue(ok, "\(name): \(detail())", line: line)
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("document-files-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        for folder in [project.appendingPathComponent("docs/images"), project.appendingPathComponent("sub"), outside] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: base) }
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        for path in ["docs/images/shot.png", "docs/images/file tree.PNG", "docs/images/logo.svg", "docs/notes.md", "sub/up.jpg"] {
            try bytes.write(to: project.appendingPathComponent(path))
        }
        try bytes.write(to: outside.appendingPathComponent("secret.png"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("docs/escape.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("docs/linked"), withDestinationURL: outside)

        func request(_ path: String) -> URL {
            var components = URLComponents()
            components.scheme = DocumentFiles.scheme
            components.host = ""
            components.path = path
            return components.url!
        }
        func resolve(_ path: String, roots: [URL]? = nil) -> DocumentFiles.Resolution {
            DocumentFiles.resolve(request(path), roots: roots ?? [project])
        }
        let real = project.resolvingSymlinksInPath().standardizedFileURL

        // A picture inside the project is served with its content type.
        if case .file(let url, let type) = resolve(project.path + "/docs/images/shot.png") {
            check("a picture inside the project is served", url.path == real.appendingPathComponent("docs/images/shot.png").path, url.path)
            check("png gets image/png", type == "image/png", type)
        } else { check("a picture inside the project is served", false) }

        if case .file(_, let type) = resolve(project.path + "/docs/images/logo.svg") {
            check("svg is declared as svg so an img can draw it", type == "image/svg+xml", type)
        } else { check("svg is served", false) }

        if case .file(let url, let type) = resolve(project.path + "/docs/images/file tree.PNG") {
            check("a name with a space and a capital extension is served", url.lastPathComponent == "file tree.PNG" && type == "image/png", url.path)
        } else { check("a name with a space and a capital extension is served", false) }

        // The address the page builds for a path with a space is percent-encoded; the request decodes it back.
        let encoded = URL(string: "markview-doc://" + project.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "/docs/images/file%20tree.PNG")!
        if case .file(let url, _) = DocumentFiles.resolve(encoded, roots: [project]) {
            check("a percent-encoded request is decoded", url.lastPathComponent == "file tree.PNG", url.path)
        } else { check("a percent-encoded request is decoded", false) }

        // Only pictures.
        check("a Markdown file is refused", resolve(project.path + "/docs/notes.md") == .forbidden)
        check("a path without a file type is refused", resolve(project.path + "/docs/images") == .forbidden)

        // Only inside the folders the person works in.
        check("a picture outside every root is refused", resolve(outside.path + "/secret.png") == .forbidden)
        check("a .. that leaves the root is refused", resolve(project.path + "/docs/../../outside/secret.png") == .forbidden)
        check("a symbolic link to a picture outside is refused", resolve(project.path + "/docs/escape.png") == .forbidden)
        check("a symbolic link to a folder outside is refused", resolve(project.path + "/docs/linked/secret.png") == .forbidden)
        check("a sibling folder with the root's name as a prefix is refused",
              resolve(base.path + "/project-other/x.png") == .forbidden)

        // .. that stays inside is fine.
        if case .file(let url, _) = resolve(project.path + "/sub/../docs/images/shot.png") {
            check("a .. that stays inside the root is served", url.lastPathComponent == "shot.png")
        } else { check("a .. that stays inside the root is served", false) }

        // Several roots: the folder of a document outside the project.
        check("a picture next to a document outside the project is served with that folder as a root",
              resolve(outside.path + "/secret.png", roots: [project, outside]) != .forbidden)

        // Requests that are not for this scheme or not absolute.
        check("another scheme is refused", DocumentFiles.resolve(URL(string: "https://example.com/a.png")!, roots: [project]) == .forbidden)
        check("no roots, nothing is served", resolve(project.path + "/docs/images/shot.png", roots: []) == .forbidden)

        // The roots: the project and the folder of each open document, without repeats.
        let docs = [project.appendingPathComponent("README.md"), project.appendingPathComponent("docs/notes.md"), outside.appendingPathComponent("a.md")]
        let roots = DocumentFiles.roots(project: project, documents: docs)
        check("roots are the project and the folders of the documents", roots.map(\.path) == [project.path, project.appendingPathComponent("docs").path, outside.path], roots.map(\.path).joined(separator: ", "))
        check("roots without a project are the folders of the documents",
              DocumentFiles.roots(project: nil, documents: [outside.appendingPathComponent("a.md")]).map(\.path) == [outside.path])

    }

    @MainActor func testDocumentFilePagePaths() async throws {
        func check(_ name: String, _ ok: Bool, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(ok, "\(name): \(detail)", line: line)
        }
        _ = NSApplication.shared
        let scriptURL = try XCTUnwrap(Bundle.main.url(forResource: "markview-document-files", withExtension: "js", subdirectory: "Editor/js"))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        defer { web.stopLoading() }
        let loader = DocumentFilesTestLoader()
        web.navigationDelegate = loader
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loader.done = continuation
            web.loadHTMLString("<html><body><div id=\"r\"></div></body></html>", baseURL: nil)
        }
        let test = script + """
        ;
        const base = 'file:///P/my%20q/';
        const r = document.getElementById('r');
        r.innerHTML = '<p><img src="a b.png" width="10"> <img src="https://x.test/w.png"> <img src="data:image/png;base64,AAAA">'
            + '<a href="notes/x.md">link</a>'
            + '<picture><source srcset="a.png 1x, b.png 2x"><img src="../up.png"></picture></p>';
        // what the renderer does to links
        r.querySelectorAll('a').forEach(function (a) { a.setAttribute('data-mv-href', a.getAttribute('href')); a.setAttribute('href', new URL(a.getAttribute('href'), base).href); });
        MarkViewDocumentFiles.resolvePictures(r, base);
        const shown = r.innerHTML;
        const restored = MarkViewDocumentFiles.withOriginalPaths(shown);
        return JSON.stringify({ shown: shown, restored: restored, original: '<p><img src="a b.png" width="10"> <img src="https://x.test/w.png"> <img src="data:image/png;base64,AAAA"><a href="notes/x.md">link</a><picture><source srcset="a.png 1x, b.png 2x"><img src="../up.png"></picture></p>' });
        """
        let raw = try? await web.callAsyncJavaScript(test, contentWorld: .page) as? String
        guard let raw, let data = raw.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let shown = result["shown"], let restored = result["restored"], let original = result["original"] else {
            XCTFail("The document-files script did not return its results"); return
        }
        check("a local picture is shown at its markview-doc address", shown.contains("src=\"markview-doc:///P/my%20q/a%20b.png\""), shown)
        check("a parent-relative picture is shown at its address", shown.contains("src=\"markview-doc:///P/up.png\""), shown)
        check("a srcset is rewritten with its descriptors", shown.contains("markview-doc:///P/my%20q/a.png 1x, markview-doc:///P/my%20q/b.png 2x"), shown)
        check("a web picture and inline data stay as written", shown.contains("src=\"https://x.test/w.png\"") && shown.contains("src=\"data:image/png;base64,AAAA\""), shown)
        check("the width the author wrote is kept", shown.contains("width=\"10\""))
        check("the author's paths come back exactly", restored == original, "\n  got  \(restored)\n  want \(original)")
        check("no helper attribute is left after restoring", !restored.contains("data-mv-"), restored)
    }

    @MainActor func testDocumentFileSchemeHandler() async throws {
        func check(_ name: String, _ ok: Bool, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(ok, "\(name): \(detail)", line: line)
        }
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("document-handler-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: project.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        func png() -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            return rep.representation(using: .png, properties: [:])!
        }
        try png().write(to: project.appendingPathComponent("docs/a b.png"))
        try png().write(to: outside.appendingPathComponent("secret.png"))
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'><rect width='20' height='10' fill='red'/></svg>".utf8)
            .write(to: project.appendingPathComponent("docs/logo.svg"))

        func address(_ path: String) -> String {
            var components = URLComponents()
            components.scheme = DocumentFiles.scheme
            components.host = ""
            components.path = path
            return components.string!
        }

        let handler = DocumentFileSchemeHandler()
        handler.allowedRoots = { [project] }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: DocumentFileSchemeHandler.scheme)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        defer { web.stopLoading() }
        let loader = DocumentFilesTestLoader()
        web.navigationDelegate = loader
        let page = """
        <html><body>
        <img id="ok" src="\(address(project.path + "/docs/a b.png"))">
        <img id="svg" src="\(address(project.path + "/docs/logo.svg"))">
        <img id="outside" src="\(address(outside.path + "/secret.png"))">
        <img id="missing" src="\(address(project.path + "/docs/none.png"))">
        </body></html>
        """
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loader.done = continuation
            web.loadHTMLString(page, baseURL: URL(fileURLWithPath: "/"))
        }
        // The load event waits for the pictures; a short extra wait covers a slow answer.
        try await Task.sleep(nanoseconds: 700_000_000)
        let raw = try await web.callAsyncJavaScript("""
        return JSON.stringify(Array.from(document.images).map(function (i) { return [i.id, i.complete && i.naturalWidth, i.naturalHeight]; }));
        """, contentWorld: .page) as? String
        let rows = (try? JSONSerialization.jsonObject(with: Data((raw ?? "[]").utf8))) as? [[Any]] ?? []
        var sizes: [String: [Int]] = [:]
        for row in rows { if let id = row[0] as? String { sizes[id] = [(row[1] as? Int) ?? 0, (row[2] as? Int) ?? 0] } }

        check("an allowed picture with a space in its name loads at its size", sizes["ok"] == [12, 8], "\(sizes)")
        check("an SVG loads (declared as image/svg+xml)", sizes["svg"] == [20, 10], "\(sizes)")
        check("a picture outside the folders is refused", sizes["outside"] == [0, 0], "\(sizes)")
        check("a missing picture does not load", sizes["missing"] == [0, 0], "\(sizes)")
    }
}


extension EditorHostTests {
    @MainActor func testMermaidSVGRenderingAndSanitization() throws {
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent().path
        let editor = ProcessInfo.processInfo.environment["MARKVIEW_MERMAID_EDITOR"] ?? bundled
        let testDeadline = Date().addingTimeInterval(240)
        func check(_ ok: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(ok, "\(message): \(detail.prefix(900))", line: line)
        }
        final class Bridge: NSObject, WKScriptMessageHandler {
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
        }
        final class Loaded: NSObject, WKNavigationDelegate {
            var done = false
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        }

        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(Bridge(), name: "bridge")
        config.userContentController.addUserScript(try BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json")).userScript)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = web
        defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "bridge"); window.close() }
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

        func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
            let end = min(Date().addingTimeInterval(seconds), testDeadline)
            while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }

        func js(_ body: String, timeout: TimeInterval = 120) -> String {
            var out: String?
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): out = value as? String ?? "\(String(describing: value))"
                case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
                }
            }
            spin(timeout) { out != nil }
            return out ?? "TIMEOUT"
        }

        /// Runs one block of page script that returns a JSON array of {name, ok, detail} and prints every entry as a check.
        func runChecks(_ title: String, _ body: String) {
            let answer = js(body)
            guard let data = answer.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                check(false, "\(title) returned results", answer)
                return
            }
            for entry in list { check(entry["ok"] as? Bool == true, entry["name"] as? String ?? title, entry["detail"] as? String ?? "") }
        }

        spin(30) { loaded.done }
        check(loaded.done, "shipping editor page loaded")
        spin(2)
        let ready = js("return String(typeof window.setContent === 'function' && typeof window.mvKit === 'object' && typeof window.mermaid === 'object');")
        check(ready == "true", "the page has setContent, mvKit and Mermaid", ready)

        // 1. A real diagram, drawn and inserted by the page itself.
        runChecks("the real diagram", #"""
            const results = [];
            const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
            const source = 'graph TD\n  A[Start] --> B{Choice}\n  B -->|yes| C[Done]\n  B -->|no| D[Retry]';
            window.mvSetDocument('mermaid-svg-test');
            window.setContent('# Diagram\n\n```mermaid\n' + source + '\n```\n');
            for (let i = 0; i < 100 && !document.querySelector('#editor-rendered .mermaid svg'); i++) await new Promise(r => setTimeout(r, 100));
            const shown = document.querySelector('#editor-rendered .mermaid svg');
            note('the page draws the diagram', !!shown);
            if (!shown) return JSON.stringify(results);
            function probe(svg) {
                const rect = svg.querySelector('.node rect, .node polygon');
                const label = svg.querySelector('.nodeLabel');
                const edge = svg.querySelector('.flowchart-link');
                return {
                    fill: rect ? getComputedStyle(rect).fill : 'none',
                    stroke: rect ? getComputedStyle(rect).stroke : 'none',
                    labelColor: label ? getComputedStyle(label).color : 'none',
                    edgeStroke: edge ? getComputedStyle(edge).stroke : 'none',
                    labels: Array.from(svg.querySelectorAll('.nodeLabel')).map(e => e.textContent.trim()).filter(Boolean)
                };
            }
            // The same source drawn by Mermaid and inserted with no sanitiser: this is what the theme looks like.
            const drawn = await mermaid.render('mermaid-svg-expected', source);
            const scratch = document.createElement('div');
            scratch.innerHTML = drawn.svg;
            document.body.appendChild(scratch);
            const expected = probe(scratch.querySelector('svg'));
            const actual = probe(shown);
            scratch.remove();
            note('Mermaid theme fill is not the default black', expected.fill !== 'rgb(0, 0, 0)' && expected.fill !== 'none', JSON.stringify(expected));
            note('the node fill on the page is the fill Mermaid drew', actual.fill === expected.fill, 'page ' + actual.fill + ' expected ' + expected.fill);
            note('the node outline on the page is the outline Mermaid drew', actual.stroke === expected.stroke && actual.stroke !== 'none', 'page ' + actual.stroke + ' expected ' + expected.stroke);
            note('the label colour on the page is the one Mermaid drew', actual.labelColor === expected.labelColor, 'page ' + actual.labelColor + ' expected ' + expected.labelColor);
            note('the edge colour on the page is the one Mermaid drew', actual.edgeStroke === expected.edgeStroke && actual.edgeStroke !== 'none', 'page ' + actual.edgeStroke + ' expected ' + expected.edgeStroke);
            note('every label of the diagram is on the page', expected.labels.length >= 4 && JSON.stringify(actual.labels) === JSON.stringify(expected.labels), 'page ' + JSON.stringify(actual.labels) + ' expected ' + JSON.stringify(expected.labels));
            const style = shown.querySelector('style');
            const id = shown.getAttribute('id');
            const sheet = style ? Array.from(document.styleSheets).find(s => s.ownerNode === style) : null;
            const rules = sheet ? Array.from(sheet.cssRules) : [];
            note('the diagram keeps its own stylesheet', rules.length > 10, 'rules: ' + rules.length);
            note('every rule of that stylesheet starts at the diagram id', rules.length > 0 && rules.every(r => r.type === 1 && r.selectorText.split(',').every(s => s.trim().indexOf('#' + id) === 0)), id);
            return JSON.stringify(results);
            """#)

        // 2. Sixteen kinds of diagram: nothing Mermaid draws is lost.
        runChecks("diagram kinds", #"""
            const results = [];
            const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
            const kinds = {
              flowchart: 'graph TD\n A[Start]-->B{Choice}\n B-->|yes|C[Done]\n classDef big fill:#f9f,stroke:#333,stroke-width:4px\n class A big\n style C fill:#bbf,stroke:#f66,stroke-dasharray: 5 5',
              sequence: 'sequenceDiagram\n participant Alice\n Alice->>Bob: Hello\n Bob-->>Alice: Hi\n Note over Alice,Bob: note\n loop L\n Alice->>Bob: x\n end',
              class: 'classDiagram\n class Animal{+int age\n +eat()}\n Animal <|-- Dog\n Animal : +String name',
              state: 'stateDiagram-v2\n [*] --> Still\n Still --> Moving\n Moving --> [*]\n state Moving {\n  [*] --> A\n }',
              er: 'erDiagram\n CUSTOMER ||--o{ ORDER : places\n CUSTOMER { string name }',
              gantt: 'gantt\n title T\n dateFormat YYYY-MM-DD\n section S\n A :a1, 2024-01-01, 3d\n B :after a1, 2d',
              pie: 'pie title Pets\n "Dogs" : 386\n "Cats" : 85',
              mindmap: 'mindmap\n root((mind))\n  A\n  B',
              journey: 'journey\n title J\n section S\n  Task: 5: Me',
              git: 'gitGraph\n commit\n branch dev\n commit\n checkout main\n merge dev',
              timeline: 'timeline\n title T\n 2002 : A',
              quadrant: 'quadrantChart\n title Q\n x-axis Low --> High\n y-axis Low --> High\n quadrant-1 A\n Campaign A: [0.3, 0.6]',
              xy: 'xychart-beta\n title "S"\n x-axis [a, b]\n bar [1, 2]',
              c4: 'C4Context\n title T\n Person(a, "A")',
              sankey: 'sankey-beta\n a,b,1',
              requirement: 'requirementDiagram\n requirement test_req {\n id: 1\n text: the test text.\n risk: high\n verifymethod: test\n }'
            };
            const parser = document.implementation.createHTMLDocument('');
            function declarations(svgMarkup) {
                const doc = new DOMParser().parseFromString(svgMarkup, 'text/html');
                const list = [];
                doc.querySelectorAll('style').forEach(el => {
                    const s = parser.createElement('style');
                    s.textContent = el.textContent;
                    parser.head.appendChild(s);
                    Array.from(s.sheet.cssRules).forEach(rule => {
                        for (const property of rule.style) list.push(rule.selectorText.replace(/#[A-Za-z0-9_-]+/, '#ID') + '|' + property + ':' + rule.style.getPropertyValue(property));
                    });
                    s.remove();
                });
                return list;
            }
            function text(svgMarkup) {
                const doc = new DOMParser().parseFromString(svgMarkup, 'text/html');
                doc.querySelectorAll('style').forEach(s => s.remove());
                return doc.body.textContent.replace(/\s+/g, ' ').trim();
            }
            let serial = 0;
            for (const [kind, source] of Object.entries(kinds)) {
                let drawn;
                try { drawn = await mermaid.render('kind-' + (++serial), source); } catch (e) { note(kind + ': Mermaid draws the sample', false, e); continue; }
                const clean = window.mvKit.sanitizeMermaidSvg(drawn.svg);
                const before = declarations(drawn.svg), after = new Set(declarations(clean));
                // The two declarations the filter refuses on purpose: z-index, and position:absolute on the HTML overlays Mermaid adds
                // to the page body for click callbacks (tooltip, sequence-diagram popup menu), which never sit inside the returned SVG.
                const overlay = /\.(?:mermaidTooltip|actorPopupMenu|actorPopupMenuPanel)\|position:absolute$/;
                const lost = before.filter(d => !after.has(d)).filter(d => d.indexOf('|z-index:') < 0 && !overlay.test(d));
                note(kind + ': every label is kept', text(drawn.svg) === text(clean), text(drawn.svg).slice(0, 80) + ' / ' + text(clean).slice(0, 80));
                note(kind + ': every style declaration is kept', before.length > 0 && lost.length === 0, 'declarations ' + before.length + ', lost: ' + lost.slice(0, 3).join(' ; '));
            }
            return JSON.stringify(results);
            """#)

        // 3. Hostile SVG.
        runChecks("hostile SVG", #"""
            const results = [];
            const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
            window.__pwn = 0;
            const corpus = {
              'a script element': '<svg id="a1"><script>window.__pwn = 1</script><rect/></svg>',
              'event handlers': '<svg id="a2" onload="window.__pwn = 2"><rect onclick="window.__pwn = 2" onmouseover="window.__pwn = 2"/></svg>',
              'a script and a handler in foreignObject': '<svg id="a3"><foreignObject><script>window.__pwn = 3</script><div onclick="window.__pwn = 3">x</div></foreignObject></svg>',
              'an iframe, a form, an object and an embed in foreignObject': '<svg id="a4"><foreignObject><iframe srcdoc="<script>parent.__pwn = 4</script>"></iframe><form action="https://evil.invalid"></form><object data="x"></object><embed src="x"></foreignObject></svg>',
              'javascript: links': '<svg id="a5"><a href="javascript:window.__pwn = 5"><text>x</text></a><a xlink:href="javascript:window.__pwn = 5"><text>y</text></a></svg>',
              'an @import': '<svg id="a6"><style>@import url(https://evil.invalid/x.css); @import "https://evil.invalid/y.css";</style><rect/></svg>',
              'rules outside the diagram': '<svg id="a7"><style>body{display:none} p{color:red} #a7 rect{fill:red} #a7 ~ p{color:blue} #a7 + p{color:blue}</style><rect/></svg>',
              'remote loads from CSS': '<svg id="a8"><style>#a8 rect{background:url(https://evil.invalid/p.png);list-style-image:url(https://evil.invalid/q.png);cursor:url(https://evil.invalid/c.png),auto;filter:url(https://evil.invalid/f.svg#x)}</style><rect/></svg>',
              'CSS escapes and comments': '<svg id="a9"><style>#a9 rect{position:f\\69xed;background:\\75rl(https://evil.invalid/p.png);z-index:9;color:/**/red;-moz-binding:url(x);behavior:url(x)}</style><rect/></svg>',
              'a CSS expression': '<svg id="b1"><style>#b1 rect{width:expression(window.__pwn = 6);fill:red}</style><rect/></svg>',
              'markup in a CSS string': '<svg id="b2"><style>#b2 a{content:"</style><img src=x onerror=window.__pwn=7>"}</style></svg>',
              'a mutation payload with </p>': '<svg></p><style><a id="</style><img src=1 onerror=window.__pwn=8>">',
              'a mutation payload with mglyph': '<math><mtext><table><mglyph><style><!--</style><img title="--&gt;&lt;img src=1 onerror=window.__pwn=9&gt;">',
              'a mutation payload in foreignObject': '<svg id="b3"><foreignObject><p><svg><desc><style><a id="</style><img src=1 onerror=window.__pwn=10>"></style></desc></svg></p></foreignObject></svg>',
              'a style in foreignObject': '<svg id="b4"><foreignObject><style>body{display:none}</style><style><img src=x onerror=window.__pwn=11></style><div>y</div></foreignObject></svg>',
              'a comment that closes a style': '<svg id="b5"><style><!--</style><img src=x onerror=window.__pwn=12>--></style></svg>',
              'nested foreignObject': '<svg id="b6"><foreignObject><svg><foreignObject><img src=x onerror=window.__pwn=13></foreignObject></svg></foreignObject></svg>',
              'a hostile style attribute': '<svg id="b7"><rect style="position:fixed;background:url(https://evil.invalid/p.png);fill:blue" width="5" height="5"/></svg>'
            };
            const host = document.createElement('div');
            document.body.appendChild(host);
            const bodyBefore = getComputedStyle(document.body).display;
            for (const [name, raw] of Object.entries(corpus)) {
                const clean = window.mvKit.sanitizeMermaidSvg(raw);
                host.innerHTML = clean;
                const once = host.innerHTML;
                host.innerHTML = once;
                await new Promise(r => setTimeout(r, 40));
                const all = Array.from(host.querySelectorAll('*'));
                const handlers = all.filter(e => Array.from(e.attributes).some(a => /^on/i.test(a.name))).length;
                const jsLinks = all.filter(e => Array.from(e.attributes).some(a => /javascript:/i.test(a.value))).length;
                const imports = Array.from(document.styleSheets).filter(s => s.ownerNode && host.contains(s.ownerNode)).flatMap(s => Array.from(s.cssRules)).filter(r => r.type === 3).length;
                const outside = Array.from(document.styleSheets).filter(s => s.ownerNode && host.contains(s.ownerNode)).flatMap(s => Array.from(s.cssRules))
                    .filter(r => r.type === 1 && !r.selectorText.split(',').every(sel => /^#(a\d|b\d)(?![\w-])/.test(sel.trim()))).length;
                const loads = all.filter(e => /url\(\s*["']?https?:/i.test(e.getAttribute('style') || '')).length +
                    Array.from(document.styleSheets).filter(s => s.ownerNode && host.contains(s.ownerNode)).flatMap(s => Array.from(s.cssRules)).filter(r => /url\(\s*["']?https?:/i.test(r.cssText)).length;
                const fixed = all.filter(e => getComputedStyle(e).position === 'fixed').length;
                const rect = host.querySelector('rect');
                const background = rect ? getComputedStyle(rect).backgroundImage : 'none';
                note('hostile SVG neutralised: ' + name,
                     host.querySelectorAll('script').length === 0 && handlers === 0 && jsLinks === 0 && imports === 0 && outside === 0 && loads === 0 &&
                     fixed === 0 && background === 'none' && once === host.innerHTML && window.__pwn === 0 && getComputedStyle(document.body).display === bodyBefore,
                     JSON.stringify({ clean: clean.slice(0, 200), handlers, jsLinks, imports, outside, loads, fixed, background, pwn: window.__pwn }));
                host.innerHTML = '';
            }
            await new Promise(r => setTimeout(r, 300));
            note('nothing the hostile SVG carried ran', window.__pwn === 0, window.__pwn);
            host.remove();
            return JSON.stringify(results);
            """#)

        // 4. <style> stays forbidden everywhere else.
        runChecks("other profiles", #"""
            const results = [];
            const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
            for (const profile of ['markdown', 'book', 'discussion', 'insight']) {
                const clean = window.mvKit.sanitizeHtml('<p>kept</p><style>body{display:none}</style><svg id="x"><style>#x rect{fill:red}</style><rect/></svg>', profile);
                note('the ' + profile + ' profile still drops <style>', clean.indexOf('kept') >= 0 && clean.toLowerCase().indexOf('<style') < 0, clean);
            }
            return JSON.stringify(results);
            """#)

    }
}


extension EditorHostTests {
    @MainActor func testLargeEditorDiagramsRemainResponsive() throws {
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent().path
        let editor = ProcessInfo.processInfo.environment["MARKVIEW_DIAGRAM_EDITOR"] ?? bundled
        let testDeadline = Date().addingTimeInterval(300)
        func check(_ ok: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(ok, "\(message): \(detail.prefix(600))", line: line)
        }
        final class Bridge: NSObject, WKScriptMessageHandler {
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
        }
        final class Loaded: NSObject, WKNavigationDelegate {
            var done = false
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        }

        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(Bridge(), name: "bridge")
        config.userContentController.addUserScript(try BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json")).userScript)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = web
        defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "bridge"); window.close() }
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

        func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
            let end = min(Date().addingTimeInterval(seconds), testDeadline)
            while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }

        func js(_ body: String, arguments: [String: Any] = [:], timeout: TimeInterval = 120) -> String {
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

        func json(_ text: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }

        let flowchart = "graph TD\n  A[Start] --> B{Choice}\n  B -->|yes| C[Done]\n  B -->|no| D[Retry]\n  D --> B"
        func diagram(_ source: String? = nil) -> String { "```mermaid\n\(source ?? flowchart)\n```\n" }

        /// Loads `markdown` the way the app does and waits until every diagram has its picture and its expand button.
        /// Returns the longest time the page did not answer a timer while it worked, and how long the whole drawing took.
        struct Drawn { var complete = false; var seconds = 0.0; var longestStall = 0.0; var diagrams = 0; var pictures = 0; var buttons = 0; var bodyDisplay = "" }
        func open(_ markdown: String, id: String, expecting diagrams: Int, within limit: TimeInterval = 100) -> Drawn {
            _ = js("""
                window.__stall = { max: 0, last: performance.now(), on: true };
                (function tick() {
                    const now = performance.now();
                    window.__stall.max = Math.max(window.__stall.max, now - window.__stall.last);
                    window.__stall.last = now;
                    if (window.__stall.on) setTimeout(tick, 10);
                })();
                return 'ok';
                """)
            let started = Date()
            _ = js("window.mvSetDocument(id); window.setContent(markdown); return 'ok';", arguments: ["id": id, "markdown": markdown])
            var result = Drawn()
            while Date() < testDeadline && Date().timeIntervalSince(started) < limit {
                spin(0.25)
                let state = json(js("""
                    const root = document.getElementById('editor-rendered');
                    const nodes = Array.from(root.querySelectorAll('.mermaid'));
                    return JSON.stringify({ diagrams: nodes.length, pictures: nodes.filter(n => n.querySelector('svg')).length,
                        buttons: root.querySelectorAll('.mermaid-expand-btn').length,
                        bodyDisplay: (root.querySelector('.markdown-body') || { style: {} }).style.display || '' });
                    """))
                result.diagrams = state["diagrams"] as? Int ?? 0
                result.pictures = state["pictures"] as? Int ?? 0
                result.buttons = state["buttons"] as? Int ?? 0
                result.bodyDisplay = state["bodyDisplay"] as? String ?? ""
                if result.diagrams == diagrams, result.pictures == diagrams, result.buttons == diagrams {
                    result.complete = true
                    break
                }
            }
            result.seconds = Date().timeIntervalSince(started)
            spin(0.4) // a stalled page answers its timer only after the stall, so the longest gap is read after a moment
            result.longestStall = (Double(js("window.__stall.on = false; return String(Math.round(window.__stall.max));")) ?? -1) / 1000
            return result
        }

        spin(30) { loaded.done }
        check(loaded.done, "shipping editor loaded")
        spin(2)

        // A large document: 150 sections of text, a table of 12 rows and a diagram.
        var large = "# A large document\n\n"
        for section in 0..<150 {
            large += "## Section \(section)\n\nParagraph \(section) of the market entry plan, long enough to be a realistic block of prose.\n\n"
            large += "| Item | Owner | Value | Note |\n|---|---|---|---|\n"
            for row in 0..<12 { large += "| row \(section).\(row) | team \(row) | \(row * 7) | note \(row) |\n" }
            large += "\n" + diagram() + "\n"
        }
        let big = open(large, id: UUID().uuidString, expecting: 150)
        check(big.complete, "all 150 diagrams of a large document are drawn and have their expand button",
              "diagrams \(big.diagrams), pictures \(big.pictures), buttons \(big.buttons) after \(big.seconds) s")
        print("    drawn in \(String(format: "%.1f", big.seconds)) s, longest time the page did not answer: \(String(format: "%.1f", big.longestStall)) s")
        check(big.longestStall < 5, "the page answers within 5 s while the diagrams of a large document are drawn", "stalled \(big.longestStall) s")
        check(big.bodyDisplay == "", "the document body is shown again once the diagrams are drawn", big.bodyDisplay)

        // A broken diagram is shown by Mermaid itself and the diagrams around it are still drawn.
        let mixed = open("# Mixed\n\n" + diagram() + "\n" + diagram("graph TD\n  A --> ;;; [[[ broken") + "\n" + diagram(), id: UUID().uuidString, expecting: 3)
        check(mixed.complete, "a broken diagram is drawn by Mermaid and the diagrams around it are drawn", "pictures \(mixed.pictures) of \(mixed.diagrams)")
        let marked = Int(js("return String(document.querySelectorAll('#editor-rendered .mermaid[data-processed]').length);")) ?? -1
        check(marked == 3, "every diagram is marked as processed, as Mermaid's own run marks them", "\(marked) of 3")

        // A document that replaces another while its diagrams are still being drawn leaves only its own diagrams.
        var many = "# First\n\n"
        for _ in 0..<60 { many += diagram() + "\nText\n\n" }
        _ = js("window.mvSetDocument('first'); window.setContent(markdown); setTimeout(() => window.setContent('# Second\\n\\n' + diagram), 700); return 'ok';",
               arguments: ["markdown": many, "diagram": diagram()])
        spin(8)
        let replaced = json(js("""
            const nodes = Array.from(document.querySelectorAll('#editor-rendered .mermaid'));
            return JSON.stringify({ diagrams: nodes.length, pictures: nodes.filter(n => n.querySelector('svg')).length,
                title: (document.querySelector('#editor-rendered h1') || {}).textContent || '' });
            """))
        check(replaced["title"] as? String == "Second" && replaced["diagrams"] as? Int == 1 && replaced["pictures"] as? Int == 1,
              "a document that replaces another while it is being drawn shows only its own diagram", "\(replaced)")

        // The reading position survives the hiding of the body.
        var long = "# Long\n\n"
        for index in 0..<400 { long += "Paragraph \(index) of filler text that makes the page tall enough to scroll.\n\n" }
        long += many
        _ = js("window.mvSetDocument('scroll'); window.setContent(markdown); return 'ok';", arguments: ["markdown": long])
        spin(0.3)
        _ = js("document.getElementById('editor-rendered').scrollTop = 3000; return 'ok';")
        spin(8)
        let scrolled = js("return String(document.getElementById('editor-rendered').scrollTop);")
        check(scrolled == "3000", "the reading position is kept while the diagrams are drawn", scrolled)

        // A document without diagrams is not touched.
        _ = js("window.mvSetDocument('plain'); window.setContent('# Plain\\n\\nNo diagrams here.'); return 'ok';")
        spin(1)
        let plain = json(js("""
            const root = document.getElementById('editor-rendered');
            return JSON.stringify({ title: (root.querySelector('h1') || {}).textContent || '', diagrams: root.querySelectorAll('.mermaid').length,
                bodyDisplay: (root.querySelector('.markdown-body') || { style: {} }).style.display || '' });
            """))
        check(plain["title"] as? String == "Plain" && plain["diagrams"] as? Int == 0 && plain["bodyDisplay"] as? String == "",
              "a document without diagrams renders as before", "\(plain)")

    }
}


extension EditorHostTests {
    @MainActor func testUntrustedEditorValuesAndStyles() throws {
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent().path
        let editor = ProcessInfo.processInfo.environment["MARKVIEW_WEB_SINKS_EDITOR"] ?? bundled
        let testDeadline = Date().addingTimeInterval(240)
        func check(_ ok: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(ok, "\(message): \(detail.prefix(900))", line: line)
        }
        final class Bridge: NSObject, WKScriptMessageHandler {
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
        }
        final class Loaded: NSObject, WKNavigationDelegate {
            var done = false
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        }

        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(Bridge(), name: "bridge")
        config.userContentController.addUserScript(try BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json")).userScript)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = web
        defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "bridge"); window.close() }
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

        func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
            let end = min(Date().addingTimeInterval(seconds), testDeadline)
            while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }

        func js(_ body: String, timeout: TimeInterval = 120) -> String {
            var out: String?
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): out = value as? String ?? "\(String(describing: value))"
                case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
                }
            }
            spin(timeout) { out != nil }
            return out ?? "TIMEOUT"
        }

        /// Runs one block of page script that returns a JSON array of {name, ok, detail} and prints every entry as a check.
        func runChecks(_ title: String, _ body: String) {
            let answer = js(body)
            guard let data = answer.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                check(false, "\(title) returned results", answer)
                return
            }
            for entry in list { check(entry["ok"] as? Bool == true, entry["name"] as? String ?? title, entry["detail"] as? String ?? "") }
        }

        spin(30) { loaded.done }
        check(loaded.done, "shipping editor page loaded")
        spin(2)
        let ready = js("return String(typeof window.setContent === 'function' && typeof window.mvKit === 'object' && typeof window.mermaid === 'object');")
        check(ready == "true", "the page has setContent, mvKit and Mermaid", ready)

        // 1. The style filter on every profile.
        runChecks("style attributes", #"""
            const results = [];
            const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
            const cases = [
              // [name, style, properties that must be gone, properties that must stay as {name: value}]
              ['a CSS escape in the position value', 'position:f\\69xed;color:red', ['position'], { color: 'red' }],
              ['a comment in the position value', 'position:/**/fixed;color:red', ['position'], { color: 'red' }],
              ['position fixed with !important', 'POSITION : FIXED !important;color:red', ['position'], { color: 'red' }],
              ['position sticky', 'position:sticky;top:0', ['position'], {}],
              ['position absolute', 'position:absolute;top:0', ['position'], {}],
              ['an escaped url() function', 'background:\\75rl(https://evil.invalid/x.png);color:red', ['background-image'], { color: 'red' }],
              ['a half-escaped url() function', 'background:u\\72l(https://evil.invalid/x.png)', ['background-image'], {}],
              ['a remote background', 'background:url(https://evil.invalid/x.png);color:red', ['background-image'], { color: 'red' }],
              ['a relative background address', 'background-image:url(local.png)', ['background-image'], {}],
              ['an SVG data picture', 'background:url("data:image/svg+xml,<svg onload=1>")', ['background-image'], {}],
              ['image-set with a remote address', 'background-image:image-set("https://evil.invalid/x.png" 1x)', ['background-image'], {}],
              ['a remote cursor', 'cursor:url(https://evil.invalid/c.cur), auto;color:red', ['cursor'], { color: 'red' }],
              ['a remote list marker', 'list-style-image:url(https://evil.invalid/l.png)', ['list-style-image'], {}],
              ['a remote filter', 'filter:url(https://evil.invalid/f.svg#x)', ['filter'], {}],
              ['a remote border image', 'border-image-source:url(https://evil.invalid/b.png)', ['border-image-source'], {}],
              ['a CSS expression', 'width:expression(window.__pwn = 1);color:red', ['width'], { color: 'red' }],
              ['z-index', 'z-index:9999;color:red', ['z-index'], { color: 'red' }],
              ['content', 'content:"x";color:red', ['content'], { color: 'red' }],
              ['behavior and -moz-binding', 'behavior:url(x);-moz-binding:url(x);color:red', ['behavior', '-moz-binding'], { color: 'red' }],
              ['a custom property that hides url() behind an escape', '--x:\\75rl(https://evil.invalid/x);color:red', ['--x'], { color: 'red' }],
              ['all: unset (hundreds of longhands)', 'all:unset;color:red', ['display', 'color'], {}],
              ['a property that is not on the list', 'zoom:3;appearance:none;pointer-events:none', ['zoom', 'appearance'], { 'pointer-events': 'none' }],
              ['KaTeX-style offsets', 'height:1.5em;top:-0.2em;vertical-align:-0.25em;margin-right:0.05em', [], { height: '1.5em', top: '-0.2em', 'vertical-align': '-0.25em', 'margin-right': '0.05em' }],
              ['relative position', 'position:relative;top:2px', [], { position: 'relative', top: '2px' }],
              ['a data picture, a gradient and a fragment reference', 'background-image:url(data:image/png;base64,AAA=);fill:url(#grad);filter:url(#blur)', [], { fill: 'url("#grad")', filter: 'url("#blur")' }],
              ['layout, text and colour', 'display:grid;grid-template-columns:repeat(2,1fr);gap:4px;color:#f00;font-weight:600;border:1px solid #333;transform:rotate(3deg)', [], { display: 'grid', gap: '4px', 'font-weight': '600', transform: 'rotate(3deg)' }],
              ['a custom property used as a colour', '--accent:#123;color:var(--accent)', [], { '--accent': '#123', color: 'var(--accent)' }]
            ];
            const html = cases.map((c, i) => '<p id="c' + i + '" style="' + c[1].replace(/"/g, '&quot;') + '">x</p>').join('');
            for (const profile of ['markdown', 'book', 'discussion', 'insight']) {
                const doc = new DOMParser().parseFromString(window.mvKit.sanitizeHtml(html, profile), 'text/html');
                cases.forEach((c, i) => {
                    const el = doc.getElementById('c' + i);
                    const style = el ? el.style : null;
                    const gone = c[2].filter(p => style && style.getPropertyValue(p) !== '' && !(p === 'background-image' && style.getPropertyValue(p) === 'none'));
                    const wrong = Object.entries(c[3]).filter(([p, v]) => !style || style.getPropertyValue(p) !== v && !(p === 'color' && style.getPropertyValue(p).replace(/\s/g, '') === 'rgb(255,0,0)'));
                    note(profile + ' profile: ' + c[0], !!el && gone.length === 0 && wrong.length === 0, 'still set: ' + gone.join(',') + ' wrong: ' + wrong.map(w => w[0]).join(',') + ' style: ' + (el && el.getAttribute('style')));
                });
            }
            // The same on the page's own path: the page renders the document and asks the browser what it computed.
            window.__pwn = 0;
            window.mvSetDocument('web-sinks-style');
            window.setContent('# Styles\n\n<div id="live-fixed" style="position:f\\69xed;top:0;left:0;width:100vw;height:100vh;background:red">covers</div>\n\n<div id="live-url" style="background:\\75rl(https://evil.invalid/x.png) red;height:10px">x</div>\n');
            for (let i = 0; i < 50 && !document.getElementById('live-fixed'); i++) await new Promise(r => setTimeout(r, 100));
            const fixed = document.getElementById('live-fixed'), remote = document.getElementById('live-url');
            note('the page renders the document with the escaped fixed position', !!fixed);
            if (fixed) {
                const toolbar = document.getElementById('mode-toggle').getBoundingClientRect();
                const hit = document.elementFromPoint(toolbar.left + 3, toolbar.top + 3);
                note('an escaped position:fixed in a document does not cover the page toolbar', getComputedStyle(fixed).position === 'static' && hit && hit.id === 'mode-toggle', getComputedStyle(fixed).position + ' ' + (hit && (hit.id || hit.className)));
            }
            note('an escaped url() in a document loads no remote background', !!remote && getComputedStyle(remote).backgroundImage === 'none', remote && getComputedStyle(remote).backgroundImage);
            return JSON.stringify(results);
            """#)

        // 2. A colour in a .canvas file.
        runChecks("canvas colour", #"""
            const results = [];
            const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
            window.__pwn = 0;
            const breakout = 'red" onmouseover="window.__pwn = 1" data-x="';
            const canvas = JSON.stringify({ nodes: [
              { id: 'n1', type: 'text', text: 'a', x: 0, y: 0, width: 100, height: 60, color: breakout },
              { id: 'n2', type: 'text', text: 'b', x: 200, y: 0, width: 100, height: 60, color: '4' },
              { id: 'n3', type: 'text', text: 'c', x: 400, y: 0, width: 100, height: 60, color: '"><img src=x onerror=window.__pwn=2>' },
              { id: 'n4', type: 'text', text: 'd', x: 600, y: 0, width: 100, height: 60, color: 'rgb(1, 2, 3)' },
              { id: 'n5', type: 'text', text: 'e', x: 800, y: 0, width: 100, height: 60, color: 'url(https://evil.invalid/x.png)' },
              { id: 'n6', type: 'text', text: 'f', x: 1000, y: 0, width: 100, height: 60, color: 'tomato' }
            ], edges: [
              { id: 'e1', fromNode: 'n1', toNode: 'n2', color: breakout },
              { id: 'e2', fromNode: 'n2', toNode: 'n3', color: '#44cf6e' },
              { id: 'e3', fromNode: 'n3', toNode: 'n4', color: 'var(--x)' }
            ] });
            window.setStructuredContent(canvas, 'canvas');
            for (let i = 0; i < 50 && !document.querySelector('.canvas-node'); i++) await new Promise(r => setTimeout(r, 100));
            function pick(selector) {
                document.querySelector(selector).dispatchEvent(new MouseEvent('click', { bubbles: true }));
                const swatch = document.querySelector('.canvas-props .canvas-swatch');
                return { swatch, attrs: swatch ? Array.from(swatch.attributes).map(a => a.name).join(',') : '', imgs: document.querySelectorAll('.canvas-props img').length };
            }
            for (const id of ['n1', 'n3', 'n5']) {
                const p = pick('.canvas-node[data-node-id="' + id + '"]');
                note('node ' + id + ': a hostile colour adds no attribute and no element to the properties panel', !!p.swatch && p.attrs === 'class,style' && p.imgs === 0 && p.swatch.style.background === '', p.attrs + ' imgs ' + p.imgs);
            }
            for (const [id, painted] of [['n2', 'rgb(68, 207, 110)'], ['n4', 'rgb(1, 2, 3)'], ['n6', 'tomato']]) {
                const p = pick('.canvas-node[data-node-id="' + id + '"]');
                note('node ' + id + ': a preset, rgb() or a colour name still paints the swatch', !!p.swatch && p.swatch.style.background === painted, p.swatch && p.swatch.getAttribute('style'));
            }
            for (const id of ['e1', 'e3']) {
                const p = pick('.canvas-edge[data-edge-id="' + id + '"]');
                note('edge ' + id + ': a hostile colour adds no attribute and no element to the properties panel', !!p.swatch && p.attrs === 'class,style' && p.imgs === 0 && p.swatch.style.background === '', p.attrs);
                const line = document.querySelector('.canvas-edge[data-edge-id="' + id + '"] .canvas-edge-line');
                note('edge ' + id + ': the line keeps the default colour', line.style.stroke === 'var(--cv-edge-color)', line.style.stroke);
            }
            const good = pick('.canvas-edge[data-edge-id="e2"]');
            note('edge e2: a hex colour still paints the swatch', !!good.swatch && good.swatch.style.background === 'rgb(68, 207, 110)', good.swatch && good.swatch.getAttribute('style'));
            await new Promise(r => setTimeout(r, 300));
            note('nothing the colours carried ran', window.__pwn === 0, window.__pwn);
            return JSON.stringify(results);
            """#)

        // 3. A result kind in the list of definitions.
        runChecks("code peek", #"""
            const results = [];
            const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
            window.__pwn = 0;
            window.setCodeContent('const a = 1;\n', 'javascript', 'a.js');
            await new Promise(r => setTimeout(r, 500));
            window.onCodeNavEvent({ type: 'definitions', name: 'foo', results: [
                { path: 'src/a.js', line: 1, kind: '<img src=x onerror=window.__pwn=3>', text: 'function foo() {}' },
                { path: 'src/a.js', line: 2, kind: 'function', text: 'foo(<b>x</b>)' },
                { path: 'src/b.js', line: 3, kind: 'usage', text: 'foo()' }
            ] });
            await new Promise(r => setTimeout(r, 300));
            const rows = Array.from(document.querySelectorAll('.code-peek-row'));
            note('the list shows its three results', rows.length === 3, rows.length);
            note('a result kind with markup adds no element to the list', document.querySelectorAll('.code-peek img').length === 0 && document.querySelectorAll('.code-peek .tx b').length === 0, document.querySelectorAll('.code-peek img').length);
            note('the kind is shown as text', rows[0] && rows[0].querySelector('i') && rows[0].querySelector('i').textContent === '<img src=x onerror=window.__pwn=3>', rows[0] && rows[0].innerHTML);
            note('an ordinary kind is still shown before the line', rows[1] && rows[1].querySelector('i') && rows[1].querySelector('i').textContent === 'function', rows[1] && rows[1].innerHTML);
            note('a usage has no kind and the name is still marked', rows[2] && !rows[2].querySelector('i') && rows[2].querySelector('mark') && rows[2].querySelector('mark').textContent === 'foo', rows[2] && rows[2].innerHTML);
            await new Promise(r => setTimeout(r, 300));
            note('nothing the kind carried ran', window.__pwn === 0, window.__pwn);
            return JSON.stringify(results);
            """#)

        // 4. Text and attribute escaping (AR-29): every page script escapes through mvKit.escapeHtml / escapeAttr. Hostile text and quote
        //    characters are shown as text, add no element, and come back unchanged through an attribute.
        runChecks("escaping", #"""
            const results = [];
            const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
            window.__pwn = 0;
            const hostile = '<img src=x onerror=window.__pwn=4>';
            window.setStructuredContent(JSON.stringify({ [hostile]: 'it\'s "quoted" <b>bold</b> & more', list: [hostile] }), 'json');
            await new Promise(r => setTimeout(r, 400));
            const tree = document.getElementById('editor-rendered');
            note('the JSON tree adds no element for a hostile key or value', tree.querySelectorAll('img, b').length === 0, tree.innerHTML.slice(0, 300));
            note('a JSON key is shown as text', Array.from(tree.querySelectorAll('.struct-key')).some(k => k.textContent === '"' + hostile + '"'), tree.innerHTML.slice(0, 300));
            note('a JSON value with both quote characters is shown as it is', Array.from(tree.querySelectorAll('.struct-value')).some(v => v.textContent === '"it\'s "quoted" <b>bold</b> & more"'), tree.innerHTML.slice(0, 300));
            window.setContent('---\ntitle: ' + hostile + ' it\'s\ntags: [a\'b, "c"]\n---\n\n# Heading\n\n[[Some "page" it\'s|label <b>x</b>]]\n\n$a\'+`b`$\n');
            await new Promise(r => setTimeout(r, 600));
            const page = document.getElementById('editor-rendered');
            const panel = page.querySelector('.frontmatter-panel');
            note('the front matter panel adds no element for a hostile value', !!panel && panel.querySelectorAll('img').length === 0, panel && panel.innerHTML.slice(0, 300));
            note('the front matter value is shown as text', !!panel && panel.textContent.includes(hostile + " it's"), panel && panel.textContent);
            const link = page.querySelector('a.wikilink');
            note('a wikilink target with quote characters comes back unchanged from its attribute', !!link && link.getAttribute('data-wikilink') === 'Some "page" it\'s', link && link.outerHTML);
            note('a wikilink label is shown as text', !!link && link.textContent.includes('label <b>x</b>') && link.querySelectorAll('b').length === 0, link && link.outerHTML);
            const math = page.querySelector('.math-inline');
            note('inline math keeps its source, quote and backtick included, in its attribute', !!math && math.getAttribute('data-tex') === "a'+`b`", math && math.outerHTML.slice(0, 200));
            await new Promise(r => setTimeout(r, 300));
            note('nothing the hostile text carried ran', window.__pwn === 0, window.__pwn);
            return JSON.stringify(results);
            """#)

    }
}


extension EditorHostTests {
    @MainActor func testEditorBaselineSecurity() async throws {
        func check(_ label: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, label, line: line)
        }
        @MainActor
        func loadFile(_ file: URL, allowingReadAccessTo dir: URL, readyJS: String, userScripts: [WKUserScript] = []) async -> WKWebView? {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            for script in userScripts { config.userContentController.addUserScript(script) }
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            webView.loadFileURL(file, allowingReadAccessTo: dir)
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let res = try? await webView.evaluateJavaScript(readyJS) as? Bool, res {
                    return webView
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return nil
        }

        let editorDir = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent()

        // 1. Vendored offline dependencies & externalized scripts exist on disk (AR-01, AR-03)
        for relPath in [
            "vendor/js/dompurify.min.js",
            "vendor/js/turndown.min.js",
            "vendor/js/turndown-plugin-gfm.min.js",
            "js/mv-kit.js",
            "js/markview-terminal.js"
        ] {
            check("AR-01/AR-03: \(relPath) exists locally",
                  FileManager.default.fileExists(atPath: editorDir.appendingPathComponent(relPath).path))
        }

        // 2. Live WebKit check of AR-01/AR-02/AR-03/FU-10/FU-13 sanitization, style filtering, TOC escaping, SVG sanitization & CSP
        // The app's own nonce and nonce script (EditorPage, FU-26), not a copy of them.
        let nonce = EditorPage.makeNonce()
        let nonceScript = WKUserScript(source: EditorPage.nonceScript(nonce), injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let webView = await loadFile(
            editorDir.appendingPathComponent("index.html"),
            allowingReadAccessTo: editorDir,
            readyJS: "typeof window.setContent === 'function' && typeof window.DOMPurify !== 'undefined' && typeof window.mvKit === 'object' && typeof window.mvKit.sanitizeHtml === 'function' && typeof window.TurndownService === 'function'",
            userScripts: [nonceScript]
        )
        check("AR-01/AR-03: shipping index.html loads DOMPurify, mvKit, and TurndownService offline", webView != nil)

        if let webView {
            let indexCspMeta = (try? await webView.evaluateJavaScript("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')?.content || ''") as? String) ?? ""
            check("AR-01: index.html runtime CSP enforces script-src without unsafe-inline",
                  indexCspMeta.contains("script-src 'self' 'wasm-unsafe-eval'") && !indexCspMeta.contains("script-src 'self' 'unsafe-inline'"))

            let mdCheck = try await webView.evaluateJavaScript(#"""
                (function() {
                    window.__xssFired = false;
                    window.setContent(
                        '# &lt;img id="toc-evil" src="x"&gt;SafeHeading\n\n' +
                        '<style>body { background: url(https://evil.example/leak); }</style>' +
                        '<div id="styled-bad" style="position:fixed;z-index:9999;background-image:url(https://evil.example/s.png);color:red">styled</div>' +
                        '<span class="katex-like" style="height:1.5em;top:-0.2em">math</span>' +
                        '<script>window.__xssFired = true;</script>' +
                        '<img src=x onerror="window.__xssFired=true">' +
                        '<a href="javascript:window.__xssFired=true">js</a>' +
                        '<a href="file:///etc/passwd">f</a>' +
                        '<a href="data:text/html,<script>1</script>">dh</a>' +
                        '<img src="data:image/svg+xml,<svg onload=1>">' +
                        '<img src="data:image/png;base64,AAA=">',
                        'preview'
                    );
                    var rendered = document.getElementById('editor-rendered').innerHTML;
                    var lower = rendered.toLowerCase();
                    var styledBad = document.getElementById('styled-bad');
                    var mathEl = document.querySelector('.katex-like');
                    var tocImgCount = document.querySelectorAll('#toc-status img').length;
                    var tocText = (document.getElementById('toc-status') || {}).textContent || '';

                    var svgClean = window.mvKit.sanitizeMermaidSvg('<svg id="s1" viewBox="0 0 10 10"><style>body{display:none} #s1 rect{fill:red}</style><script>evil()</script><rect width="10" height="10" onclick="evil()"/></svg>');

                    var savedPurify = window.DOMPurify;
                    var stripWhenMissing = '';
                    try {
                        window.DOMPurify = undefined;
                        stripWhenMissing = window.sanitizeMarkdownHTML('<img src=x onerror=alert(1)>');
                    } finally {
                        window.DOMPurify = savedPurify;
                    }
                    return JSON.stringify({
                        xssFired: window.__xssFired,
                        hasScript: lower.indexOf('<script') >= 0,
                        hasStyleTag: lower.indexOf('<style') >= 0,
                        hasOnerror: lower.indexOf('onerror') >= 0,
                        hasJavascriptHref: lower.indexOf('javascript:') >= 0,
                        hasFileScheme: lower.indexOf('file:///') >= 0,
                        hasDataHTML: lower.indexOf('data:text/html') >= 0,
                        hasDataSVG: lower.indexOf('data:image/svg+xml') >= 0,
                        hasPngData: lower.indexOf('data:image/png;base64,aaa=') >= 0,
                        hasHeading: rendered.indexOf('SafeHeading') >= 0,
                        badStyleStripped: !!styledBad && styledBad.style.position === '' && styledBad.style.zIndex === '' && styledBad.style.backgroundImage === '' && styledBad.style.color === 'red',
                        mathStyleKept: !!mathEl && mathEl.style.height === '1.5em' && mathEl.style.top === '-0.2em',
                        tocEscaped: tocImgCount === 0 && tocText.indexOf('SafeHeading') >= 0,
                        svgSafe: svgClean.indexOf('<svg') >= 0 && svgClean.indexOf('<rect') >= 0 && svgClean.indexOf('<script') < 0 && svgClean.indexOf('onclick') < 0 && svgClean.indexOf('body{') < 0 && svgClean.indexOf('#s1 rect{fill') >= 0,
                        failClosed: stripWhenMissing.indexOf('sanitization-error') >= 0 && stripWhenMissing.indexOf('<img') < 0,
                        cdnStripped: window.stripCDNTags('<canvas data-chart=\'{"type":"bar"}\'></canvas><style>p{color:red}</style><script>evil()</script><img src=x onerror=alert(1)>')
                    });
                })()
            """#) as? String ?? "{}"

            if let mdData = mdCheck.data(using: .utf8),
               let mdObj = try? JSONSerialization.jsonObject(with: mdData) as? [String: Any] {
                check("AR-01/FU-13: untrusted Markdown script, <style>, dangerous CSS, onerror, javascript:, file:, data:text/html, and data:image/svg+xml are stripped while safe PNG, KaTeX styles, and heading survive",
                      (mdObj["xssFired"] as? Bool) == false &&
                      (mdObj["hasScript"] as? Bool) == false &&
                      (mdObj["hasStyleTag"] as? Bool) == false &&
                      (mdObj["hasOnerror"] as? Bool) == false &&
                      (mdObj["hasJavascriptHref"] as? Bool) == false &&
                      (mdObj["hasFileScheme"] as? Bool) == false &&
                      (mdObj["hasDataHTML"] as? Bool) == false &&
                      (mdObj["hasDataSVG"] as? Bool) == false &&
                      (mdObj["hasPngData"] as? Bool) == true &&
                      (mdObj["hasHeading"] as? Bool) == true &&
                      (mdObj["badStyleStripped"] as? Bool) == true &&
                      (mdObj["mathStyleKept"] as? Bool) == true)
                check("AR-01 (10.3): updateTOCStatus escapes heading HTML instead of injecting live DOM nodes",
                      (mdObj["tocEscaped"] as? Bool) == true)
                check("AR-01 (10.3)/FU-20: mvKit.sanitizeMermaidSvg strips <script> and event handlers from SVG and keeps only the style rules that start at the SVG's own id",
                      (mdObj["svgSafe"] as? Bool) == true)
                let cdnStripped = (mdObj["cdnStripped"] as? String) ?? ""
                check("FU-13/AR-02: sanitizeMarkdownHTML fails closed without DOMPurify and stripCDNTags uses shared sanitizer",
                      (mdObj["failClosed"] as? Bool) == true &&
                      cdnStripped.contains("data-chart") &&
                      !cdnStripped.contains("evil()") &&
                      !cdnStripped.lowercased().contains("<style"))
            } else {
                check("AR-01/FU-13: live index.html check returned valid JSON", false)
            }

            // Verify buildInsightSrcdoc uses strict nonce-only policy (no blob:/data:) and fails closed to 'none' without nonce
            _ = try? await webView.evaluateJavaScript(#"""
                (function() {
                    window.__srcdocCheckResult = null;
                    Promise.resolve().then(async function() {
                        var parser = new DOMParser();
                        function extractScriptSrc(html) {
                            var doc = parser.parseFromString(html, 'text/html');
                            var m = doc.querySelector('meta[http-equiv="Content-Security-Policy"]');
                            var content = m ? (m.getAttribute('content') || '') : '';
                            var match = content.match(/(?:^|;)\s*(script-src\s+[^;]+)/i);
                            return match ? match[1].trim() : '';
                        }
                        var withNonceHtml = await window.buildInsightSrcdoc({ title: 'T', sections: [] }, '');
                        var savedNonce = window.__markviewInsightNonce;
                        var withoutNonceHtml = '';
                        try {
                            window.__markviewInsightNonce = undefined;
                            withoutNonceHtml = await window.buildInsightSrcdoc({ title: 'T', sections: [] }, '');
                        } finally {
                            window.__markviewInsightNonce = savedNonce;
                        }
                        window.__srcdocCheckResult = JSON.stringify({
                            withNonceScriptSrc: extractScriptSrc(withNonceHtml),
                            withoutNonceScriptSrc: extractScriptSrc(withoutNonceHtml)
                        });
                    }).catch(function(err) {
                        window.__srcdocCheckResult = JSON.stringify({ error: String(err) });
                    });
                })()
            """#)
            var srcdocRes: String?
            let srcdocDeadline = Date().addingTimeInterval(5)
            while srcdocRes == nil && Date() < srcdocDeadline {
                if let value = try? await webView.evaluateJavaScript("window.__srcdocCheckResult") as? String {
                    srcdocRes = value
                    break
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }

            if let sData = (srcdocRes ?? "{}").data(using: .utf8),
               let sObj = try? JSONSerialization.jsonObject(with: sData) as? [String: String] {
                let withNonceScriptSrc = sObj["withNonceScriptSrc"] ?? ""
                let withoutNonceScriptSrc = sObj["withoutNonceScriptSrc"] ?? ""
                check("FU-10/AR-02: buildInsightSrcdoc uses nonce-only script-src without blob: or data:",
                      withNonceScriptSrc == "script-src 'nonce-\(nonce)'")
                check("FU-10/AR-02: buildInsightSrcdoc fails closed to script-src 'none' when nonce is missing",
                      withoutNonceScriptSrc == "script-src 'none'")
            } else {
                check("FU-10/AR-02: buildInsightSrcdoc async check returned valid JSON", false)
            }
        }

        // 3. Live WebKit check of book.html, discussion.html, and terminal.html strict CSP + external scripts
        for pageName in ["book.html", "discussion.html"] {
            let pageWeb = await loadFile(
                editorDir.appendingPathComponent(pageName),
                allowingReadAccessTo: editorDir,
                readyJS: "typeof window.DOMPurify === 'function' && typeof window.markdownit === 'function' && typeof window.mvKit === 'object' && typeof window.mvKit.sanitizeHtml === 'function'"
            )
            var cspOK = false
            var inlineCount = -1
            if let pageWeb {
                let csp = (try? await pageWeb.evaluateJavaScript("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')?.content || ''") as? String) ?? ""
                inlineCount = (try? await pageWeb.evaluateJavaScript("document.querySelectorAll('script:not([src])').length") as? Int) ?? -1
                cspOK = csp.contains("script-src 'self';") && !csp.contains("script-src 'self' 'unsafe-inline'")
            }
            check("AR-01/FU-13: \(pageName) runs offline under script-src 'self' with mvKit and 0 inline scripts (inline=\(inlineCount))",
                  pageWeb != nil && cspOK && inlineCount == 0)
        }

        let termWeb = await loadFile(
            editorDir.appendingPathComponent("terminal.html"),
            allowingReadAccessTo: editorDir,
            readyJS: "typeof window.mvWrite === 'function' && typeof window.mvSetTheme === 'function' && typeof window.mvKit === 'object'"
        )
        var termCSPOK = false
        var termInlineCount = -1
        if let termWeb {
            let csp = (try? await termWeb.evaluateJavaScript("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')?.content || ''") as? String) ?? ""
            termInlineCount = (try? await termWeb.evaluateJavaScript("document.querySelectorAll('script:not([src])').length") as? Int) ?? -1
            termCSPOK = csp.contains("script-src 'self';") && !csp.contains("script-src 'self' 'unsafe-inline'")
        }
        check("AR-01 (10.3): terminal.html runs under strict CSP script-src 'self' with 0 inline scripts (inline=\(termInlineCount))",
              termWeb != nil && termCSPOK && termInlineCount == 0)

        // 4. Live WebKit check of CSP nonce blocking un-nonced scripts in parent & srcdoc while allowing nonced script
        final class ProbeHandler: NSObject, WKScriptMessageHandler {
            var message: String?
            func userContentController(_ userContentController: WKUserContentController, didReceive msg: WKScriptMessage) {
                message = msg.body as? String
            }
        }
        let handler = ProbeHandler()
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.userContentController.add(handler, name: "probe")
        let nonceWeb = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
        defer { nonceWeb.stopLoading(); cfg.userContentController.removeScriptMessageHandler(forName: "probe") }
        // The parent page's policy is the shipped index.html's own Content-Security-Policy element after the app's own injection
        // (EditorPage.injectNonce), not a hand-built copy that could drift from it (FU-26).
        let shippedIndex = (try? String(contentsOf: editorDir.appendingPathComponent("index.html"), encoding: .utf8)) ?? ""
        let injectedIndex = EditorPage.injectNonce(nonce, into: shippedIndex) ?? ""
        let rawMeta = injectedIndex.range(of: #"<meta http-equiv="Content-Security-Policy"[^>]*>"#, options: .regularExpression).map { String(injectedIndex[$0]) } ?? ""
        check("FU-26: EditorPage.injectNonce puts the nonce into script-src of the shipped index.html policy",
              rawMeta.contains("script-src 'self' 'wasm-unsafe-eval' 'nonce-\(nonce)'"))
        let childCSP = "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; connect-src 'none'; img-src data: blob:; font-src data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
        let srcdoc = "<!DOCTYPE html><meta http-equiv='Content-Security-Policy' content=\"\(childCSP)\"><script>window.__unnonced=1; parent.postMessage({evil:true},'*');</script><script nonce='\(nonce)'>parent.postMessage({good:true, unnonced: !!window.__unnonced},'*');</script>"
        let srcdocJSON = String(data: try JSONSerialization.data(withJSONObject: srcdoc, options: .fragmentsAllowed), encoding: .utf8)!
        let nonceParentHTML = """
        <!DOCTYPE html><html><head>\(rawMeta)</head><body>
        <script>window.__unnoncedParent = true;</script>
        <script nonce="\(nonce)">
        window.addEventListener('message', function(ev) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.probe) {
                window.webkit.messageHandlers.probe.postMessage(JSON.stringify({ origin: ev.origin, data: ev.data, parentUnnonced: !!window.__unnoncedParent }));
            }
        });
        var f = document.createElement('iframe');
        f.sandbox = 'allow-scripts';
        f.srcdoc = \(srcdocJSON);
        document.body.appendChild(f);
        </script></body></html>
        """
        nonceWeb.loadHTMLString(nonceParentHTML, baseURL: nil)
        let nonceDeadline = Date().addingTimeInterval(5)
        while handler.message == nil && Date() < nonceDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let msg = handler.message ?? ""
        if let msgData = msg.data(using: .utf8),
           let msgObj = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any],
           let dataObj = msgObj["data"] as? [String: Any] {
            check("FU-10: Nonced CSP blocks un-nonced parent and srcdoc scripts while allowing nonced Insight iframe execution",
                  (dataObj["good"] as? Bool) == true &&
                  dataObj["evil"] == nil &&
                  (dataObj["unnonced"] as? Bool) == false &&
                  (msgObj["parentUnnonced"] as? Bool) == false)
        } else {
            check("FU-10: Nonced CSP iframe test received structured probe message", false)
        }
    }
}
