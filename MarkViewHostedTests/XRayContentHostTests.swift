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

extension XRayContentHostTests {
    func testBookStructureAndAnnotations() {
        func check(_ name: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, name, line: line)
        }
        func check<T: Equatable>(_ name: String, _ got: T, _ want: T, line: UInt = #line) {
            XCTAssertEqual(got, want, name, line: line)
        }
        // MARK: Text documents

        check("markdown is a text document", BookBuilder.isTextDocument("docs/a.md"))
        check("txt/rst/adoc/org are text documents", ["notes.txt", "a/b.rst", "guide.adoc", "todo.org"].allSatisfy(BookBuilder.isTextDocument))
        check("CMakeLists.txt is not", !BookBuilder.isTextDocument("CMakeLists.txt"))
        check("requirements.txt is not", !BookBuilder.isTextDocument("requirements-dev.txt"))
        check("swift is not", !BookBuilder.isTextDocument("App.swift"))

        // MARK: Headings

        let markdown = """
        ---
        title: front matter
        ---
        # Guide

        Intro text.

        ## Setup

        ```sh
        # not a heading
        echo "## nor this"
        ```

        ### Install

        Setext title
        ------------

        ## Setup

        #hashtag line
        ####### seven hashes
        """
        let heads = BookBuilder.headings(of: markdown, format: .markdown)
        check("markdown headings", heads.map { "\($0.level):\($0.title)@\($0.line)" },
              ["1:Guide@4", "2:Setup@8", "3:Install@15", "2:Setext title@17", "2:Setup@20"])

        let adoc = "= Title\n\n== First\n\n----\n== not a heading\n----\n\n=== Deep\n"
        check("asciidoc headings", BookBuilder.headings(of: adoc, format: .asciidoc).map { "\($0.level):\($0.title)" },
              ["1:Title", "2:First", "3:Deep"])

        let rst = "=====\nTitle\n=====\n\nPart\n----\n\nSub\n~~~\n\nPart two\n--------\n"
        check("rst headings by adornment", BookBuilder.headings(of: rst, format: .rst).map { "\($0.level):\($0.title)@\($0.line)" },
              ["1:Title@2", "2:Part@5", "3:Sub@8", "2:Part two@11"])

        let org = "* One\n#+BEGIN_SRC\n* not\n#+END_SRC\n** Two\n*** Three\n*nope\n"
        check("org headings", BookBuilder.headings(of: org, format: .org).map { "\($0.level):\($0.title)" }, ["1:One", "2:Two", "3:Three"])
        check("plain text has no headings", BookBuilder.headings(of: "a\nb", format: .plain).isEmpty)

        // MARK: Slugs

        check("github slug", BookBuilder.slug("API: Auth & Tokens"), "api-auth--tokens")
        check("cyrillic slug", BookBuilder.slug("Сборка и релиз"), "сборка-и-релиз")
        check("markup stripped", BookBuilder.slug("3.2 `ArchitectureScanner` and *links* [x](y.md) ##"), "32-architecturescanner-and-links-x")
        check("underscore kept", BookBuilder.slug("snake_case_name"), "snake_case_name")
        check("unique slugs", BookBuilder.uniqueSlugs(["setup", "intro", "setup", "setup"]), ["setup", "intro", "setup-1", "setup-2"])

        // MARK: Chapters

        let doc = """
        # Architecture map

        Overview paragraph.

        ## 1. Purpose

        Text [see scanner](#3-scanner) and [[other]].

        ### 1.1 Goals

        Goal text.

        ## 3. Scanner

        Scanner text, see [concurrency](../guides/concurrency.md#main-actor) and [missing](nowhere.md).

        ### 3.1 Files

        Files [ref][sc] and ![image](pic.png) and `[code](x.md)`.

        [sc]: ./scanner.md#files
        """
        let chapter = BookBuilder.chapter(path: "docs/arch.md", text: doc)
        check("title from the only H1", chapter.title, "Architecture map")
        check("sections exclude the title", chapter.sections.map(\.title), ["1. Purpose", "1.1 Goals", "3. Scanner", "3.1 Files"])
        check("section ids by slug", chapter.sections.map(\.id),
              ["d:docs/arch.md#1-purpose", "d:docs/arch.md#11-goals", "d:docs/arch.md#3-scanner", "d:docs/arch.md#31-files"])
        check("nesting by level", chapter.sections.map(\.parent),
              ["d:docs/arch.md", "d:docs/arch.md#1-purpose", "d:docs/arch.md", "d:docs/arch.md#3-scanner"])
        check("ranges: parent spans children, last ends at EOF", chapter.sections.map { "\($0.start)-\($0.end)" }, ["5-12", "9-12", "13-21", "17-21"])
        check("title slug leads to the chapter", chapter.anchors["architecture-map"], "d:docs/arch.md")
        check("innermost section by line", chapter.section(containing: 10)?.id, "d:docs/arch.md#11-goals")
        check("chapter-level line has no section", chapter.section(containing: 3) == nil)
        check("signature is 24 hex", chapter.signature.count == 24 && chapter.signature.allSatisfy(\.isHexDigit))

        check("links found with lines", chapter.links.map { "\($0.line):\($0.target)#\($0.fragment ?? "")\($0.wiki ? "w" : "")" },
              ["7:other#w", "7:#3-scanner", "15:../guides/concurrency.md#main-actor", "15:nowhere.md#", "19:./scanner.md#files"])

        let twoH1 = BookBuilder.chapter(path: "notes.md", text: "# A\n\ntext\n\n# B\n\nmore\n")
        check("two H1s: file name title, both are sections", twoH1.title == "notes" && twoH1.sections.map(\.title) == ["A", "B"])
        let headless = BookBuilder.chapter(path: "plain.txt", text: "just\nsome\ntext")
        check("headless chapter", !headless.hasHeadings && headless.sections.isEmpty && headless.lines == 3)

        // Cap: 400 H3 headings under 2 H2s keep the H2s and drop the H3s; links to dropped ones go up.
        var big = "# T\n"
        for i in 0..<2 { big += "## Part \(i)\n"; for j in 0..<200 { big += "### Item \(i)-\(j)\n" } }
        let capped = BookBuilder.chapter(path: "big.md", text: big)
        check("section cap drops deepest level", capped.sections.map(\.title), ["Part 0", "Part 1"])
        check("dropped heading leads to kept ancestor", capped.anchors["item-1-7"], "d:big.md#part-1")

        // MARK: Links by format

        /// "line:target#fragment" per extracted link, `w` marking a wiki link.
        func found(_ text: String, _ format: BookBuilder.Format) -> [String] {
            BookBuilder.links(in: text, format: format).map { "\($0.line):\($0.target)\($0.fragment.map { "#" + $0 } ?? "")\($0.wiki ? "w" : "")" }
        }

        // reStructuredText: an embedded hyperlink is a single-backtick span, so it must be read before
        // code spans are removed (BUG-040), while literals, literal blocks and external targets stay out.
        check("rst embedded hyperlink", found("See `the setup guide <setup.rst>`_.", .rst), ["1:setup.rst"])
        check("rst anonymous hyperlink", found("See `the setup guide <setup.rst>`__.", .rst), ["1:setup.rst"])
        check("rst hyperlink with a fragment and a path", found("Read `install <../guide/setup.rst#install>`_ first.", .rst), ["1:../guide/setup.rst#install"])
        check("rst two hyperlinks on lines 2 and 4", found("Intro\n`a <a.rst>`_ and `b <b.rst>`_\n\n`c <c.rst>`_", .rst), ["2:a.rst", "2:b.rst", "4:c.rst"])
        check("rst hyperlink text wrapped over two lines", found("See `the setup\nguide <setup.rst>`_.", .rst), ["2:setup.rst"])
        check("rst external hyperlink skipped", found("`Python <https://python.org/doc>`_ and `mail <mailto:a@b.c>`_", .rst), [])
        check("rst inline literal skipped, real link kept", found("Write ``see `x <no.rst>`_`` then `real <yes.rst>`_.", .rst), ["1:yes.rst"])
        check("rst inline literal holding a single backtick", found("``a`b`` and `real <yes.rst>`_ and ``c <no.rst>`_``", .rst), ["1:yes.rst"])
        check("rst literal block after ::", found("Example::\n\n    `x <lit.rst>`_\n\n    more `y <lit2.rst>`_\n\nAfter `z <after.rst>`_", .rst), ["7:after.rst"])
        check("rst literal block after a bare ::", found("Text\n\n::\n\n    `x <lit.rst>`_\n\n`z <after.rst>`_", .rst), ["7:after.rst"])
        check("rst code-block directive body is literal", found(".. code-block:: rst\n   :linenos:\n\n   `x <lit.rst>`_\n\n`z <after.rst>`_", .rst), ["6:after.rst"])
        check("rst code directive without an argument", found(".. code::\n\n   `x <lit.rst>`_\n`z <after.rst>`_", .rst), ["4:after.rst"])
        check("rst indented literal block inside a list item", found("- item::\n\n      `x <lit.rst>`_\n\n- `z <after.rst>`_", .rst), ["5:after.rst"])
        check("rst note directive is not literal", found(".. note::\n\n   See `the guide <guide.rst>`_.\n", .rst), ["3:guide.rst"])
        check("rst :: with no block after it ends at once", found("Example::\n`x <next.rst>`_", .rst), ["2:next.rst"])
        check("rst literal block ends at the first dedented line", found("A::\n\n    `x <lit.rst>`_\n`y <back.rst>`_", .rst), ["4:back.rst"])
        check("rst wiki link still found", found("See [[Other]] and `s <s.rst>`_", .rst), ["1:Otherw", "1:s.rst"])

        // The other formats keep their rules: the same backtick text is not a link outside RST.
        check("markdown ignores the rst form", found("See `the setup guide <setup.md>`_.", .markdown), [])
        check("markdown inline link, code span skipped", found("[a](a.md) and `[b](b.md)`", .markdown), ["1:a.md"])
        check("asciidoc xref and link macros", found("See xref:setup.adoc[Setup] and link:other.adoc#part[Other].", .asciidoc), ["1:setup.adoc", "1:other.adoc#part"])
        check("asciidoc macro inside backticks skipped", found("Type `xref:setup.adoc[Setup]` but see xref:real.adoc[Real].", .asciidoc), ["1:real.adoc"])
        check("asciidoc ignores the rst form", found("`the setup guide <setup.adoc>`_", .asciidoc), [])
        check("org and plain have no inline links", found("[[file:setup.org]] and `x <y.org>`_", .org).filter { !$0.hasSuffix("w") }, [])
        check("plain text has no links", found("`x <y.txt>`_ and [a](a.md)", .plain), [])

        // MARK: Resolution

        let concurrency = BookBuilder.chapter(path: "guides/concurrency.md", text: "# Concurrency\n\n## Main actor\n\ntext\n\n## Queues\n\nmore\n")
        let other = BookBuilder.chapter(path: "docs/other.md", text: "# Other\n\nbody\n")
        let otherDeep = BookBuilder.chapter(path: "deep/x/other.md", text: "# Other deep\n\nbody\n")
        let scanner = BookBuilder.chapter(path: "docs/scanner.md", text: "# Scanner\n\n## Files\n\nf\n\n## Files\n\ng\n")
        let readme = BookBuilder.chapter(path: "README.md", text: "# The Book\n\nStart [here](docs/arch.md) and [there](docs/arch.md#L10).\n")
        let chapters = [chapter, concurrency, other, otherDeep, scanner, readme]
        let index = BookBuilder.Index(chapters)
        func resolve(_ link: BookBuilder.Link, from: BookBuilder.Chapter? = nil) -> String? { BookBuilder.resolve(link, from: from ?? chapter, index: index) }

        check("same-document fragment", resolve(.init(line: 7, target: "", fragment: "3-scanner", wiki: false)), "d:docs/arch.md#3-scanner")
        check("relative path with fragment", resolve(.init(line: 15, target: "../guides/concurrency.md", fragment: "main-actor", wiki: false)), "d:guides/concurrency.md#main-actor")
        check("fragment by heading text", resolve(.init(line: 15, target: "../guides/concurrency.md", fragment: "Main Actor", wiki: false)), "d:guides/concurrency.md#main-actor")
        check("unknown fragment → chapter", resolve(.init(line: 15, target: "../guides/concurrency.md", fragment: "nope", wiki: false)), "d:guides/concurrency.md")
        check("missing document → nil", resolve(.init(line: 15, target: "nowhere.md", fragment: nil, wiki: false)) == nil)
        check("./ prefix and duplicate slug", resolve(.init(line: 19, target: "./scanner.md", fragment: "files-1", wiki: false)), "d:docs/scanner.md#files-1")
        check("wiki link by name prefers the same folder", resolve(.init(line: 7, target: "other", fragment: nil, wiki: true)), "d:docs/other.md")
        check("wiki link by name elsewhere: shortest path", resolve(.init(line: 1, target: "other", fragment: nil, wiki: true), from: readme), "d:docs/other.md")
        check("wiki link with heading", resolve(.init(line: 7, target: "concurrency", fragment: "Queues", wiki: true)), "d:guides/concurrency.md#queues")
        check("wiki path from the root", resolve(.init(line: 7, target: "guides/concurrency", fragment: nil, wiki: true)), "d:guides/concurrency.md")
        check("extension added", resolve(.init(line: 7, target: "scanner", fragment: nil, wiki: false)), "d:docs/scanner.md")
        check("#L line fragment → containing section", resolve(.init(line: 3, target: "docs/arch.md", fragment: "L10", wiki: false), from: readme), "d:docs/arch.md#11-goals")
        check("percent-decoded path", resolve(.init(line: 1, target: "docs/arch.md", fragment: nil, wiki: false), from: readme), "d:docs/arch.md")

        // MARK: Order

        let paths = ["zeta.md", "docs/10-api.md", "README.md", "docs/2-setup.md", "docs/01-intro.md", "docs/README.md", "docs/sub/a.md", "docs/b.md"]
        check("book order", paths.sorted(by: BookBuilder.bookOrder),
              ["README.md", "zeta.md", "docs/README.md", "docs/01-intro.md", "docs/2-setup.md", "docs/10-api.md", "docs/b.md", "docs/sub/a.md"])

        // MARK: Build

        let book = BookBuilder.build(chapters: chapters, rootName: "folder")
        check("book title from the root README", book.nodes.first?.name, "The Book")
        check("parts and chapters in order", book.nodes.filter { $0.kind == "dir" || $0.kind == "doc" }.map(\.id),
              ["d:README.md", "d:deep/", "d:deep/x/", "d:deep/x/other.md", "d:docs/", "d:docs/arch.md", "d:docs/other.md", "d:docs/scanner.md",
               "d:guides/", "d:guides/concurrency.md"])
        let archNode = book.nodes.first { $0.id == "d:docs/arch.md" }!
        check("chapter node", archNode.kind == "doc" && archNode.name == "Architecture map" && archNode.language == "markdown" && archNode.files == 1 && archNode.signature != nil)
        let goals = book.nodes.first { $0.id == "d:docs/arch.md#11-goals" }!
        check("section node carries lines and anchor", goals.line == 9 && goals.endLine == 12 && goals.anchor == "1.1 Goals" && goals.loc == 4)
        let docsPart = book.nodes.first { $0.id == "d:docs/" }!
        check("part counts chapters and lines", docsPart.files == 3 && docsPart.loc == chapter.lines + other.lines + scanner.lines)
        let edgeKeys = book.edges.map { "\($0.source) → \($0.target) ×\($0.weight)" }
        check("edges from the containing section to the section",
              edgeKeys.contains("d:docs/arch.md#1-purpose → d:docs/arch.md#3-scanner ×1")
              && edgeKeys.contains("d:docs/arch.md#1-purpose → d:docs/other.md ×1")
              && edgeKeys.contains("d:docs/arch.md#3-scanner → d:guides/concurrency.md#main-actor ×1")
              && edgeKeys.contains("d:docs/arch.md#31-files → d:docs/scanner.md#files ×1"))
        check("README links from the chapter, weight aggregates by target", edgeKeys.contains("d:README.md → d:docs/arch.md ×1")
              && edgeKeys.contains("d:README.md → d:docs/arch.md#11-goals ×1"))
        check("no edge to a missing document or image", !edgeKeys.contains { $0.contains("nowhere") || $0.contains("pic.png") })
        check("no edge from code spans", !edgeKeys.contains { $0.contains("x.md") })

        // An RST book: the embedded hyperlink becomes an edge from the section that holds it (BUG-040).
        // A link in the literal block would raise the weight of the first edge to 2.
        let rstIndex = BookBuilder.chapter(path: "index.rst", text: "Manual\n======\n\nStart\n-----\n\nSee `the setup guide <setup.rst>`_ or `install <setup.rst#install>`__.\n\nShell::\n\n    `not <setup.rst>`_\n")
        let rstSetup = BookBuilder.chapter(path: "setup.rst", text: "Setup\n=====\n\ninstall\n-------\n\nSteps.\n")
        let rstBook = BookBuilder.build(chapters: [rstIndex, rstSetup], rootName: "rst")
        check("rst hyperlinks give edges to the chapter and the section",
              rstBook.edges.map { "\($0.source) → \($0.target) ×\($0.weight)" }.sorted(),
              ["d:index.rst#start → d:setup.rst ×1", "d:index.rst#start → d:setup.rst#install ×1"])

        let selfLink = BookBuilder.chapter(path: "s.md", text: "# S\n\n## A\n\n[up](#s) [self](#a)\n\n### B\n\n[parent](#a)\n")
        let selfBook = BookBuilder.build(chapters: [selfLink], rootName: "x")
        check("self, ancestor and descendant links dropped", selfBook.edges.isEmpty)

        // MARK: Front matter and leads

        let req = """
        ---
        type: requirement
        id: REQ-001
        title: Title includes workspace folder name
        status: approved
        ---

        ## Statement

        When a workspace folder is open, each window's title shall be **'MarkView <version> — <folder>'**,
        with the Finder display name of the root folder.

        ## Acceptance Criteria

        - [x] With folder /x/my-project open, the title reads 'MarkView 1.4 — my-project'.
        - [x] The full path never appears.
        """
        let reqChapter = BookBuilder.chapter(path: "requirements/REQ-001.md", text: req)
        check("front matter title names the chapter", reqChapter.title, "Title includes workspace folder name")
        check("chapter lead falls back to the first section's paragraph",
              reqChapter.lead, "When a workspace folder is open, each window's title shall be 'MarkView <version> — <folder>', with the Finder display name of the root folder.")
        check("section lead strips list markers and checkboxes", reqChapter.sections[1].lead,
              "With folder /x/my-project open, the title reads 'MarkView 1.4 — my-project'. The full path never appears.")
        check("leads become provisional summaries", BookBuilder.build(chapters: [reqChapter], rootName: "r").nodes.first { $0.kind == "doc" }?.summary == reqChapter.lead)
        let front = BookBuilder.frontMatter(["---", "title: \"Quoted\"", "summary: Short one.", "nested:", "  - a", "---", "body"])
        check("front matter fields and end", front.fields["title"] == "Quoted" && front.fields["summary"] == "Short one." && front.end == 6)
        check("summary field wins over the first paragraph", BookBuilder.chapter(path: "a.md", text: "---\nsummary: From front matter.\n---\n\nBody text here.\n").lead, "From front matter.")
        check("lead skips headings, fences and tables", BookBuilder.lead(["# T", "```", "code", "```", "| a | b |", "", "Real *text* [here](x).", "continues.", "", "next"], from: 1, to: 10), "Real text here. continues.")
        check("long lead is cut at a word", BookBuilder.lead([String(repeating: "word ", count: 60)], from: 1, to: 1)!.hasSuffix("…"))
        check("no lead in an empty range", BookBuilder.lead(["", "## x"], from: 1, to: 2) == nil)
        check("chapter lead from the opening paragraph", chapter.lead, "Overview paragraph.")
        check("section lead", chapter.sections[0].lead, "Text see scanner and other.")

        // MARK: Annotator

        let bookView = ArchView(id: "docs", nodes: book.nodes, edges: book.edges)
        let annotated = BookAnnotator.Book(view: bookView, language: "English")
        check("book title and chapters", annotated.title == "The Book" && annotated.chapters.count == 6)
        let archChapter = annotated.chapters.first { $0.path == "docs/arch.md" }!
        check("chapter sections with depth", archChapter.sections.map { "\($0.depth)" }, ["0", "1", "0", "1"])
        check("chapter not current before annotation", !archChapter.isCurrent)
        check("README is front matter", annotated.chapters.first { $0.path == "README.md" }!.isFrontMatter)

        // Windows: a 6000-line chapter with three 2000-line top-level sections.
        var longChapter = archChapter
        longChapter.lines = 6000
        longChapter.sections = [
            BookAnnotator.Section(id: "s1", parent: "c", title: "One", line: 1, end: 2000, depth: 0),
            BookAnnotator.Section(id: "s1a", parent: "s1", title: "One a", line: 100, end: 2000, depth: 1),
            BookAnnotator.Section(id: "s2", parent: "c", title: "Two", line: 2001, end: 4000, depth: 0),
            BookAnnotator.Section(id: "s3", parent: "c", title: "Three", line: 4001, end: 6000, depth: 0),
        ]
        let windows = BookAnnotator.windows(for: longChapter)
        check("windows split at top-level sections", windows.map { "\($0.start)-\($0.end):\($0.sectionIds.joined(separator: ","))" },
              ["1-2000:s1,s1a", "2001-4000:s2", "4001-6000:s3"])
        check("short chapter: one window", BookAnnotator.windows(for: archChapter).count == 1)
        check("long chapter is large", longChapter.isLarge && !archChapter.isLarge)

        let job = BookAnnotator.Job(chapter: archChapter, window: BookAnnotator.windows(for: archChapter)[0])
        let built = BookAnnotator.request(job: job, book: annotated, lines: doc.editorLines.map(String.init))
        check("prompt lists sections with ids and lines", built.prompt.contains("- d:docs/arch.md#1-purpose | 1. Purpose | 5–12")
              && built.prompt.contains("  - d:docs/arch.md#11-goals | 1.1 Goals | 9–12"))
        check("prompt has the index with same-part sections", built.prompt.contains("- d:docs/scanner.md | Scanner") && built.prompt.contains("- d:docs/scanner.md#files | Files"))
        check("prompt numbers the text", built.prompt.contains("1| # Architecture map"))
        check("system prompt asks for facts, no items for a small chapter", built.system.contains("CHAPTER SUMMARY") && !built.system.contains("ITEMS:"))
        check("schema has sections", (built.schema["required"] as? [String]) == ["sections"])

        check("empty answer unusable", !BookAnnotator.isUsable([:], job: job))
        check("answer without chapter summary unusable", !BookAnnotator.isUsable(["sections": [["id": "d:docs/arch.md#1-purpose", "summary": "x"]]], job: job))
        let answer: [String: Any] = [
            "chapter": ["summary": "Maps the X-Ray: scanner, store, views.", "importance": "high"],
            "sections": [
                ["id": "d:docs/arch.md#1-purpose", "summary": "States the goals of the map.", "importance": "critical",
                 "refs": [["target": "d:docs/scanner.md#files", "why": "scanner lists files"],
                          ["target": "d:docs/arch.md#1-purpose", "why": "self"],
                          ["target": "d:docs/arch.md#11-goals", "why": "child"],
                          ["target": "d:nowhere.md", "why": "unknown"]]],
                ["id": "d:docs/arch.md#3-scanner", "summary": "Lists what the scanner reads.", "importance": "normal", "refs": [],
                 "items": [["name": "Files", "type": "Input", "line": 14], ["name": "Links", "type": "Input", "line": 15],
                           ["name": "Tokens", "type": "Input", "line": 15], ["name": "Edges", "type": "Output", "line": 99],
                           ["name": "Refs", "type": "Output", "line": 1]]],
                ["id": "d:unknown#x", "summary": "ignored", "importance": "low", "refs": []],
            ],
        ]
        check("answer usable", BookAnnotator.isUsable(answer, job: job))
        let applied = BookAnnotator.apply(answer, job: job, to: bookView, lines: doc.editorLines.map(String.init))
        let byId = Dictionary(applied.view.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        check("chapter summary and signature", byId["d:docs/arch.md"]?.summary == "Maps the X-Ray: scanner, store, views." && byId["d:docs/arch.md"]?.summarySignature == archChapter.expectedSignature)
        check("section summaries", byId["d:docs/arch.md#1-purpose"]?.summary == "States the goals of the map." && byId["d:docs/arch.md#3-scanner"]?.summary != nil)
        check("importance keys", applied.importance == ["p:docs/arch.md": "high", "d:docs/arch.md#1-purpose": "critical", "d:docs/arch.md#3-scanner": "normal"])
        let related = applied.view.edges.filter { $0.kind == "related" }
        check("one related edge survives (self, child, unknown dropped)", related.map { "\($0.source)→\($0.target):\($0.label ?? "")" }, ["d:docs/arch.md#1-purpose→d:docs/scanner.md#files:scanner lists files"])
        check("explicit links kept", applied.view.edges.filter { $0.kind == "links" }.count == book.edges.count)
        let items = applied.view.nodes.filter { $0.id.hasPrefix("d:docs/arch.md#3-scanner/") }
        check("five items under the section, no group level (groups under 4 items)", items.count == 5 && items.allSatisfy { $0.kind == "entity" && $0.parent == "d:docs/arch.md#3-scanner" })
        check("item lines clamped into the section", items.allSatisfy { ($0.line ?? 0) >= 13 && ($0.line ?? 0) <= 21 })

        // Re-applying replaces the earlier items and related edges instead of adding to them.
        let reapplied = BookAnnotator.apply(answer, job: job, to: applied.view, lines: doc.editorLines.map(String.init))
        check("re-apply replaces items and refs", reapplied.view.nodes.filter { $0.id.hasPrefix("d:docs/arch.md#3-scanner/") }.count == 5
              && reapplied.view.edges.filter { $0.kind == "related" }.count == 1)

        // A document without headings: the AI proposes the sections.
        let plainBook = BookBuilder.build(chapters: [BookBuilder.chapter(path: "notes.txt", text: Array(repeating: "line", count: 60).joined(separator: "\n"))], rootName: "n")
        let plainView = ArchView(id: "docs", nodes: plainBook.nodes, edges: plainBook.edges)
        let plainChapter = BookAnnotator.Book(view: plainView, language: "English").chapters[0]
        let plainJob = BookAnnotator.Job(chapter: plainChapter, window: BookAnnotator.windows(for: plainChapter)[0])
        check("headless prompt says so", BookAnnotator.request(job: plainJob, book: BookAnnotator.Book(view: plainView, language: "English"), lines: Array(repeating: "line", count: 60)).system.contains("no headings"))
        let plainAnswer: [String: Any] = [
            "chapter": ["summary": "Notes.", "importance": "normal"],
            "sections": [["id": "", "title": "Second part", "line": 31, "summary": "B", "importance": "normal", "refs": []],
                         ["id": "", "title": "First part", "line": 1, "summary": "A", "importance": "high", "refs": []]],
        ]
        check("headless answer usable", BookAnnotator.isUsable(plainAnswer, job: plainJob))
        let plainApplied = BookAnnotator.apply(plainAnswer, job: plainJob, to: plainView, lines: Array(repeating: "line", count: 60))
        let plainSections = plainApplied.view.nodes.filter { $0.kind == "section" }
        check("AI sections with ranges", plainSections.map { "\($0.id):\($0.line ?? 0)-\($0.endLine ?? 0)" }, ["d:notes.txt#first-part:1-30", "d:notes.txt#second-part:31-60"])
        check("AI section summaries and importance", plainSections.first?.summary == "A" && plainApplied.importance["d:notes.txt#first-part"] == "high")

        // Parts.
        check("no parts call without chapter summaries", BookAnnotator.partsRequests(view: bookView, language: "English").isEmpty)
        let partsRequests = BookAnnotator.partsRequests(view: applied.view, language: "English")
        check("one parts call listing parts with chapters", partsRequests.count == 1 && partsRequests[0].prompt.contains("- d:docs/ (3 chapters")
              && partsRequests[0].prompt.contains("\"Architecture map\" — Maps the X-Ray: scanner, store, views"))
        let withParts = BookAnnotator.applyParts(["book": ["summary": "All about X-Ray."], "parts": [["id": "d:docs/", "summary": "Design notes."]]], to: applied.view)
        check("part and book summaries applied", withParts.nodes.first { $0.id == "d:docs/" }?.summary == "Design notes." && withParts.nodes.first { $0.kind == "root" }?.summary == "All about X-Ray.")
    }
}

extension XRayContentHostTests {
    func testUnderstandingAnswerValidationAndPersistence() throws {
        func check(_ name: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, name, line: line)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("understanding-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("code.swift"), atomically: true, encoding: .utf8)
        try "# Decision\nThe reason\n".write(to: root.appendingPathComponent("docs/DEC-001.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let sha = String(repeating: "a", count: 40)
        func source(_ id: String, _ kind: String, path: String = "", target: String = "", url: String = "") -> [String: Any] {
            ["id": id, "kind": kind, "label": "Evidence \(id)", "path": path, "start": 2, "end": 900, "target": target, "url": url]
        }
        let references = [source("S1", "code", path: "code.swift"), source("S2", "document", path: "docs/DEC-001.md"),
                          source("S3", "component", target: "editor"), source("S4", "deployment", target: "app"),
                          source("S5", "commit", target: sha), source("S6", "pr", target: "26", url: "https://github.com/test/repo/pull/26")]
        func section(_ text: String, _ ids: [String]) -> [String: Any] { ["text": text, "sources": ids] }
        let valid: [String: Any] = ["what": section("A thing", ["S1", "S3"]), "why": section("Solves a problem", ["S2"]),
                                  "how": section("The flow", ["S1", "S4"]), "origin": section("The documented decision", ["S2", "S5", "S6"]),
                                  "originFound": true, "sources": references]
        func parse(_ object: Any?) throws -> UnderstandingAnswer {
            try UnderstandingAnswer.parse(object, root: root, components: ["editor"], deployment: ["app"], commits: [sha],
                                          pullRequests: ["https://github.com/test/repo/pull/26"])
        }
        func rejected(_ name: String, _ object: Any?) {
            do { _ = try parse(object); check(name, false) } catch { check(name, !error.localizedDescription.isEmpty) }
        }
        let answer = try parse(valid)
        check("all six evidence types survive validation", answer.sources.count == 6)
        check("file ranges are clamped", answer.sources[0].start == 2 && answer.sources[0].end == 4)
        check("parsing never saves research", !FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/research").path))
        rejected("nil/empty answers give a reason", nil)
        rejected("legacy location-only answer is rejected", ["answer": "See code.swift"])
        var bad = valid; bad["why"] = section(" \n", []); rejected("empty explanatory section is rejected", bad)
        bad = valid; bad["how"] = section("Flow", ["unknown"]); rejected("dangling citation is rejected", bad)
        bad = valid; bad["origin"] = section("Origin", ["S1"]); rejected("origin needs document/commit/PR evidence", bad)
        bad = valid; bad["sources"] = references + [references[0]]; rejected("duplicate citations are rejected", bad)
        bad = valid; bad["sources"] = [source("S1](bad)", "code", path: "code.swift")]; rejected("invalid citation identifiers are rejected", bad)
        bad = valid; bad["sources"] = [source("S1", "code", path: "../outside.swift")]; rejected("path traversal is rejected", bad)
        bad = valid; bad["sources"] = [source("S1", "code", path: "/etc/passwd")]; rejected("absolute paths are rejected", bad)
        bad = valid; bad["sources"] = [source("S1", "code", path: "missing.swift")]; rejected("missing evidence is rejected", bad)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        check("symlinks cannot escape the workspace", UnderstandingAnswer.relativePath("escape/passwd", root: root) == nil)
        bad = valid; bad["sources"] = [source("S1", "component", target: "missing")]; rejected("unknown X-Ray target is rejected", bad)
        bad = valid; bad["sources"] = [source("S1", "commit", target: String(repeating: "b", count: 40))]; rejected("unseen commit is rejected", bad)
        bad = valid; bad["sources"] = [source("S1", "pr", target: "26", url: "https://github.com/evil/repo/pull/26")]; rejected("unseen PR is rejected", bad)
        check("external and mismatched commit URLs are rejected", !UnderstandingAnswer.isGitHubURL("https://example.com/commit/" + sha, kind: .commit, target: sha)
              && !UnderstandingAnswer.isGitHubURL("https://github.com/a/b/commit/other", kind: .commit, target: sha))
        var noOrigin = valid; noOrigin["originFound"] = false; noOrigin["origin"] = section("No origin source was found. Git/PR access unavailable.", [])
        let missingOrigin = try parse(noOrigin)
        check("absent origin is explicit in saved answer", missingOrigin.markdown(question: "Q").contains("No origin source found."))

        let folder = root.appendingPathComponent("docs/research")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "untouched".write(to: folder.appendingPathComponent("RES-001-existing.md"), atomically: true, encoding: .utf8)
        try "untouched too".write(to: folder.appendingPathComponent("RES-009.md"), atomically: true, encoding: .utf8)
        let question = "What is this?\n" + String(repeating: "A long question. ", count: 40)
        let saved = try answer.save(question: question, root: root, author: "Tester", date: "2026-09-27")
        let content = try String(contentsOf: saved, encoding: .utf8)
        let front = FrontMatter.split(content).0
        check("save uses next free RES number", saved.lastPathComponent.hasPrefix("RES-010-"))
        check("existing file is never overwritten", try String(contentsOf: folder.appendingPathComponent("RES-001-existing.md"), encoding: .utf8) == "untouched")
        check("research format includes id and type", front.string("type") == "research" && front.string("id") == "RES-010")
        check("entire question, sections and sources are saved", content.contains(question) && content.contains("## What") && content.contains("## Why")
              && content.contains("## How") && content.contains("## Origin") && content.contains("## Sources") && content.contains("Source S6"))
        check("source file links retain lines", content.contains("../../code.swift#L2-L4"))
        let image = root.appendingPathComponent("screenshot.png")
        try Data([1, 2, 3]).write(to: image)
        let copied = try UnderstandingAttachments.copy([image], to: root.appendingPathComponent(".dde/understanding/test"), root: root)
        check("unsaved attachments stay outside research", copied.first?.hasPrefix(".dde/understanding/") == true)
        let withImage = try answer.save(question: "Explain this screenshot", root: root, author: "Tester", date: "2026-09-27",
            attachments: copied.map { root.appendingPathComponent($0) })
        let imageBody = try String(contentsOf: withImage, encoding: .utf8)
        check("explicit save embeds question images", imageBody.contains("## Question attachments") && imageBody.contains("![") && imageBody.contains("assets/RES-011-"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".dde"))
        let assetFolders = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("assets"), includingPropertiesForKeys: nil)
        check("saved image survives closing the transient question", try FileManager.default.contentsOfDirectory(atPath: assetFolders[0].path).count == 1)
        do {
            _ = try UnderstandingAttachments.copy([image], to: root.appendingPathComponent("escape/attachments"), root: root)
            check("attachment destination cannot escape via symlink", false)
        } catch { check("attachment destination cannot escape via symlink", true) }
        let lock = NSLock()
        var files: [URL] = []
        var saveErrors = 0
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let file = try answer.save(question: "Concurrent question", root: root, author: "Tester", date: "2026-09-27")
                lock.lock(); files.append(file); lock.unlock()
            } catch { lock.lock(); saveErrors += 1; lock.unlock() }
        }
        check("concurrent saves reserve distinct numeric ids", saveErrors == 0 && Set(files.map { $0.lastPathComponent.prefix(7) }).count == 8)
        check("save leaves no reservation files", try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasSuffix(".reserve") })
        // A folder that refuses the file: the save fails, and neither a reservation nor a partial answer stays; the earlier research is untouched.
        let listingBefore = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let existingBefore = try Data(contentsOf: folder.appendingPathComponent("RES-001-existing.md"))
        chmod(folder.path, 0o555)
        var refusedSave = false
        do { _ = try answer.save(question: "Refused question", root: root, author: "Tester", date: "2026-09-27") } catch { refusedSave = true }
        chmod(folder.path, 0o755)
        check("a research folder that refuses the file fails the save", refusedSave)
        check("and leaves it as it was: no reservation, no partial answer, the earlier files unchanged",
              try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == listingBefore
                  && Data(contentsOf: folder.appendingPathComponent("RES-001-existing.md")) == existingBefore)
    }
}
