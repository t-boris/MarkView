import AppKit
import Foundation
import WebKit
import XCTest
import MarkViewCore
@testable import MarkView

final class XRayContentHostTests: XCTestCase {
    func testContentHierarchy() throws {
var failures = 0
var checks = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "ok" : "FAIL")  \(name)")
    checks += 1
    if !condition { failures += 1 }
}

let local = XRayContent.codeOutline(text: "func first() {}\nfunc second() {}\nfunc third() {}", language: "swift", signature: "fixture")!
let localNodes = XRayContent.nodes(for: local, path: "Small.swift", fileId: "file")
check("short code keeps all declarations directly under file",
      localNodes.count == 3 && localNodes.allSatisfy { $0.kind == "entity" && $0.parent == "file" })

func item(_ name: String, _ line: Int) -> XRayContent.Item {
    .init(name: name, line: line, summary: nil, anchor: nil)
}
func group(_ name: String, _ items: [XRayContent.Item]) -> XRayContent.Group {
    .init(name: name, items: items)
}
func part(_ name: String, _ groups: [XRayContent.Group]) -> XRayContent.Collection {
    .init(name: name, summary: nil, groups: groups)
}
func outline(_ collections: [XRayContent.Collection]) -> XRayContent.Outline {
    .init(signature: "fixture", collections: collections, source: "ai", language: "English")
}

let sparse = outline([
    part("State", [group("Helpers", [item("parse", 10), item("clean", 20)])]),
    part("Actions", [group("Functions", [item("start", 30), item("stop", 40)])]),
])
let sparseNodes = XRayContent.nodes(for: sparse, path: "Module.swift", fileId: "file")
check("sparse AI parts and groups add no levels",
      sparseNodes.count == 4 && sparseNodes.allSatisfy { $0.kind == "entity" && $0.parent == "file" })
check("sparse items keep source lines", sparseNodes.compactMap(\.line) == [10, 20, 30, 40])
check("flattened items keep stable IDs", sparseNodes.map(\.id) == [
    "l:e:Module.swift#0.0.0", "l:e:Module.swift#0.0.1",
    "l:e:Module.swift#1.0.0", "l:e:Module.swift#1.0.1",
])

let dense = outline([
    part("Parsing", [group("Helpers", [item("a", 1), item("b", 2), item("c", 3), item("d", 4)]),
                     group("Functions", [item("e", 5), item("f", 6)])]),
    part("Output", [group("Rendering", [item("g", 7), item("h", 8), item("i", 9), item("j", 10)])]),
])
let denseNodes = XRayContent.nodes(for: dense, path: "Module.swift", fileId: "file")
let byName = Dictionary(uniqueKeysWithValues: denseNodes.map { ($0.name, $0) })
check("useful parts stay visible", byName["Parsing"]?.parent == "file" && byName["Output"]?.parent == "file")
check("four-item group stays visible", byName["Helpers"]?.parent == byName["Parsing"]?.id)
check("two-item group is flattened", byName["Functions"] == nil && byName["e"]?.parent == byName["Parsing"]?.id)
check("single group adds no redundant level", byName["Rendering"] == nil && byName["g"]?.parent == byName["Output"]?.id)
check("every item is reachable", denseNodes.filter { $0.kind == "entity" }.count == 10 &&
      denseNodes.filter { $0.kind == "entity" }.allSatisfy { $0.line != nil })

let lone = outline([part("Declarations", [group("Types", [item("A", 1), item("B", 2), item("C", 3), item("D", 4)])])])
let loneNodes = XRayContent.nodes(for: lone, path: "Types.swift", fileId: "file")
check("one part with one group adds no redundant levels",
      loneNodes.count == 4 && loneNodes.allSatisfy { $0.kind == "entity" && $0.parent == "file" })

let untyped = outline([part("Mixed", [group("", [item("a", 1), item("b", 2), item("c", 3), item("d", 4)]),
                                      group("Public API", [item("e", 5), item("f", 6), item("g", 7), item("h", 8)])])])
let untypedNodes = XRayContent.nodes(for: untyped, path: "Mixed.swift", fileId: "file")
check("unnamed group does not become Other", !untypedNodes.contains { $0.kind == "group" && $0.name == "Other" })
check("useful named group remains under file", untypedNodes.first { $0.name == "Public API" }?.parent == "file")

// BUG-015: the shipping index.html used to enter the 300-second AI queue on every
// analysis without a successful outline cache, despite its useful local structure.
let html = try String(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor")), encoding: .utf8)
let htmlOutline = XRayContent.localOutline(text: html, language: "html", signature: "fixture")
let htmlItems = htmlOutline?.collections.flatMap(\.groups).flatMap(\.items) ?? []
check("shipping index.html has local regions", htmlOutline?.source == "structure" && htmlItems.count >= 10)
// The expected line is read from the file: index.html grows above the region over time.
let archContainerLine = (html.editorLines.firstIndex { $0.contains("id=\"arch-container\"") } ?? -2) + 1
check("HTML regions retain exact lines", htmlItems.contains { $0.name == "arch-container" && $0.line == archContainerLine })
let simpleHTML = "<html>\n<h1>Overview</h1>\n<section>Text</section>\n<h2>Details</h2>\n</html>"
let headingItems = XRayContent.localOutline(text: simpleHTML, language: "html", signature: "fixture")?
    .collections.flatMap(\.groups).flatMap(\.items) ?? []
check("HTML without IDs uses headings", headingItems.map(\.name) == ["Overview", "Details"])
let longSwift = Array(repeating: "// filler", count: 250).joined(separator: "\n") + "\nfunc one() {}\nfunc two() {}"
check("long code has a local outline",
      XRayContent.localOutline(text: longSwift, language: "swift", signature: "fixture")?.source == "structure")
let markdown = "# Title\n\n~~~swift\n# Not a heading\n~~~\n\n## First\nText\n## Second\n"
let markdownItems = XRayContent.localOutline(text: markdown, language: "markdown", signature: "fixture")?
    .collections.flatMap(\.groups).flatMap(\.items) ?? []
check("Markdown headings are outlined locally without code fences",
      markdownItems.map(\.name) == ["Title", "First", "Second"] &&
      markdownItems.map(\.line) == [1, 7, 9])

let root = FileManager.default.temporaryDirectory.appendingPathComponent("xray-content-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let file = root.appendingPathComponent("index.html")
try html.write(to: file, atomically: true, encoding: .utf8)
let signature = XRayContent.signature(of: file)!
let cached = XRayContent.localOutline(text: html, language: "html", signature: signature)!
XRayContent.save(cached, root: root, path: "index.html")
check("unchanged file reuses saved outline",
      XRayContent.loadFresh(root: root, paths: ["index.html"])["index.html"]?.signature == signature)
try (html + "\n").write(to: file, atomically: true, encoding: .utf8)
check("changed file invalidates saved outline",
      XRayContent.loadFresh(root: root, paths: ["index.html"]).isEmpty)
// A saved outline that cannot be read is a miss that is logged, not a crash and not a stale outline; the next save replaces it (AR-36).
try html.write(to: file, atomically: true, encoding: .utf8)
// The signature holds the modification time in milliseconds, so the rewrite above has a new one: the outline is made for it. A URL
// value caches its resource values, so the signature is read through a new URL, as the store does for every file.
let signatureNow = XRayContent.signature(of: root.appendingPathComponent("index.html"))!
let cachedNow = XRayContent.localOutline(text: html, language: "html", signature: signatureNow)!
XRayContent.save(cachedNow, root: root, path: "index.html")
let cacheFolder = XRayContent.cacheDirectory(root: root)
let cacheFiles = ((try? FileManager.default.contentsOfDirectory(atPath: cacheFolder.path)) ?? []).filter { $0.hasSuffix(".json") }
check("the saved outline is one file of the cache", cacheFiles.count == 1)
if let name = cacheFiles.first {
    let outlineFile = cacheFolder.appendingPathComponent(name)
    try Data("{ \"signature\": ".utf8).write(to: outlineFile)
    check("a damaged saved outline is a miss", XRayContent.loadFresh(root: root, paths: ["index.html"]).isEmpty)
    XRayContent.save(cachedNow, root: root, path: "index.html")
    check("and the next save replaces it", XRayContent.loadFresh(root: root, paths: ["index.html"])["index.html"]?.signature == signatureNow)
}

struct TestTimeout: LocalizedError {
    var errorDescription: String? { "Codex did not finish within 60 s." }
}
let message = XRayContent.outlineFailureMessage(path: "src/index.html", error: TestTimeout())
check("AI timeout is identified as outlining rather than reading",
      message.contains("Could not outline index.html") && message.contains("60 s") &&
      !message.contains("Could not read"))

        print("X-Ray content hosted checks: \(checks)")
        XCTAssertEqual(failures, 0)
    }
}


extension XRayContentHostTests {
    @MainActor func testLogicalLayoutInHiddenWebView() throws {
        let editor = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent().path
        func check(_ ok: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(ok, "\(message): \(detail.prefix(700))", line: line)
        }
        final class Bridge: NSObject, WKScriptMessageHandler {
            var messages: [[String: Any]] = []
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                if let body = message.body as? [String: Any] { messages.append(body) }
            }
            /// The payloads the page posted for one X-Ray action.
            func sent(_ action: String) -> [[String: Any]] {
                messages.compactMap { $0["payload"] as? [String: Any] }.filter { $0["action"] as? String == action }
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
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900), configuration: config)
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
        func js(_ body: String, timeout: TimeInterval = 30) -> String {
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

        spin(20) { loaded.done }
        check(loaded.done, "shipping editor loaded")

        // A small project (Logical and Structure views), and a comparison with an earlier commit: two changed files, one new file,
        // and two removed ones - one in a folder that still exists (src/ui) and one in a folder that is gone (src/legacy).
        let prelude = """
        window.make = function(opts) {
            opts = opts || {};
            const sha = 'a'.repeat(40);
            const sizes = { 'src/core/engine.js': 120, 'src/core/util.js': 40, 'src/core/fresh.js': 30, 'src/ui/view.js': 200, 'src/ui/panel.js': 80 };
            const owner = path => path.startsWith('src/core') ? 'core' : 'ui';
            const modules = [{ id: 'm:', kind: 'root', name: 'project', files: 5, loc: 470 },
                { id: 'm:src', parent: 'm:', kind: 'dir', name: 'src', path: 'src', files: 5 },
                { id: 'm:src/core', parent: 'm:src', kind: 'dir', name: 'core', path: 'src/core', files: 3 },
                { id: 'm:src/ui', parent: 'm:src', kind: 'dir', name: 'ui', path: 'src/ui', files: 2 }];
            const logical = [{ id: 'l:', kind: 'root', name: 'project' },
                { id: 'l:c:core', parent: 'l:', kind: 'component', name: 'Core', files: 3 },
                { id: 'l:c:ui', parent: 'l:', kind: 'component', name: 'UI', files: 2 }];
            const metrics = {};
            Object.keys(sizes).forEach(path => {
                modules.push({ id: 'm:' + path, parent: 'm:src/' + path.split('/')[1], kind: 'file', name: path.split('/').pop(), path, language: 'javascript', loc: sizes[path], files: 1 });
                logical.push({ id: 'l:f:' + path, parent: 'l:c:' + owner(path), kind: 'file', name: path.split('/').pop(), path, language: 'javascript', loc: sizes[path], files: 1 });
                metrics['m:' + path] = { loc: sizes[path], complexity: 10, commits: 3, bugfixes: 0, isTest: false, tested: true, testFiles: [], lastChanged: 1790000000,
                    functions: 4, maxFunctionComplexity: path.includes('engine') ? 25 : 3, maxFunctionName: 'run', complexFunctions: path.includes('engine') ? 1 : 0 };
            });
            const files = [
                { path: 'src/core/engine.js', additions: 10, deletions: 2, ranges: [[5, 14]] },
                { path: 'src/ui/view.js', additions: 3, deletions: 1, ranges: [[20, 22]] },
                { path: 'src/core/fresh.js', additions: 30, deletions: 0, ranges: [[1, 30]] },
                { path: 'src/ui/old-panel.js', additions: 0, deletions: 60, ranges: [], deleted: true },
                { path: 'src/legacy/old.js', additions: 0, deletions: 40, ranges: [], deleted: true }];
            const payload = {
                mode: opts.folder ? 'folder' : opts.project ? undefined : 'pr', root: '/tmp/project', busy: false, filters: [], describing: [], outlining: [],
                searchSummaries: {}, searchAnswers: {}, understandingAnswers: {}, edgeNotes: {}, codeSequenceDiagrams: [], codeSequenceInfo: [],
                automaticState: {}, automaticAnalysis: true,
                snapshot: { views: [{ id: 'modules', nodes: modules, edges: [] }, { id: 'logical', nodes: logical, edges: [{ source: 'l:f:src/ui/view.js', target: 'l:f:src/core/engine.js', kind: 'imports', weight: 1 }] }],
                    coverage: {}, metrics, deploymentHints: [], scannedAt: '2026-11-08T10:00:00Z',
                    components: [{ id: 'core', name: 'Core', purpose: 'The engine' }, { id: 'ui', name: 'UI', purpose: 'The screens' }],
                    assignments: { 'src/core': { component: 'core' }, 'src/ui': { component: 'ui' }, 'src': { component: 'core' } }, overrides: {} },
                prSources: [{ id: 'local', title: 'All changes vs main' }, { id: 'at:' + sha, title: 'Working copy vs aaaaaaaa (2026-11-05 14:32) Fix it' }],
                pr: opts.noChange ? undefined : { source: { id: 'at:' + sha, title: 'Working copy vs aaaaaaaa (2026-11-05 14:32) Fix it' }, files, reviewed: false, dependencies: [], chat: [],
                    analysis: opts.analysis ? { summary: 'Touches the engine', verdict: 'attention', impact: [{ component: 'core', risk: 'low', note: 'Small and covered' }], risks: [], checks: [] } : undefined },
                history: opts.history };
            return JSON.parse(JSON.stringify(payload));
        };
        window.cyNow = () => document.getElementById('arch-graph')._cyreg.cy;
        window.settle = async function(minNodes) {
            for (let i = 0; i < 300; i++) {
                const g = document.getElementById('arch-graph')._cyreg;
                if (g && g.cy && g.cy.nodes().length >= (minNodes || 1)) break;
                await new Promise(r => setTimeout(r, 50));
            }
            await new Promise(r => setTimeout(r, 900));
        };
        window.node = id => window.cyNow().getElementById(id);
        window.info = id => { const n = window.node(id); return n.length ? { label: n.data('label'), changed: n.data('changed'), removed: n.data('removed'), dimmed: n.data('dimmed'),
            fill: n.data('fill'), parent: n.parent().length ? n.parent().id() : '', border: n.style('border-style'), halo: Number(n.style('underlay-opacity')), w: n.data('w') } : null; };
        """
        _ = js(prelude + "return 'ready';")


        /// The Logical view of eight components linked as in the report (CLI -> Desktop -> Trading -> Brokers -> Docs, all to External).
        let fixture = """
        window.fixture = function(extra) {
            const comps = [['Installer and Deploy', 31, 6100], ['CLI and Control Plane', 401, 103000], ['StrikeDesk Desktop', 1200, 302000], ['Trading Core', 64, 13000],
                ['Brokers and Contracts', 288, 109000], ['Ops Tooling', 21, 3600], ['Documentation', 1800, 183000]];
            const logical = [{ id: 'l:', kind: 'root', name: 'project' }];
            comps.forEach((c, i) => logical.push({ id: 'l:c:' + i, parent: 'l:', kind: 'component', name: c[0], purpose: 'Purpose of the component ' + i + ' that wraps over a couple of lines', files: c[1], loc: c[2] }));
            if (extra) logical.push({ id: 'l:c:extra', parent: 'l:', kind: 'component', name: 'Extra', purpose: 'One more', files: 3, loc: 300 });
            logical.push({ id: 'l:ext', parent: 'l:', kind: 'externalGroup', name: 'External' });
            const ids = i => i === 'x' ? 'l:ext' : 'l:c:' + i;
            const links = [[1,2],[1,3],[1,4],[1,5],[1,6],[1,'x'],[2,3],[2,4],[2,6],[2,'x'],[3,4],[3,6],[3,'x'],[4,6],[4,'x'],[0,1],[0,'x'],[5,'x'],[6,'x'],[2,5],[3,5]];
            const edges = links.map(l => ({ source: ids(l[0]), target: ids(l[1]), kind: 'imports', weight: 3 }));
            const p = window.make({ project: true, noChange: true });
            p.snapshot.views = [{ id: 'logical', nodes: logical, edges }, p.snapshot.views[0]];
            return p;
        };
        window.shape = function() {
            const cy = window.cyNow(), box = cy.nodes().boundingBox({ includeLabels: false });
            // The zoom the page's fit gives it (28 px of padding): the page is off screen here, where its animations never run, so the
            // fit itself is computed instead of read.
            const fit = Math.min((cy.width() - 56) / Math.max(1, box.w), (cy.height() - 56) / Math.max(1, box.h));
            return { canvas: [cy.width(), cy.height()], graph: [Math.round(box.w), Math.round(box.h)], zoom: Number(fit.toFixed(2)),
                shown: [Math.round(box.w * fit), Math.round(box.h * fit)] };
        };
        return 'ready';
        """
        _ = js(fixture)

        func shape(_ text: String) -> (canvas: [Double], graph: [Double], zoom: Double, shown: [Double]) {
            let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
            return (o["canvas"] as? [Double] ?? [0, 0], o["graph"] as? [Double] ?? [0, 0], o["zoom"] as? Double ?? 0, o["shown"] as? [Double] ?? [0, 0])
        }

        // MARK: A canvas nearly as tall as it is wide: the chain flows downwards and is shown larger (the report: 0.77 as a strip)
        var text = js("""
        window.showArchitecture(window.fixture());
        document.querySelector('[data-arch-view="logical"]').click();
        await window.settle(8);
        return JSON.stringify(window.shape());
        """)
        var s = shape(text)
        check(s.canvas[0] > 900 && s.canvas[1] > 600, "the canvas is 'wide and tall' as in the report", text)
        check(s.zoom >= 1.0, "the Logical graph is fitted at its own size or larger (0.77 as a strip)", text)
        check(s.graph[1] > s.graph[0] * 0.8, "the components are placed in rows that fill the height, not in one thin strip", text)
        check(s.shown[1] >= s.canvas[1] * 0.6, "the graph fills most of the canvas height (it filled a quarter of it)", text)

        // MARK: A canvas that is wide and low: the chain still flows to the right
        text = js("""
        document.getElementById('arch-graph').style.height = '280px';
        window.cyNow().resize();
        window.showArchitecture(window.fixture(true));
        await window.settle(9);
        return JSON.stringify(window.shape());
        """)
        s = shape(text)
        check(s.canvas[1] < 400, "the canvas is now wide and low", text)
        check(s.graph[0] > s.graph[1] * 2.5, "a wide, low canvas keeps the rightward flow, which fits it", text)
        check(s.zoom >= 0.68, "and the labels there stay as large as before (0.69 with the rightward flow)", text)

    }
}


private enum XRayCommandChecks {
    static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        XCTAssertTrue(condition, message, line: line)
    }

    static func parse(_ action: String, _ payload: [String: Any] = [:]) -> XRayCommand? { XRayCommand.parse(action, payload: payload) }

    // MARK: - Each action reaches its command with its arguments

    static func routing() {
        check(parse("operationRun", ["id": "build"]) == .operation(.run(id: "build")), "operationRun carries the operation id")
        check(parse("operationOpen", ["id": "build"]) == .operation(.open(id: "build")), "operationOpen carries the operation id")
        check(parse("operationEdit", ["id": "build"]) == .operation(.edit(id: "build")), "operationEdit carries the operation id")
        check(parse("operationAdd") == .operation(.add), "operationAdd needs no payload")
        check(parse("operationAdopt", ["id": "d1"]) == .operation(.adopt(id: "d1")), "operationAdopt carries the discovered id")
        check(parse("operationDiscover") == .operation(.discover), "operationDiscover")
        check(parse("operationCancelDiscovery") == .operation(.cancelDiscovery), "operationCancelDiscovery")
        check(parse("operationDismissReport") == .operation(.dismissReport), "operationDismissReport")
        check(parse("operationAcceptProposal", ["index": 2]) == .operation(.acceptProposal(index: 2)), "operationAcceptProposal carries the index")
        check(parse("operationRejectProposal", ["index": 3]) == .operation(.rejectProposal(index: 3)), "operationRejectProposal carries the index")
        check(parse("operationAddUnknown", ["index": 0]) == .operation(.addUnknown(index: 0)), "operationAddUnknown carries the index")

        check(parse("openFile", ["path": "a/b.swift", "line": 7, "endLine": 9, "find": "x", "fromSearch": true, "fromPR": true])
              == .openFile(.init(path: "a/b.swift", line: 7, endLine: 9, find: "x", fromSearch: true, fromPR: true)),
              "openFile carries the places, the text to find and where the request came from")
        check(parse("openFile", ["path": "a.md"]) == .openFile(.init(path: "a.md", line: nil, endLine: nil, find: nil, fromSearch: false, fromPR: false)),
              "openFile without places or origin opens the file plainly")
        check(parse("rescan") == .rescan, "rescan")
        check(parse("analyze") == .analyze, "analyze")
        check(parse("describeBook", ["path": "ch1.md"]) == .describeBook(path: "ch1.md"), "describeBook of one chapter")
        check(parse("describeBook") == .describeBook(path: nil), "describeBook of the remaining chapters has no path")
        check(parse("recursiveInsight", ["path": "docs"]) == .recursiveInsight(path: "docs"), "recursiveInsight of a part")
        check(parse("recursiveInsight") == .recursiveInsight(path: ""), "recursiveInsight of the whole X-Ray has an empty path")
        check(parse("askBook", ["question": "  why?  "]) == .askBook(question: "why?"), "askBook trims the question")
        check(parse("cancelAnalysis") == .cancelAnalysis, "cancelAnalysis")
        check(parse("tempFilter", ["criterion": "auth"]) == .temporaryFilter(criterion: "auth"), "tempFilter carries the criterion")
        check(parse("tempFilter") == .temporaryFilter(criterion: ""), "tempFilter without a criterion clears the filter")
        check(parse("openPRXRay", ["source": "gh:5"]) == .openPRXRay(source: "gh:5"), "openPRXRay carries the source")
        check(parse("openPRXRay") == .openPRXRay(source: nil), "openPRXRay without a source opens the default comparison")
        check(parse("analyzePR") == .analyzePR(again: false), "analyzePR runs once by default")
        check(parse("analyzePR", ["again": true]) == .analyzePR(again: true), "analyzePR can start over")
        check(parse("historyCommits", ["day": "2026-11-01"]) == .historyCommits(day: "2026-11-01"), "historyCommits carries the day")
        check(parse("compareWithCommit", ["sha": "abc"]) == .compareWithCommit(sha: "abc"), "compareWithCommit carries the commit")
        check(parse("prFileDiff", ["path": "x"]) == .prFileDiff(path: "x"), "prFileDiff carries the path")
        check(parse("explainPRFile", ["path": "x"]) == .explainPRFile(path: "x"), "explainPRFile carries the path")
        check(parse("askPR", ["question": "q", "path": "x"]) == .askPR(question: "q", path: "x"), "askPR about one file")
        check(parse("askPR", ["question": "q", "path": ""]) == .askPR(question: "q", path: nil), "askPR with an empty path asks about the whole change")
        check(parse("filterSearch", ["filter": "f1"]) == .filterSearch(filter: "f1"), "filterSearch carries the filter")
        check(parse("showPR", ["source": "gh:5"]) == .showPR(source: "gh:5"), "showPR carries the source")
        check(parse("reviewPR") == .reviewPR(again: false), "reviewPR reviews once by default")
        check(parse("reviewPR", ["again": true]) == .reviewPR(again: true), "reviewPR can review again")
        check(parse("prTasksToTerminal") == .prTasksToTerminal, "prTasksToTerminal")
        check(parse("copyPRTasks") == .copyPRTasks, "copyPRTasks")
        check(parse("refreshPRSources") == .refreshPRSources, "refreshPRSources")
        check(parse("prAction", ["op": "merge", "body": "ok", "method": "rebase"]) == .prAction(op: "merge", body: "ok", method: "rebase"),
              "prAction carries the operation, the text and the merge method")
        check(parse("prAction", ["op": "approve"]) == .prAction(op: "approve", body: "", method: "squash"), "prAction defaults to a squash merge and no text")
        let finding = XRayCommand.Finding(path: "x.swift", index: 4)
        check(parse("prFindingFix", ["path": "x.swift", "index": 4]) == .prFindingFix(finding), "prFindingFix names the finding")
        check(parse("prFixAll") == .prFixAll, "prFixAll")
        check(parse("prFindingExplain", ["path": "x.swift", "index": 4]) == .prFindingExplain(finding), "prFindingExplain names the finding")
        check(parse("prFindingComment", ["path": "x.swift", "index": 4]) == .prFindingComment(finding), "prFindingComment names the finding")
        check(parse("prFindingIssue", ["path": "x.swift", "index": 4]) == .prFindingIssue(finding), "prFindingIssue names the finding")
        check(parse("prFindingDismiss", ["path": "x.swift", "index": 4]) == .prFindingDismiss(finding), "prFindingDismiss names the finding")
        check(parse("prFindingFix", ["path": "x.swift"]) == .prFindingFix(.init(path: "x.swift", index: -1)), "a finding without an index is -1, which no finding has")
        check(parse("openURL", ["url": "https://github.com/o/r/pull/1"]) == .openURL(URL(string: "https://github.com/o/r/pull/1")!), "openURL of a GitHub link")
        check(parse("setComponent", ["path": "a", "component": "core"]) == .setComponent(path: "a", component: "core"), "setComponent carries path and component")
        check(parse("rateImportance") == .rateImportance(view: "modules", parent: "", filter: "importance"), "rateImportance defaults to the modules view and importance")
        check(parse("rateImportance", ["view": "code", "parent": "p", "filter": "f"]) == .rateImportance(view: "code", parent: "p", filter: "f"), "rateImportance carries view, parent and filter")
        check(parse("createFilter", ["name": "n", "criterion": "c"]) == .createFilter(name: "n", criterion: "c"), "createFilter carries name and criterion")
        check(parse("deleteFilter", ["id": "u1"]) == .deleteFilter(id: "u1"), "deleteFilter carries the id")
        check(parse("outlineFile", ["path": "x.md"]) == .outlineFile(path: "x.md"), "outlineFile carries the path")
        check(parse("saveSearchAnswer", ["filter": "f"]) == .saveSearchAnswer(filter: "f"), "saveSearchAnswer carries the filter")
        check(parse("retryUnderstanding", ["filter": "f"]) == .retryUnderstanding(filter: "f"), "retryUnderstanding carries the filter")
        check(parse("openUnderstandingSource", ["filter": "f", "source": "s1"]) == .openUnderstandingSource(filter: "f", source: "s1"), "openUnderstandingSource carries filter and source")
        check(parse("explainEdge", ["source": "a", "target": "b"]) == .explainEdge(view: "modules", source: "a", target: "b", kind: "uses", label: nil, again: false),
              "explainEdge defaults to a modules edge of kind uses")
        check(parse("explainEdge", ["view": "code", "source": "a", "target": "b", "kind": "calls", "label": "l", "again": true])
              == .explainEdge(view: "code", source: "a", target: "b", kind: "calls", label: "l", again: true), "explainEdge carries the edge and can start over")
        check(parse("refreshCode") == .refreshCode, "refreshCode")
        check(parse("traceCode", ["scope": "s", "question": "q"]) == .traceCode(scope: "s", question: "q"), "traceCode carries scope and question")
        check(parse("describe", ["view": "code", "id": "n1"]) == .describe(view: "code", id: "n1"), "describe carries view and node")
    }

    // MARK: - What is dropped before it reaches a store

    static func dropped() {
        check(parse("doSomethingElse") == nil && parse("") == nil, "an unknown action is dropped")
        for action in ["operationRun", "operationOpen", "operationEdit", "operationAdopt"] {
            check(parse(action) == nil, "\(action) without an id is dropped")
        }
        for action in ["operationAcceptProposal", "operationRejectProposal", "operationAddUnknown"] {
            check(parse(action) == nil && parse(action, ["index": "2"]) == nil, "\(action) without a numeric index is dropped")
        }
        check(parse("openFile") == nil && parse("openFile", ["path": ""]) == nil, "openFile without a path is dropped")
        check(parse("askBook") == nil && parse("askBook", ["question": "  \n "]) == nil, "askBook with a blank question is dropped")
        check(parse("prAction", ["op": "delete"]) == nil && parse("prAction") == nil, "prAction with an operation the page may not ask for is dropped")
        for op in XRayCommand.prOperations {
            check(parse("prAction", ["op": op]) != nil, "prAction accepts \(op)")
        }
        check(parse("openURL", ["url": "http://github.com/o/r"]) == nil, "openURL of a plain http link is dropped")
        check(parse("openURL", ["url": "https://example.com/o/r"]) == nil, "openURL of another host is dropped")
        check(parse("openURL", ["url": "https://github.com.evil.example/o"]) == nil, "openURL of a host that only starts with github.com is dropped")
        check(parse("openURL", ["url": "javascript:alert(1)"]) == nil && parse("openURL") == nil, "openURL of a script or nothing is dropped")
        check(parse("outlineFile") == nil && parse("outlineFile", ["path": ""]) == nil, "outlineFile without a path is dropped")
        check(parse("explainEdge", ["source": "a"]) == nil && parse("explainEdge", ["target": "b"]) == nil, "explainEdge without both ends is dropped")
        check(parse("traceCode", ["scope": "s"]) == nil && parse("traceCode", ["question": "q"]) == nil, "traceCode without scope or question is dropped")
    }

    // MARK: - "123", "#123" or a link to a pull request

    static func pullRequestNumber() {
        func source(_ text: String) -> XRayCommand? { parse("openPRNumber", ["text": text]) }
        check(source("123") == .openPRXRay(source: "gh:123"), "a bare number opens that pull request")
        check(source("#123") == .openPRXRay(source: "gh:123"), "#123 opens that pull request")
        check(source("  7  ") == .openPRXRay(source: "gh:7"), "spaces around the number do not matter")
        check(source("https://github.com/o/r/pull/42") == .openPRXRay(source: "gh:42"), "a pull request link opens that pull request")
        check(source("https://github.com/o/r/pull/42/files") == .openPRXRay(source: "gh:42"), "a link to its files tab opens that pull request")
        check(source("not a number") == nil && source("") == nil && parse("openPRNumber") == nil, "text without a number is dropped")
    }

    // MARK: - The operations strip belongs to the project's own X-Ray

    static func scopes() {
        let operation = XRayCommand.operation(.run(id: "build"))
        check(operation.isAllowed(inScope: ""), "the operations strip works from the project's X-Ray")
        check(!operation.isAllowed(inScope: "Sources") && !operation.isAllowed(inScope: "#pr") && !operation.isAllowed(inScope: nil),
              "the operations strip is refused from a folder's X-Ray, the pull request's and a tab that is no X-Ray")
        for command in [XRayCommand.rescan, .reviewPR(again: false), .openFile(.init(path: "a", line: nil, endLine: nil, find: nil, fromSearch: false, fromPR: false))] {
            check(command.isAllowed(inScope: "") && command.isAllowed(inScope: "Sources") && command.isAllowed(inScope: "#pr") && command.isAllowed(inScope: nil),
                  "\(command) works from every X-Ray")
        }
    }

    // MARK: - A file or part the page names must lie inside

    static func paths() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("xray-command-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let project = base.appendingPathComponent("project", isDirectory: true)
        let folder = project.appendingPathComponent("Sources", isDirectory: true)
        let sibling = base.appendingPathComponent("project-evil", isDirectory: true)
        for directory in [folder, folder.appendingPathComponent("Core", isDirectory: true), sibling] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let inFolder = XRayCommand.file(at: "Core/a.swift", root: folder, projectRoot: project)
        check(inFolder?.path == folder.appendingPathComponent("Core/a.swift").standardizedFileURL.path, "a relative path inside the X-Ray's folder resolves")
        let inProject = XRayCommand.file(at: project.appendingPathComponent("README.md").path, root: folder, projectRoot: project)
        check(inProject?.path == project.appendingPathComponent("README.md").standardizedFileURL.path, "an absolute path elsewhere in the project resolves for a folder X-Ray")
        check(XRayCommand.file(at: "../../outside.md", root: folder, projectRoot: project) == nil, "a path that climbs out of the project is refused")
        check(XRayCommand.file(at: "../README.md", root: folder, projectRoot: project) != nil, "a path that climbs to a file still inside the project resolves")
        check(XRayCommand.file(at: "/etc/passwd", root: folder, projectRoot: project) == nil, "an absolute path outside the project is refused")
        check(XRayCommand.file(at: sibling.appendingPathComponent("x.md").path, root: folder, projectRoot: project) == nil,
              "a folder whose name only starts like the project's is refused")
        check(XRayCommand.file(at: project.path, root: folder, projectRoot: project) == nil, "the project folder itself is not a file to open")

        check(XRayCommand.insightTarget("", root: folder)?.path == folder.path, "an empty part is the X-Ray's folder")
        check(XRayCommand.insightTarget("Core", root: folder)?.path == folder.appendingPathComponent("Core").standardizedFileURL.path, "an existing part inside the folder resolves")
        check(XRayCommand.insightTarget("Missing", root: folder) == nil, "a part that is not on disk is refused")
        check(XRayCommand.insightTarget("..", root: folder) == nil && XRayCommand.insightTarget("../../project-evil", root: folder) == nil,
              "a part outside the X-Ray's folder is refused")
    }
}


extension XRayContentHostTests {
    func testXRayCommandRoutingAndPathContainment() throws {
        XRayCommandChecks.routing()
        XRayCommandChecks.dropped()
        XRayCommandChecks.pullRequestNumber()
        XRayCommandChecks.scopes()
        try XRayCommandChecks.paths()
    }
}


extension XRayContentHostTests {
    func testHistoricalBaselineOnTemporaryRepositories() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition(), "\(message): \(detail.prefix(600))", line: line)
        }
        func calendar(_ zone: String) -> Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            return calendar
        }

        /// A moment written in a given time zone, e.g. `moment("2026-11-05 23:59:59", "Asia/Tokyo")`.
        func moment(_ text: String, _ zone: String) -> Date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: zone)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.date(from: text)!
        }

        let hashA = String(repeating: "a", count: 40)
        let hashB = String(repeating: "b", count: 40)
        let hashC = String(repeating: "c", count: 40)

        // MARK: Commit names and source ids (the id reaches git command lines, so only a full object name passes)

        check(HistoricalBaseline.isCommitHash(hashA), "a 40-digit name is a commit hash")
        check(HistoricalBaseline.isCommitHash(String(repeating: "0123456789abcdef", count: 4)), "a 64-digit name (SHA-256 repository) is a commit hash")
        for bad in ["", "main", "HEAD", "abc1234", String(repeating: "A", count: 40), String(repeating: "g", count: 40),
                    "--output=/tmp/x", hashA + " ", " " + hashA, hashA + "\n", String(repeating: "a", count: 41)] {
            check(!HistoricalBaseline.isCommitHash(bad), "not a commit hash: \(bad.debugDescription)")
        }
        check(HistoricalBaseline.sourceId(for: hashA) == "at:" + hashA, "the source id is at:<sha>")
        check(HistoricalBaseline.sourceId(for: "main") == nil, "no source id for a branch name")
        check(HistoricalBaseline.commitHash(fromSourceId: "at:" + hashB) == hashB, "the commit comes back out of its source id")
        for other in ["local", "gh:12", "cmp:main", "rev:main", "at:main", "at:--output=x", "at:", "at:" + hashA + "x", hashA] {
            check(HistoricalBaseline.commitHash(fromSourceId: other) == nil, "\(other) names no historical commit")
        }

        // MARK: Parsing the log

        let us = "\u{1F}"
        let log = [
            "\(hashA)\(us)1793000000\(us)Ada Lovelace\(us)Fix the parser",
            "\(hashB)\(us)1793000100\(us)Grace\(us)Subject with \(us) a separator inside",
            "not a hash\(us)1793000200\(us)Bob\(us)bad hash",
            "\(hashC)\(us)soon\(us)Bob\(us)bad time",
            "\(hashC)\(us)1793000300",
            "",
        ].joined(separator: "\n")
        let parsed = HistoricalBaseline.parse(log)
        check(parsed.map(\.sha) == [hashA, hashB], "valid lines are kept, malformed ones skipped (got \(parsed.map(\.sha)))")
        check(parsed.first?.author == "Ada Lovelace" && parsed.first?.subject == "Fix the parser", "author and subject are read")
        check(parsed.last?.subject == "Subject with \(us) a separator inside", "a separator inside the subject stays in the subject")
        check(parsed.first?.committed == Date(timeIntervalSince1970: 1793000000), "the committer epoch becomes the date")
        check(parsed.first?.shortSha == "aaaaaaaa", "the short name is 8 digits")
        check(HistoricalBaseline.parse("").isEmpty, "an empty log has no commits")

        // MARK: The day the page sends

        let chicagoCalendar = calendar("America/Chicago")
        let sent = HistoricalBaseline.day(from: "2026-11-05", calendar: chicagoCalendar)
        check(sent != nil && chicagoCalendar.dateComponents([.year, .month, .day], from: sent!) == DateComponents(year: 2026, month: 11, day: 5),
              "2026-11-05 is Nov 5 in the user's calendar")
        check(HistoricalBaseline.day(from: "2026-11-05", calendar: calendar("Asia/Tokyo")) != sent, "the same text is another moment for another zone")
        for bad in ["", "2026-2-3", "2026-02-31", "2026-13-01", "2026-00-10", "1969-12-31", "yesterday", "2026-11-05T10:00", "2026/11/05",
                    "+026-11-05", "2026-11-05 ", "٢٠٢٦-١١-٠٥"] {
            check(HistoricalBaseline.day(from: bad, calendar: chicagoCalendar) == nil, "not a day: \(bad.debugDescription)")
        }
        check(HistoricalBaseline.day(from: "2028-02-29", calendar: chicagoCalendar) != nil, "a leap day is a day")
        check(HistoricalBaseline.day(from: "2026-02-29", calendar: chicagoCalendar) == nil, "Feb 29 of a common year is not")
        check(HistoricalBaseline.logArguments(forCommit: hashA) == ["log", "-1", "--no-color", "--format=%H%x1f%ct%x1f%an%x1f%s", hashA],
              "one commit is read with the same line format")
        check(HistoricalBaseline.logArguments(forCommit: "--output=/tmp/x") == nil, "no git command line for a name that is not a full hash")

        // MARK: The calendar day, read in the user's time zone (DEC-005)

        func commit(_ sha: String, _ date: Date, author: String = "x", subject: String = "s") -> HistoricalBaseline.Commit {
            HistoricalBaseline.Commit(sha: sha, committed: date, author: author, subject: subject)
        }

        let tokyo = calendar("Asia/Tokyo")
        let chicago = calendar("America/Chicago")
        let utc = calendar("UTC")

        // The same instant is on different days for people in different zones.
        let instant = moment("2026-11-05 23:30:00", "UTC")   // 2026-11-06 08:30 in Tokyo, 2026-11-05 17:30 in Chicago
        let one = [commit(hashA, instant)]
        check(HistoricalBaseline.commits(one, on: moment("2026-11-05 12:00:00", "UTC"), calendar: utc).count == 1, "UTC: the commit is on Nov 5")
        check(HistoricalBaseline.commits(one, on: moment("2026-11-06 12:00:00", "Asia/Tokyo"), calendar: tokyo).count == 1, "Tokyo: the commit is on Nov 6")
        check(HistoricalBaseline.commits(one, on: moment("2026-11-05 12:00:00", "Asia/Tokyo"), calendar: tokyo).isEmpty, "Tokyo: not on Nov 5")
        check(HistoricalBaseline.commits(one, on: moment("2026-11-05 12:00:00", "America/Chicago"), calendar: chicago).count == 1, "Chicago: the commit is on Nov 5")
        check(HistoricalBaseline.commits(one, on: moment("2026-11-06 12:00:00", "America/Chicago"), calendar: chicago).isEmpty, "Chicago: not on Nov 6")

        // The day is half open: its first second belongs to it, the first second of the next day does not.
        let edges = [commit(hashA, moment("2026-11-04 23:59:59", "Asia/Tokyo")),
                     commit(hashB, moment("2026-11-05 00:00:00", "Asia/Tokyo")),
                     commit(hashC, moment("2026-11-05 23:59:59", "Asia/Tokyo")),
                     commit(String(repeating: "d", count: 40), moment("2026-11-06 00:00:00", "Asia/Tokyo"))]
        let tokyoFifth = HistoricalBaseline.commits(edges, on: moment("2026-11-05 15:00:00", "Asia/Tokyo"), calendar: tokyo)
        check(tokyoFifth.map(\.sha) == [hashC, hashB], "midnight to 23:59:59 is the day (got \(tokyoFifth.map { $0.sha.prefix(1) }))")

        // Clock changes: 2026-11-01 is 25 hours long in Chicago, 2026-03-08 only 23.
        let longDay = [commit(hashA, moment("2026-11-01 00:00:00", "America/Chicago")),
                       commit(hashB, moment("2026-11-01 23:59:59", "America/Chicago")),
                       commit(hashC, moment("2026-11-02 00:00:00", "America/Chicago"))]
        check(HistoricalBaseline.commits(longDay, on: moment("2026-11-01 12:00:00", "America/Chicago"), calendar: chicago).count == 2,
              "a 25-hour day keeps both its first and its last second")
        let shortDay = [commit(hashA, moment("2026-03-08 23:59:59", "America/Chicago")), commit(hashB, moment("2026-03-09 00:00:00", "America/Chicago"))]
        check(HistoricalBaseline.commits(shortDay, on: moment("2026-03-08 12:00:00", "America/Chicago"), calendar: chicago).map(\.sha) == [hashA],
              "a 23-hour day ends where the next begins")

        // Newest first; equal times are ordered by name so the list does not jump.
        let ordering = HistoricalBaseline.commits([commit(hashB, instant), commit(hashA, instant),
                                                   commit(hashC, instant.addingTimeInterval(60))], on: instant, calendar: utc)
        check(ordering.map(\.sha) == [hashC, hashA, hashB], "newest first, ties by name (got \(ordering.map { $0.sha.prefix(1) }))")

        // MARK: Reading the history through the injected runner

        check(HistoricalBaseline.commits(on: instant, calendar: utc, run: { _ in nil }) == nil, "git failing is nil, not an empty day")
        let emptyDay = HistoricalBaseline.commits(on: moment("2026-01-01 12:00:00", "UTC"), calendar: utc, run: { _ in log })
        check(emptyDay != nil && emptyDay!.isEmpty, "a day without commits is an empty list (the empty state), not nil")
        var asked: [[String]] = []
        _ = HistoricalBaseline.commits(on: instant, calendar: utc, run: { asked.append($0); return "" })
        check(asked == [HistoricalBaseline.logArguments], "git is asked once, with the fixed argument list")
        check(HistoricalBaseline.logArguments.contains("--branches"), "all local branches are read")
        check(!HistoricalBaseline.logArguments.contains(where: { $0.hasPrefix("--since") || $0.hasPrefix("--until") }),
              "git is given no date limit: its early stop would miss a commit with a wrong clock")

        // MARK: Naming

        let named = HistoricalBaseline.title(for: commit(hashA, moment("2026-11-05 14:32:10", "Asia/Tokyo"), subject: "Fix it"), calendar: tokyo)
        check(named == "Working copy vs aaaaaaaa (2026-11-05 14:32) Fix it", "title is the working copy against the commit (got \(named))")
        let longTitle = HistoricalBaseline.title(for: commit(hashA, instant, subject: String(repeating: "x", count: 100)), calendar: utc)
        check(longTitle.hasSuffix(String(repeating: "x", count: 59) + "…"), "a long subject is cut")

        // MARK: Real git: all local branches, committer date, nothing else

        func git(_ arguments: [String], in directory: URL, environment: [String: String] = [:]) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", directory.path, "-c", "user.name=Tester", "-c", "user.email=tester@example.com",
                                 "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + arguments
            var env = ProcessInfo.processInfo.environment
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["GIT_CONFIG_NOSYSTEM"] = "1"
            for (key, value) in environment { env[key] = value }
            process.environment = env
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }

        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("historical-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        func commitEmpty(_ message: String, author: String, committer: String) -> String {
            _ = git(["commit", "--allow-empty", "-m", message], in: repo,
                    environment: ["GIT_AUTHOR_DATE": author, "GIT_COMMITTER_DATE": committer])
            return git(["rev-parse", "HEAD"], in: repo)!.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        _ = git(["init", "-q"], in: repo)
        let onMain = commitEmpty("main work", author: "2026-11-04T09:00:00+0000", committer: "2026-11-05T09:00:00+0000")
        _ = git(["switch", "-q", "-c", "side"], in: repo)
        let onSide = commitEmpty("side work", author: "2026-11-05T10:00:00+0000", committer: "2026-11-05T11:00:00+0000")
        let rebasedLater = commitEmpty("rewritten later", author: "2026-11-05T12:00:00+0000", committer: "2026-11-07T12:00:00+0000")
        _ = git(["switch", "-q", "main"], in: repo)
        // `side` is not merged: its commits are not in main's history, and the checkout is on main.
        check(git(["branch", "--contains", onSide], in: repo)?.contains("side") == true, "setup: the side commit is on branch side")
        // A commit reachable only from a remote-tracking ref or a tag is not on a local branch.
        _ = git(["switch", "-q", "-c", "gone"], in: repo)
        let remoteOnly = commitEmpty("only on a remote", author: "2026-11-05T13:00:00+0000", committer: "2026-11-05T13:00:00+0000")
        _ = git(["update-ref", "refs/remotes/origin/gone", remoteOnly], in: repo)
        _ = git(["tag", "only-a-tag", remoteOnly], in: repo)
        _ = git(["switch", "-q", "main"], in: repo)
        _ = git(["branch", "-D", "gone"], in: repo)

        let runInRepo: ([String]) -> String? = { git($0, in: repo) }
        let nov5 = HistoricalBaseline.commits(on: moment("2026-11-05 12:00:00", "UTC"), calendar: utc, run: runInRepo)
        check(nov5 != nil, "real git: the history is read")
        check(Set(nov5?.map(\.sha) ?? []) == [onMain, onSide],
              "real git: Nov 5 has the main commit and the unmerged side-branch commit, by committer date (got \(nov5?.map { $0.subject } ?? []))")
        check(nov5?.map(\.subject) == ["side work", "main work"], "real git: newest first")
        check(nov5?.first?.author == "Tester", "real git: the author is read")
        let nov4 = HistoricalBaseline.commits(on: moment("2026-11-04 12:00:00", "UTC"), calendar: utc, run: runInRepo)
        check(nov4?.isEmpty == true, "real git: the author date (Nov 4) does not place the commit; the committer date does")
        let nov7 = HistoricalBaseline.commits(on: moment("2026-11-07 12:00:00", "UTC"), calendar: utc, run: runInRepo)
        check(nov7?.map(\.sha) == [rebasedLater], "real git: a commit amended later is on the day it was committed")
        check(HistoricalBaseline.commits(on: moment("2026-11-05 12:00:00", "UTC"), calendar: utc, run: runInRepo)?.contains { $0.sha == remoteOnly } == false,
              "real git: a commit only on a remote-tracking ref or a tag is not offered (local branches only)")
        check(HistoricalBaseline.commits(on: moment("2026-11-06 12:00:00", "UTC"), calendar: utc, run: runInRepo)?.isEmpty == true,
              "real git: a quiet day is an empty list")
        // Every listed name is usable as a baseline: git resolves it to a commit.
        check(nov5?.allSatisfy { git(["rev-parse", "--verify", "--quiet", $0.sha + "^{commit}"], in: repo) != nil } == true,
              "real git: each offered commit resolves")
        let notARepo = FileManager.default.temporaryDirectory.appendingPathComponent("historical-baseline-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notARepo) }
        check(HistoricalBaseline.commits(on: instant, calendar: utc, run: { git($0, in: notARepo) }) == nil,
              "real git: a folder that is not a repository gives nil")

        // MARK: Real git: what the working copy changed since the chosen commit (REQ-002)

        check(HistoricalBaseline.diffArguments(since: "main") == nil && HistoricalBaseline.diffArguments(since: "--output=/tmp/x") == nil,
              "no diff command for a name that is not a full hash")

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("historical-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        func put(_ name: String, _ text: String) { try? text.write(to: work.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func remove(_ name: String) { try? FileManager.default.removeItem(at: work.appendingPathComponent(name)) }
        func save(_ message: String) -> String {
            _ = git(["add", "-A"], in: work)
            _ = git(["commit", "-q", "-m", message], in: work)
            return git(["rev-parse", "HEAD"], in: work)!.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = git(["init", "-q"], in: work)
        put("a.txt", "one\ntwo\n"); put("gone.txt", "bye\n"); put("same.txt", "same\n")
        put("rename-me.txt", "a line that identifies this file when git looks for renames\nand a second one\nand a third one\n")
        put("файл.js", "let x = 1\n")
        let base = save("base")
        // A branch that goes its own way from the base: its commit is not in the history of what main becomes.
        _ = git(["switch", "-q", "-c", "side"], in: work)
        put("s.txt", "only on the side branch\n")
        let sideCommit = save("side only")
        _ = git(["switch", "-q", "main"], in: work)
        put("a.txt", "one\ntwo\nthree\n"); remove("gone.txt"); remove("файл.js")
        remove("rename-me.txt")
        put("renamed.txt", "a line that identifies this file when git looks for renames\nand a second one\nand a third one\n")
        _ = save("committed work")
        put("a.txt", "one\ntwo\nthree\nfour\n")            // uncommitted edit
        put("staged.txt", "staged\n"); _ = git(["add", "staged.txt"], in: work)   // new, in the index
        put("loose.txt", "never added\n")                   // new, untracked

        func diff(since sha: String) -> String {
            guard let arguments = HistoricalBaseline.diffArguments(since: sha) else { return "NO ARGUMENTS" }
            return git(arguments, in: work) ?? "GIT FAILED"
        }
        let sinceBase = diff(since: base)
        check(sinceBase.contains("diff --git a/a.txt b/a.txt") && sinceBase.contains("+three") && sinceBase.contains("+four"),
              "since the base: committed and uncommitted edits of one file are both in the diff", sinceBase)
        check(sinceBase.contains("deleted file mode") && sinceBase.contains("--- a/gone.txt"), "since the base: a file removed by a commit is a removed file", sinceBase)
        check(sinceBase.contains("new file mode") && sinceBase.contains("+++ b/staged.txt"), "since the base: a new file in the index is a new file", sinceBase)
        check(!sinceBase.contains("loose.txt"), "since the base: an untracked file is not in this diff (the store adds it as a new file)", sinceBase)
        check(!sinceBase.contains("same.txt"), "since the base: an untouched file is not in the diff", sinceBase)
        check(!sinceBase.contains("rename from") && sinceBase.contains("--- a/rename-me.txt") && sinceBase.contains("+++ b/renamed.txt"),
              "since the base: a rename is a removed and an added file, so its content lines are read", sinceBase)
        check(sinceBase.contains("--- a/файл.js") && !sinceBase.contains("\\321"), "since the base: a path outside ASCII stays readable", sinceBase)
        // The chosen commit is the baseline itself, not its merge base with HEAD.
        let sinceSide = diff(since: sideCommit)
        check(sinceSide.contains("deleted file mode") && sinceSide.contains("--- a/s.txt"),
              "since a commit of another branch: what that commit has and the working copy lacks is a removed file", sinceSide)
        check(git(["merge-base", sideCommit, "HEAD"], in: work)?.trimmingCharacters(in: .whitespacesAndNewlines) == base,
              "setup: the merge base of that commit with HEAD is the base commit, which would hide s.txt")
        check(!diff(since: base).contains("s.txt"), "setup: from the merge base the side file does not show")
        check(diff(since: String(repeating: "f", count: 40)) == "GIT FAILED", "a commit that does not exist is a failure, not an empty diff")

    }
}


extension XRayContentHostTests {
    func testGitStatusOnTemporaryRepository() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let z = "\0"
        let sample = ["# branch.oid abc", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1",
                      "1 .M N... 100644 100644 100644 aaa bbb Sources/a b.swift",
                      "1 M. N... 100644 100644 100644 aaa bbb README.md",
                      "1 MM N... 100644 100644 100644 aaa bbb both.txt",
                      "1 A. N... 000000 100644 100644 000 bbb new.txt",
                      "1 .D N... 100644 100644 000000 aaa bbb gone.txt",
                      "2 R. N... 100644 100644 100644 aaa bbb R100 moved.txt", "old name.txt",
                      "u UU N... 100644 100644 100644 100644 a b c clash.txt",
                      "? scratch.txt", "? dir/inner.txt", "! build/", "! .DS_Store"].joined(separator: z) + z

        let status = GitRepoStatus.parse(sample)
        check(status.head == "main" && status.upstream == "origin/main", "branch and upstream are read")
        check(status.ahead == 2 && status.behind == 1, "ahead and behind are read")
        check(status.entries.count == 11, "every path becomes one entry: \(status.entries.count)")
        check(status.entries.first { $0.path == "Sources/a b.swift" }?.worktree == .modified, "a path with a space keeps all of it")
        check(status.entries.first { $0.path == "README.md" }?.index == .modified, "an index change is staged")
        let both = status.entries.first { $0.path == "both.txt" }
        check(both?.index == .modified && both?.worktree == .modified, "a staged file changed again has both states")
        check(status.count(.staged) == 4 && status.count(.changes) == 3, "staged \(status.count(.staged)), changes \(status.count(.changes))")
        check(status.entries.first { $0.path == "moved.txt" }.map { $0.index == .renamed && $0.origin == "old name.txt" } == true, "a rename reads its origin")
        check(status.count(.conflicts) == 1 && status.entries(in: .conflicts).first?.path == "clash.txt", "an unmerged path is a conflict")
        check(status.count(.untracked) == 2, "untracked files are listed one by one")
        check(status.entries(in: .ignored).map(\.path) == ["build/", ".DS_Store"] && status.entries(in: .ignored)[0].isDirectory, "ignored paths and directories")
        check(!status.changedPaths.contains("build/") && status.changedPaths.contains("scratch.txt"), "changedPaths leaves ignored out")
        check(GitRepoStatus.parse("").entries.isEmpty && GitRepoStatus.parse("garbage\0") == GitRepoStatus.empty, "empty and malformed output is harmless")
        check(GitRepoStatus.cleanTracked(lsFiles: "a.txt\0b.txt\0c.txt\0", changed: ["b.txt"]) == ["a.txt", "c.txt"], "clean tracked files exclude changed ones")

        // The file tree's view of the same output.
        check(status.decoration(of: "README.md", isDirectory: false) == GitDecoration(state: .modified, staged: true, inside: 0, detail: "Modified, staged"), "decoration: staged file")
        check(status.decoration(of: "both.txt", isDirectory: false).state == .modified && !status.decoration(of: "both.txt", isDirectory: false).staged, "decoration: staged and changed again counts as not fully staged")
        check(status.decoration(of: "scratch.txt", isDirectory: false).state == .untracked, "decoration: untracked file")
        check(status.decoration(of: "clash.txt", isDirectory: false).state == .conflicted, "decoration: conflict")
        check(status.decoration(of: "build", isDirectory: true).state == .ignored && status.decoration(of: "build/out/x.o", isDirectory: false).state == .ignored, "decoration: ignored directory and what is inside")
        check(status.decoration(of: ".DS_Store", isDirectory: false).state == .ignored, "decoration: ignored file")
        check(status.decoration(of: "dir", isDirectory: true).state == .untracked && status.decoration(of: "dir", isDirectory: true).inside == 1, "decoration: folder with an untracked file")
        check(status.decoration(of: "Sources", isDirectory: true) == GitDecoration(state: .modified, staged: false, inside: 1, detail: "1 changed file inside"), "decoration: folder with a modified file")
        check(status.decoration(of: "untouched.txt", isDirectory: false) == GitDecoration() && status.decoration(of: "docs", isDirectory: true) == GitDecoration(), "decoration: nothing for a clean path")

        // Against real git.
        func git(_ args: [String], in dir: URL) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + args
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            process.environment = environment
            process.currentDirectoryURL = dir
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func write(_ name: String, _ text: String) throws {
            let url = repo.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        _ = git(["init", "-q", "-b", "main"], in: repo)
        _ = git(["config", "user.email", "t@example.com"], in: repo)
        _ = git(["config", "user.name", "T"], in: repo)
        try write(".gitignore", "build/\n*.log\n")
        try write("keep.txt", "one\n"); try write("edit.txt", "one\n"); try write("drop.txt", "one\n")
        _ = git(["add", "-A"], in: repo)
        _ = git(["commit", "-q", "-m", "init"], in: repo)
        try write("edit.txt", "two\n")
        try write("added.txt", "x\n"); _ = git(["add", "added.txt"], in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("drop.txt"))
        try write("build/out.bin", "x"); try write("run.log", "x"); try write("new dir/inner.txt", "x")

        let live = GitRepoStatus.parse(git(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignored=matching"], in: repo))
        check(live.head == "main", "real repo: branch")
        check(live.entries.first { $0.path == "edit.txt" }?.worktree == .modified, "real repo: modified")
        check(live.entries.first { $0.path == "added.txt" }?.index == .added, "real repo: added")
        check(live.entries.first { $0.path == "drop.txt" }?.worktree == .deleted, "real repo: deleted")
        check(live.entries(in: .untracked).map(\.path) == ["new dir/inner.txt"], "real repo: untracked directory is expanded")
        check(Set(live.entries(in: .ignored).map(\.path)) == ["build/", "run.log"], "real repo: ignored: \(live.entries(in: .ignored).map(\.path))")
        let tracked = GitRepoStatus.cleanTracked(lsFiles: git(["ls-files", "-z"], in: repo), changed: live.changedPaths)
        check(Set(tracked) == [".gitignore", "keep.txt"], "real repo: clean tracked files: \(tracked)")

        let trees = GitWorktree.parse("""
        worktree /r/MarkView
        HEAD aaa
        branch refs/heads/main

        worktree /r/MarkView-x
        HEAD bbb
        branch refs/heads/fix/bug-1

        worktree /r/MarkView-release
        HEAD ccc
        detached

        """)
        check(trees.map(\.path) == ["/r/MarkView", "/r/MarkView-x", "/r/MarkView-release"], "worktrees: every copy is listed")
        check(trees[1].branch == "fix/bug-1" && trees[1].folderName == "MarkView-x", "worktrees: branch keeps its slashes")
        check(trees[2].branch == nil && trees[2].isDetached && trees[2].branchLabel == "detached HEAD", "worktrees: detached HEAD")
        let linked = git(["worktree", "list", "--porcelain"], in: repo)
        check(GitWorktree.parse(linked).count == 1 && GitWorktree.parse(linked)[0].branch == "main", "worktrees: real repo with one copy")

    }
}
