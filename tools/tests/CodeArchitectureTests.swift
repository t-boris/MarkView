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
badDependency = model; badDependency.dependencies![1].evidence = "web/app.js:2"
check((try? CodeArchitecture.validateModel(badDependency, modules: modules, root: fixture)) == nil, "a real file in an unrelated component cannot prove a dependency")
var subsystemDependency = model
subsystemDependency.dependencies = [.init(source: "web", target: "server", label: "posts order", evidence: "api.py:9")]
check((try? CodeArchitecture.validateModel(subsystemDependency, modules: modules, root: fixture)) != nil, "a nested implementation can support its containing subsystem's dependency")
var badModel = model; badModel.components[0].paths = ["missing.py"]
check((try? CodeArchitecture.validateModel(badModel, modules: modules, root: fixture)) == nil, "invented component paths rejected")
badModel = model; badModel.components[0].evidence = "api.py:99999"
check((try? CodeArchitecture.validateModel(badModel, modules: modules, root: fixture)) == nil, "invalid component source lines rejected")
badModel = model; badModel.components[0].id = "api"
check((try? CodeArchitecture.validateModel(badModel, modules: modules, root: fixture)) == nil, "duplicate component ids rejected")
let excerpts = CodeArchitecture.sourceEvidence(root: fixture, modules: modules)
check(excerpts.contains("FILE repository.py") && excerpts.contains("INSERT INTO orders"), "analysis receives storage implementation evidence, not only file names")
check(excerpts.contains("9:         return self.repository.save"), "source excerpts preserve exact implementation line numbers")
check(CodeArchitecture.sourceEvidence(root: fixture, modules: modules, limit: 350).count <= 350, "source evidence respects the analysis context budget")
var incompletePaths = model
for i in incompletePaths.components.indices { incompletePaths.components[i].paths = ["missing-\(i).py"] }
do {
    try CodeArchitecture.validateModel(incompletePaths, modules: modules, root: fixture)
    check(false, "invalid ownership must request repair")
} catch {
    let feedback = CodeArchitecture.repairFeedback(for: error)
    check((0..<model.components.count).allSatisfy { feedback.contains("missing-\($0).py") }, "repair feedback includes affected paths beyond the three user-facing errors")
    let previous = String(decoding: try JSONEncoder().encode(incompletePaths), as: UTF8.self)
    let repair = CodeArchitecture.repairPrompt(base: "Read the source", answer: previous, error: error)
    check(repair.contains(previous) && repair.contains("missing-4.py"), "the repair request retains the complete prior model and its component identities")
}
var deeper = snapshot
var deeperModel = model
deeperModel.components.append(.init(id: "order-logic", name: "Order processing", purpose: "Coordinates rules and persistence", parent: "server", layer: "application", paths: ["service.py", "repository.py", "schema.sql"], evidence: "service.py:5"))
for i in deeperModel.components.indices where ["service", "data"].contains(deeperModel.components[i].id) { deeperModel.components[i].parent = "order-logic" }
deeper.codeModel = deeperModel
let deeperView = CodeArchitecture.view(deeper)
let deeperIndex = Dictionary(deeperView.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
var cursor = deeperView.nodes.first { $0.kind == "file" && $0.path == "service.py" }?.parent
var componentDepth = 0
while let id = cursor, let node = deeperIndex[id] { if node.kind == "component" { componentDepth += 1 }; cursor = node.parent }
check(treeIsValid(deeperView) && componentDepth == 3, "three nested responsibility levels survive the layer projection")
var untagged = snapshot
untagged.codeModel = nil
untagged.views[0].nodes.append(ArchNode(id: "m:tests/order_test.py", parent: "m:", kind: "file", name: "order_test.py", path: "tests/order_test.py", language: "python"))
let tagged = CodeArchitecture.view(untagged)
check(tagged.nodes.first { $0.path == "tests/order_test.py" && $0.kind == "file" }?.tags?.contains("tests") == true, "tests can be hidden before Logical analysis has assigned any tags")
check(CodePathTags.tags("src/OrderTests.swift", isFile: true, language: "swift").contains("tests"), "tests beside production code keep their shared path classification")
check(CodePathTags.tags("vendor/glue.js", isFile: true, language: "javascript").contains("generated"), "unminified vendor glue is classified as generated code")
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
let escaping = ArchView(id: "modules", nodes: [ArchNode(id: "m:outside.py", kind: "file", name: "outside.py", path: "outside.py", language: "python")], edges: [])
check(CodeArchitecture.sourceEvidence(root: symlinkRoot, modules: escaping).isEmpty, "source excerpts do not follow a symlink outside the selected root")
try "let first = 1\r\nlet second = 2\r\n".write(to: symlinkRoot.appendingPathComponent("lines.swift"), atomically: true, encoding: .utf8)
let crlf = ArchView(id: "modules", nodes: [ArchNode(id: "m:lines.swift", kind: "file", name: "lines.swift", path: "lines.swift", language: "swift")], edges: [])
check(CodeArchitecture.sourceEvidence(root: symlinkRoot, modules: crlf).contains("2: let second = 2"), "CRLF source excerpts use the editor's physical line numbers")
check(CodeArchitecture.sourceLocation("lines.swift:4", root: symlinkRoot) == nil, "CRLF evidence cannot cite a line past the editor's file end")
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
// Coverage: the shipping tables say python/javascript/swift extract dependencies and
// outline declarations, java outlines but (here) extracts nothing, sql has neither.
let capabilities = CodeCoverage.Capabilities(dependencyLanguages: ["python", "javascript", "swift"],
                                             outlineLanguages: ["python", "javascript", "swift", "java"])
func language(_ report: CodeCoverage, _ id: String) -> CodeCoverage.Language? { report.languages.first { $0.language == id } }
let scanOnly = CodeArchitecture.coverage(modules: modules, model: nil, skipped: [], capabilities: capabilities)
check(scanOnly.version == CodeCoverage.currentVersion && !scanOnly.hasModel, "coverage carries its format version and whether a model informed it")
check(scanOnly.languages.map(\.language) == ["javascript", "python", "sql"], "coverage lists the project's code languages in a stable order and leaves documents out")
check(scanOnly.languages.allSatisfy { $0.level == .partial && $0.full == 0 } && language(scanOnly, "python")?.partial == 3, "without a model every language is at most partial")
check(scanOnly.unassignedFiles == 0 && scanOnly.reasons.contains { $0.hasPrefix("No code model yet") }, "a scan-only report says the model is missing instead of counting files as unassigned")
check(scanOnly.reasons.contains("sql: no import or type-reference extraction (1 file)") && scanOnly.reasons.contains("sql: no declaration outline (1 file)")
      && !scanOnly.reasons.contains { $0.hasPrefix("python:") }, "missing scanner capabilities are named per language")
let analyzed = CodeArchitecture.coverage(modules: modules, model: model, skipped: [], capabilities: capabilities)
check(language(analyzed, "python")?.level == .full && language(analyzed, "python")?.full == 3
      && language(analyzed, "javascript")?.level == .full, "languages with dependencies, outlines and component ownership are fully understood")
check(language(analyzed, "sql")?.level == .partial && language(analyzed, "sql")?.partial == 1, "a language the scanner cannot parse stays partial even when the model owns its files")
check(analyzed.hasModel && analyzed.unassignedFiles == 0 && !analyzed.reasons.contains { $0.hasPrefix("No code model") }, "a complete model leaves no unassigned files")
var withStrays = modules
withStrays.nodes += [ArchNode(id: "m:scripts/tool.py", parent: "m:", kind: "file", name: "tool.py", path: "scripts/tool.py", language: "python"),
                     ArchNode(id: "m:Model.java", parent: "m:", kind: "file", name: "Model.java", path: "Model.java", language: "java")]
let strays = CodeArchitecture.coverage(modules: withStrays, model: model, skipped: [], capabilities: capabilities)
check(language(strays, "python")?.level == .full && language(strays, "python")?.notAnalyzed == 1 && language(strays, "python")?.full == 3,
      "files outside the model count as not analyzed without hiding the understood ones")
check(language(strays, "java")?.level == .notAnalyzed && strays.unassignedFiles == 2
      && strays.reasons.contains("2 scanned files not owned by any component of the code model"), "a language the model ignores entirely is reported as not analyzed")
let skips = [CodeCoverage.Skipped(language: "javascript", reason: .tooLarge, files: 2),
             CodeCoverage.Skipped(language: "javascript", reason: .generatedBundle, files: 1),
             CodeCoverage.Skipped(language: "toml", reason: .configFormat, files: 4)]
let skipped = CodeArchitecture.coverage(modules: modules, model: model, skipped: skips, capabilities: capabilities)
check(language(skipped, "javascript")?.level == .full && language(skipped, "javascript")?.notAnalyzed == 3 && language(skipped, "javascript")?.files == 4,
      "large and bundled files are counted as not analyzed next to the understood files of their language")
check(language(skipped, "toml")?.level == .notAnalyzed && language(skipped, "toml")?.notAnalyzed == 4, "configuration formats appear as not analyzed languages")
check(skipped.reasons.contains("2 javascript files: larger than the 512 KB parse limit")
      && skipped.reasons.contains("1 javascript file: minified or bundled third-party code")
      && skipped.reasons.contains("4 toml files: configuration, build or plain-text formats without a dependency graph")
      && skipped.skipped == skips, "skipped files keep their reasons per language and the raw groups for a later recomputation")
let emptyModules = ArchView(id: "modules", nodes: [ArchNode(id: "m:", kind: "root", name: "Empty")], edges: [])
let empty = CodeArchitecture.coverage(modules: emptyModules, model: nil, skipped: [], capabilities: capabilities)
check(empty.languages.isEmpty && empty.unassignedFiles == 0 && empty.reasons.isEmpty, "an empty project has an empty report rather than a missing-model complaint")
snapshot.codeSequences = [.init(scope: "code:", signature: "sig1", diagram: diagram, createdAt: Date())]
snapshot.codeCoverage = skipped
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let encoded = try encoder.encode(snapshot)
var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
old.removeValue(forKey: "codeSequences"); old.removeValue(forKey: "codeModel"); old.removeValue(forKey: "codeCoverage")
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let legacy = try? decoder.decode(ArchitectureSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
check(legacy != nil && legacy?.codeCoverage == nil, "pre-Code snapshots still decode, without a coverage report")
let restored = try decoder.decode(ArchitectureSnapshot.self, from: encoded)
check(restored.codeModel?.components.count == 5 && restored.codeSequences?.count == 1, "model and sequences survive snapshot encoding")
check(restored.codeCoverage.map { $0.languages == skipped.languages && $0.reasons == skipped.reasons && $0.skipped == skips && $0.version == skipped.version } == true,
      "the coverage report survives snapshot encoding")
snapshot.views.append(CodeArchitecture.view(withSymbols))
let payload: [String: Any] = ["root": fixture.path, "snapshot": try JSONSerialization.jsonObject(with: encoder.encode(snapshot)),
                            "codeSequenceDiagrams": [mermaid], "busy": false, "filters": [], "prSources": []]
try JSONSerialization.data(withJSONObject: payload).write(to: output.appendingPathComponent("payload.json"))
try JSONSerialization.data(withJSONObject: CodeArchitecture.schema).write(to: output.appendingPathComponent("schema.json"))
try CodeArchitecture.prompt(root: fixture, files: paths).write(to: output.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
print("\(failures) failures")
exit(failures == 0 ? 0 : 1)
