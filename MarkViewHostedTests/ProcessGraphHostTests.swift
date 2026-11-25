import AppKit
import Foundation
import MarkViewCore
import WebKit
import XCTest
@testable import MarkView

private func processFixture() throws -> (URL, ProcessGraph, ArchView) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-process-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let text = (1...120).map { "value_\($0) = \($0)" }.joined(separator: "\r\n")
    try text.write(to: root.appendingPathComponent("flow.py"), atomically: true, encoding: .utf8)
    let source = ProcessGraph.Source(path: "flow.py", line: 1, endLine: 120, note: "The selected source range.")
    let nodes = ["entry", "result"].map {
        ProcessGraph.Node(id: $0, title: $0, explanation: "Handles the request", input: "Request", output: "Result", sources: [source])
    }
    let graph = ProcessGraph(title: "Request", question: "How is the request handled?", takeaway: "Source-backed flow.", nodes: nodes,
                             edges: [.init(id: "handoff", from: "entry", to: "result", label: "Pass result", sources: [source])])
    let modules = ArchView(id: "modules", nodes: [ArchNode(id: "m:", kind: "root", name: "Fixture", signature: "root-v1"),
        ArchNode(id: "m:flow.py", parent: "m:", kind: "file", name: "flow.py", path: "flow.py", language: "python", signature: "file-v1")], edges: [])
    return (root, graph, modules)
}

@MainActor
private final class ProcessTestHost: ArchitectureHost {
    var snapshot: ArchitectureSnapshot?
    let project: URL?
    let projectRoot: URL? = nil
    var rootPath: String?
    var status: String?
    var isBusy = false
    var response: ProcessGraph
    var calls = 0
    private var token = 0

    init(root: URL, graph: ProcessGraph, modules: ArchView) {
        project = root
        rootPath = root.standardizedFileURL.path
        response = graph
        snapshot = ArchitectureSnapshot(views: [modules], coverage: [:], deploymentHints: [], scannedAt: Date())
    }

    func outline(for path: String) -> XRayContent.Outline? { nil }
    func commit(_ next: ArchitectureSnapshot, db: SemanticDatabase?) { snapshot = next }
    func show(_ next: ArchitectureSnapshot) { snapshot = next }
    func answerCache(_ root: URL) -> URL { root }
    func bump() {}
    func setError(_ message: String?) {}
    func setStatus(_ text: String?) { status = text }
    func beginRun() -> Int { token += 1; isBusy = true; return token }
    func endRun(_ run: Int) { if run == token { isBusy = false } }
    func assistantCall(_ request: CLICompletion.Request, root: URL, db: SemanticDatabase?,
                       call: Int, fresh: Bool) async throws -> [String: Any] {
        try request.validateSchema()
        calls += 1
        let data = try JSONEncoder().encode(response)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

extension EditorHostTests {
    func testProcessSourceClippingAndChangedSource() throws {
        let (root, graph, _) = try processFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let inspected = try ProcessGraphSource.inspect(graph, root: root, allowedPaths: ["flow.py"])
        let snippet = try ProcessGraphSource.snippet(key: "selected", source: graph.nodes[0].sources[0], root: root,
                                                   allowedPaths: ["flow.py"], expectedHash: inspected.hashes["flow.py"])
        XCTAssertEqual(snippet.line, 1)
        XCTAssertEqual(snippet.endLine, 80)
        XCTAssertEqual(snippet.requestedEndLine, 120)
        XCTAssertFalse(snippet.code.contains("\r"))
        XCTAssertFalse(snippet.stale)
        XCTAssertTrue(snippet.truncated)
        XCTAssertEqual(inspected.signatures["flow.py"], ArchitectureScanner.sourceSignature("flow.py", root: root))
        try ("changed = True\n" + snippet.code + String(repeating: "\n", count: 100))
            .write(to: root.appendingPathComponent("flow.py"), atomically: true, encoding: .utf8)
        let changed = try ProcessGraphSource.snippet(key: "selected", source: graph.nodes[0].sources[0], root: root,
                                                   allowedPaths: ["flow.py"], expectedHash: inspected.hashes["flow.py"])
        XCTAssertTrue(changed.stale)
        XCTAssertTrue(changed.code.hasPrefix("changed = True"))
    }

    func testProcessSourceRejectsEscapingSymlinkAndUnknownFiles() throws {
        let (root, graph, _) = try processFixture()
        let (outside, _, _) = try processFixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.py"),
                                                  withDestinationURL: outside.appendingPathComponent("flow.py"))
        let source = ProcessGraph.Source(path: "linked.py", line: 1, endLine: 2)
        XCTAssertThrowsError(try ProcessGraphSource.snippet(key: "x", source: source, root: root,
                                                           allowedPaths: ["linked.py"], expectedHash: nil))
        XCTAssertThrowsError(try ProcessGraphSource.inspect(graph, root: root, allowedPaths: []))
    }

    @MainActor func testProcessTracePersistsAndSourceSelectionUsesSavedEvidence() async throws {
        let (root, graph, modules) = try processFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ProcessTestHost(root: root, graph: graph, modules: modules)
        let store = ProcessGraphStore(host: host)
        let task = store.trace(question: graph.question, root: root, db: nil)
        await task?.value
        let saved = try XCTUnwrap(host.snapshot?.processGraphs?.first)
        XCTAssertEqual(saved.graph.question, graph.question)
        XCTAssertEqual(host.calls, 1)
        XCTAssertFalse(host.isBusy)
        XCTAssertFalse(store.state.tracing)
        store.loadLevel(scenario: saved.id, parent: nil)
        XCTAssertEqual(store.state.levels[saved.id + "|"]?.edges.count, 1)
        let read = store.loadSource(scenario: saved.id, node: "entry", index: 0, root: root)
        await read?.value
        let key = saved.id + "|entry|0"
        XCTAssertEqual(store.state.snippets[key]?.path, "flow.py")
        XCTAssertFalse(try XCTUnwrap(store.state.snippets[key]?.stale))
        XCTAssertNil(store.loadSource(scenario: saved.id, node: "unknown", index: 0, root: root))
        XCTAssertNil(store.loadSource(scenario: saved.id, node: "entry", index: 7, root: root))
    }

    @MainActor func testProcessResetCancelsPendingTrace() async throws {
        let (root, graph, modules) = try processFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = ProcessTestHost(root: root, graph: graph, modules: modules)
        let store = ProcessGraphStore(host: host)
        let task = store.trace(question: graph.question, root: root, db: nil)
        store.reset()
        await task?.value
        XCTAssertNil(host.snapshot?.processGraphs)
        XCTAssertFalse(store.state.tracing)
        XCTAssertTrue(store.state.snippets.isEmpty)
    }

    func testProcessSnapshotsRemainBackwardCompatible() throws {
        let (root, graph, modules) = try processFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var snapshot = ArchitectureSnapshot(views: [modules], coverage: [:], deploymentHints: [], scannedAt: Date())
        let old = try JSONEncoder().encode(snapshot)
        XCTAssertNil(try JSONDecoder().decode(ArchitectureSnapshot.self, from: old).processGraphs)
        snapshot.processGraphs = [.init(graph: graph, signatures: ["flow.py": "v1"], sourceHashes: ["flow.py": "hash"])]
        let restored = try JSONDecoder().decode(ArchitectureSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.processGraphs, snapshot.processGraphs)
    }

    func testProcessCommandsRejectMalformedSelection() {
        XCTAssertEqual(XRayCommand.parse("traceProcess", payload: ["question": "  Process?  "]), .traceProcess(question: "Process?"))
        XCTAssertNil(XRayCommand.parse("traceProcess", payload: ["question": " "]))
        XCTAssertEqual(XRayCommand.parse("processLevel", payload: ["scenario": "saved"]), .processLevel(scenario: "saved", parent: nil))
        XCTAssertNil(XRayCommand.parse("processSource", payload: ["scenario": "saved", "node": "entry", "index": -1]))
        XCTAssertNil(XRayCommand.parse("processSource", payload: ["scenario": "saved", "node": "entry", "index": 8]))
        XCTAssertEqual(XRayCommand.parse("processSource", payload: ["scenario": "saved", "node": "entry", "index": 0]),
                       .processSource(scenario: "saved", node: "entry", index: 0))
    }
}


extension EditorHostTests {
    @MainActor func testProcessGraphGroupsCodeAndViewportInShippingEditor() throws {
        let editor = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let checks = try String(contentsOf: repository.appendingPathComponent("tools/tests/process-graph-web-checks.js"), encoding: .utf8)
        let fixture = try ProcessGraphWebFixture.json()
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let bridge = ArchitectureBridgeRecorder()
        configuration.userContentController.add(bridge, name: "bridge")
        let contract = try BridgeContract(contentsOf: editor.appendingPathComponent("js/bridge-contract.json"))
        configuration.userContentController.addUserScript(contract.userScript)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
            window.contentView = nil
            window.close()
        }
        func spin(_ seconds: TimeInterval, until done: () -> Bool) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        let loaded = ArchitecturePageLoad()
        web.navigationDelegate = loaded
        web.loadFileURL(editor.appendingPathComponent("index.html"), allowingReadAccessTo: editor)
        spin(20) { loaded.done }
        XCTAssertTrue(loaded.done, "shipping editor loaded")
        guard loaded.done else { return }
        var result: Result<Any, Error>?
        web.callAsyncJavaScript(checks + "\nconst state = ProcessGraphWebChecks.setup(JSON.parse(fixtureJSON));"
                                + " return JSON.stringify(await ProcessGraphWebChecks.run(state));",
                                arguments: ["fixtureJSON": fixture], in: nil, in: .page) { result = $0 }
        spin(60) { result != nil }
        let response = try XCTUnwrap(result, "process graph checks finished").get()
        let encoded = try XCTUnwrap(response as? String)
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Int])
        XCTAssertGreaterThanOrEqual(summary["passed"] ?? 0, 40)
        XCTAssertEqual(summary["blocks"], 74)
    }
}
