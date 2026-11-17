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
