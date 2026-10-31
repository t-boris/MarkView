import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1 }
    print("\(condition ? "ok  " : "FAIL") \(message)")
}
let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let paths = ["api.py", "service.py", "repository.py", "schema.sql", "web/app.js"]
var files = paths.map { path in ArchNode(id: "m:" + path, parent: "m:", kind: "file", name: (path as NSString).lastPathComponent, path: path,
                                        language: path.hasSuffix(".py") ? "python" : path.hasSuffix(".sql") ? "sql" : "javascript", loc: 20, files: 1) }
files.append(ArchNode(id: "m:README.md", parent: "m:", kind: "file", name: "README.md", path: "README.md", language: "markdown"))
let modules = ArchView(id: "modules", nodes: [ArchNode(id: "m:", kind: "root", name: "Shop", signature: "sig1")] + files,
                       edges: [.init(source: "m:api.py", target: "m:service.py", kind: "imports"),
                               .init(source: "m:api.py", target: "m:repository.py", kind: "imports"),
                               .init(source: "m:README.md", target: "m:api.py", kind: "links")])
var snapshot = ArchitectureSnapshot(views: [modules], coverage: [:], deploymentHints: [], scannedAt: Date())
let draft = CodeArchitecture.view(snapshot)
check(draft.nodes.filter { $0.kind == "file" }.count == 5, "code-only view includes every language and excludes documents")
check(draft.nodes.contains { $0.kind == "layer" && $0.role == "data" }, "SQL appears in the data layer without AI")
check(draft.edges.count == 2, "code dependencies retained; document links excluded")
func treeIsValid(_ view: ArchView) -> Bool {
    let ids = Set(view.nodes.map(\.id)), parents = Dictionary(view.nodes.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
    guard ids.count == view.nodes.count else { return false }
    for node in view.nodes {
        var current = node.parent, seen = Set([node.id])
        while let id = current {
            guard ids.contains(id), seen.insert(id).inserted else { return false }
            current = parents[id] ?? nil
        }
    }
    return true
}
check(treeIsValid(draft), "draft hierarchy has unique ids, valid parents and no cycles")
var model = CodeArchitectureModel(name: "Order shop", purpose: "Places orders through a web API and saves them in SQLite.", components: [
    .init(id: "server", name: "Order backend", purpose: "Accepts and stores orders", parent: "", layer: "application", paths: ["api.py", "service.py", "repository.py"], evidence: "api.py:8"),
    .init(id: "api", name: "Order API", purpose: "Accepts HTTP orders", parent: "server", layer: "application", paths: ["api.py"], evidence: "api.py:9"),
    .init(id: "service", name: "Order rules", purpose: "Validates quantity and calculates total", parent: "server", layer: "domain", paths: ["service.py"], evidence: "service.py:5"),
    .init(id: "data", name: "Order storage", purpose: "Persists orders in SQLite", parent: "server", layer: "data", paths: ["repository.py", "schema.sql"], evidence: "repository.py:8"),
    .init(id: "web", name: "Order client", purpose: "Submits orders", parent: "", layer: "presentation", paths: ["web"], evidence: "web/app.js:2")
], signature: "sig1", analyzedAt: Date(), dependencies: [
    .init(source: "web", target: "api", label: "posts order", evidence: "web/app.js:2"),
    .init(source: "api", target: "service", label: "validates order", evidence: "api.py:16"),
    .init(source: "service", target: "data", label: "saves order", evidence: "service.py:9")
])
check((try? CodeArchitecture.validateModel(model, modules: modules, root: fixture)) != nil, "source-backed nested model accepted")
snapshot.codeModel = model
let modelView = CodeArchitecture.view(snapshot)
check(treeIsValid(modelView), "cross-layer nested components remain a valid tree")
check(modelView.edges.filter { $0.evidence != nil }.count == 3, "cross-language component dependencies retain their source citations")
check(modelView.nodes.filter { $0.kind == "file" }.count == 5, "AI projection does not duplicate or drop files")
let serviceFile = modelView.nodes.first { $0.path == "service.py" && $0.kind == "file" }!
check(serviceFile.role == "domain" && serviceFile.parent!.contains("service"), "most specific, deepest component wins over subsystem ownership")
check(modelView.nodes.first { $0.id == "code:layer:data" }?.files == 2, "layer metrics count source files once")
let badCycle = CodeArchitectureModel(name: "Bad", purpose: "", components: [
    .init(id: "a", name: "A", purpose: "", parent: "b", layer: "data", paths: ["api.py"], evidence: "api.py:1"),
    .init(id: "b", name: "B", purpose: "", parent: "a", layer: "data", paths: ["api.py"], evidence: "api.py:1")])
check((try? CodeArchitecture.validateModel(badCycle, modules: modules, root: fixture)) == nil, "cyclic AI hierarchy rejected")
var badDependency = model; badDependency.dependencies![0].target = "invented"
check((try? CodeArchitecture.validateModel(badDependency, modules: modules, root: fixture)) == nil, "dependencies to invented components rejected")
badDependency = model; badDependency.dependencies![0].evidence = "schema.sql:9999"
check((try? CodeArchitecture.validateModel(badDependency, modules: modules, root: fixture)) == nil, "dependencies with invalid citations rejected")
var badModel = model; badModel.components[0].paths = ["missing.py"]
check((try? CodeArchitecture.validateModel(badModel, modules: modules, root: fixture)) == nil, "invented component paths rejected")
badModel = model; badModel.components[0].evidence = "api.py:99999"
check((try? CodeArchitecture.validateModel(badModel, modules: modules, root: fixture)) == nil, "invalid component source lines rejected")
badModel = model; badModel.components[0].id = "api"
check((try? CodeArchitecture.validateModel(badModel, modules: modules, root: fixture)) == nil, "duplicate component ids rejected")
var withSymbols = snapshot
withSymbols.views[0].nodes += [ArchNode(id: "symbol:type", parent: "m:service.py", kind: "group", name: "OrderService", path: "service.py"),
                              ArchNode(id: "symbol:method", parent: "symbol:type", kind: "entity", name: "place_order", path: "service.py", line: 5)]
let symbols = CodeArchitecture.view(withSymbols)
check(treeIsValid(symbols) && symbols.nodes.contains { $0.kind == "entity" && $0.line == 5 }, "symbol drill-down retains source line and all intermediate levels")
check(CodeArchitecture.sourceLocation("../api.py:1", root: fixture) == nil && CodeArchitecture.sourceLocation("/etc/passwd:1", root: fixture) == nil, "outside evidence paths rejected")
check(CodeArchitecture.sourceLocation("api.py:0", root: fixture) == nil && CodeArchitecture.sourceLocation("api.py:99999", root: fixture) == nil, "zero and out-of-range evidence rejected")
let symlinkRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
try FileManager.default.createSymbolicLink(at: symlinkRoot.appendingPathComponent("outside.py"), withDestinationURL: fixture.appendingPathComponent("api.py"))
check(CodeArchitecture.sourceLocation("outside.py:1", root: symlinkRoot) == nil, "symlink escaping the project rejected")
try FileManager.default.removeItem(at: symlinkRoot)
var diagram = DiagramSpec(title: "Place an order", question: "How is an order saved?", takeaway: "The API validates quantity through OrderService and persists the order through OrderRepository.", direction: "LR", nodes: [
    .init(id: "api", label: "Order API", kind: "api", source: "api.py:9"),
    .init(id: "service", label: "OrderService", kind: "service", source: "service.py:5"),
    .init(id: "repository", label: "OrderRepository", kind: "database", source: "repository.py:8")
], edges: [
    .init(from: "api", to: "service", label: "1. place order", evidence: "api.py:16"),
    .init(from: "service", to: "repository", label: "2. save order", evidence: "service.py:9")
], omitted: "One successful static path. Invalid quantity raises ValueError before the insert.")
check((try? CodeArchitecture.validateSequence(diagram, root: fixture)) != nil, "sequence with ordered, source-backed messages accepted")
var badSequence = diagram; badSequence.edges[0].label = "2. out of order"
check((try? CodeArchitecture.validateSequence(badSequence, root: fixture)) == nil, "unordered sequence rejected")
badSequence = diagram; badSequence.edges[0].evidence = "missing.py:1"
check((try? CodeArchitecture.validateSequence(badSequence, root: fixture)) == nil, "sequence with invented evidence rejected")
let mermaid = CodeArchitecture.sequenceMermaid(diagram)
check(mermaid.hasPrefix("sequenceDiagram\n") && mermaid.contains("p0->>p1: 1. place order"), "sequence is a time-axis Mermaid diagram")
var unsafe = diagram; unsafe.nodes[0].label = "API\nparticipant evil as <script>;"
check(!CodeArchitecture.sequenceMermaid(unsafe).contains("<script>") && !CodeArchitecture.sequenceMermaid(unsafe).contains("\nparticipant evil"), "model labels cannot inject Mermaid statements or HTML")
snapshot.codeSequences = [.init(scope: "code:", signature: "sig1", diagram: diagram, createdAt: Date())]
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let encoded = try encoder.encode(snapshot)
var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
old.removeValue(forKey: "codeSequences"); old.removeValue(forKey: "codeModel")
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
check((try? decoder.decode(ArchitectureSnapshot.self, from: JSONSerialization.data(withJSONObject: old))) != nil, "pre-Code snapshots still decode")
let restored = try decoder.decode(ArchitectureSnapshot.self, from: encoded)
check(restored.codeModel?.components.count == 5 && restored.codeSequences?.count == 1, "model and sequences survive snapshot encoding")
snapshot.views.append(CodeArchitecture.view(withSymbols))
let payload: [String: Any] = ["root": fixture.path, "snapshot": try JSONSerialization.jsonObject(with: encoder.encode(snapshot)),
                            "codeSequenceDiagrams": [mermaid], "busy": false, "filters": [], "prSources": []]
try JSONSerialization.data(withJSONObject: payload).write(to: output.appendingPathComponent("payload.json"))
try JSONSerialization.data(withJSONObject: CodeArchitecture.schema).write(to: output.appendingPathComponent("schema.json"))
try CodeArchitecture.prompt(root: fixture, files: paths).write(to: output.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
print("\(failures) failures")
exit(failures == 0 ? 0 : 1)
