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
// BUG-066: a file no component owns keeps its folders, so a layer shows one folder box instead of
// one box per loose file (hundreds of migrations collapsed every band of a real project).
var looseModules = modules
looseModules.nodes += [ArchNode(id: "m:scripts", parent: "m:", kind: "dir", name: "scripts", path: "scripts"),
                       ArchNode(id: "m:scripts/migrations", parent: "m:scripts", kind: "dir", name: "migrations", path: "scripts/migrations")]
looseModules.nodes += ["001.sql", "002.sql"].map { name in
    ArchNode(id: "m:scripts/migrations/" + name, parent: "m:scripts/migrations", kind: "file", name: name,
             path: "scripts/migrations/" + name, language: "sql", loc: 10, files: 1)
}
var looseSnapshot = snapshot
looseSnapshot.views = [looseModules]
let looseView = CodeArchitecture.view(looseSnapshot)
let looseParents = Dictionary(looseView.nodes.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
check(looseParents["code:f:scripts/migrations/001.sql"] == "code:data:m:scripts/migrations"
      && looseParents["code:data:m:scripts/migrations"] == "code:data:m:scripts"
      && looseParents["code:data:m:scripts"] == "code:layer:data",
      "an unowned file stays in its folders inside its layer")
check(treeIsValid(looseView) && looseView.nodes.filter { $0.kind == "file" }.count == 7
      && looseView.nodes.filter { $0.parent == "code:layer:data" }.count == 2
      && looseView.nodes.first { $0.id == "code:data:m:scripts" }?.files == 2,
      "unowned files are neither duplicated nor dropped; the layer holds the component and one folder")
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

// BUG-046: a citation must be usable, the answer must be told exactly why it is not, and an
// otherwise valid model is not thrown away over a line number.
var citationFormats = model
citationFormats.components[0].evidence = "api.py:8-19"
check((try? CodeArchitecture.validateModel(citationFormats, modules: modules, root: fixture)) != nil, "a line range cites one line of one file")
citationFormats.components[0].evidence = "api.py:8:5"
check((try? CodeArchitecture.validateModel(citationFormats, modules: modules, root: fixture)) != nil, "a line:column citation names its line")
citationFormats.components[0].evidence = "api.py"
check((try? CodeArchitecture.validateModel(citationFormats, modules: modules, root: fixture)) == nil, "a whole-file citation is still not evidence")

func problem(_ broken: CodeArchitectureModel) -> String {
    do { try CodeArchitecture.validateModel(broken, modules: modules, root: fixture); return "" }
    catch { return CodeArchitecture.repairFeedback(for: error) }
}
var citation = model; citation.components[1].evidence = "api.py:900"
check(problem(citation).contains("line 900 is past the end of api.py, which has 24 lines"),
      "a line past the end of the file says so, with the real length")
check(problem(citation).contains("A usable citation in that code is api.py:8"),
      "the repair request names a real definition line in the component's own code")
citation = model; citation.components[1].evidence = "service.py:5"
check(problem(citation).contains("service.py is not one of its own paths (api.py)"),
      "a citation outside the component's paths names the paths it may use")
citation = model; citation.components[1].evidence = "docs/design.md:3"
check(problem(citation).contains("is not a source file of this project"), "a citation outside the inventory says so")
citation = model; citation.components[1].evidence = ""
check(problem(citation).contains("no citation was given"), "a missing citation says so")
citation = model; citation.dependencies![0].evidence = "web/app.js:900"
check(problem(citation).contains("past the end of web/app.js") && problem(citation).contains("A usable citation"),
      "a dependency citation is explained the same way")

var ungrounded = model
ungrounded.components[1].evidence = "api.py:900"
ungrounded.components[4].evidence = "service.py:5"
ungrounded.dependencies![0].evidence = "nowhere.js:1"
check((try? CodeArchitecture.validateModel(ungrounded, modules: modules, root: fixture)) == nil, "unusable citations are rejected first")
let regrounded = CodeArchitecture.groundEvidence(ungrounded, modules: modules, root: fixture)
check((try? CodeArchitecture.validateModel(regrounded, modules: modules, root: fixture)) != nil,
      "grounding repairs the citations of an otherwise valid model")
check(regrounded.components[1].evidence.hasPrefix("api.py:") && regrounded.components[4].evidence.hasPrefix("web/app.js:"),
      "a replaced citation stays inside the component's own paths")
check(regrounded.dependencies![0].evidence.hasPrefix("web/app.js:"), "a replaced dependency citation belongs to an endpoint")
check(regrounded.components[0].evidence == model.components[0].evidence && regrounded.components.count == model.components.count,
      "grounding changes nothing else: valid citations and the assistant's structure stay")
var invented = model; invented.components[0].paths = ["missing.py"]
check((try? CodeArchitecture.validateModel(CodeArchitecture.groundEvidence(invented, modules: modules, root: fixture),
                                           modules: modules, root: fixture)) == nil,
      "grounding does not rescue invented ownership")
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
// Automatic scenarios: the analysis answer proposes them; invalid ones are dropped, each
// with a reason the coverage report repeats, and at most five are kept.
check((CodeArchitecture.schema["required"] as? [String])?.contains("scenarios") == true
      && CodeArchitecture.prompt(root: fixture, files: paths).contains("return scenarios: 3 interaction scenarios (at most 5)"),
      "the analysis request asks for 3 to 5 scenarios chosen from the entry points")
var suggested = model
suggested.scenarios = [
    .init(title: "Place an order", question: "How is an order saved?", scope: "api.py"),
    .init(title: " place an ORDER ", question: "How is an order saved, again?", scope: "service.py"),
    .init(title: "", question: "How is the schema created?", scope: "schema.sql"),
    .init(title: "Load the page", question: "   ", scope: "web/app.js"),
    .init(title: "Escape", question: "How does it escape?", scope: "../api.py"),
    .init(title: "Ghost", question: "How is a ghost traced?", scope: "missing.py"),
    .init(title: "Submit from the web", question: "How does the browser post an order?", scope: "web"),
    .init(title: "Validate", question: "How is quantity validated?", scope: "service.py"),
    .init(title: "Persist", question: "How is a row inserted?", scope: "repository.py"),
    .init(title: "Create schema", question: "How is the table created?", scope: "schema.sql"),
    .init(title: "Sixth", question: "How is the sixth flow handled?", scope: "api.py")
]
let accepted = CodeArchitecture.withAcceptedScenarios(suggested, modules: modules)
check(accepted.scenarios?.map(\.title) == ["Place an order", "Submit from the web", "Validate", "Persist", "Create schema"],
      "scenarios keep their order; duplicates by title, empty fields, outside or unknown scopes and the sixth are dropped")
check(accepted.scenarios?.allSatisfy { $0.title == $0.title.trimmingCharacters(in: .whitespaces) } == true, "accepted scenario fields are trimmed")
let notes = accepted.scenarioNotes ?? []
check(notes.count == 6 && notes.contains("Dropped a duplicate scenario: place an ORDER")
      && notes.filter { $0 == "Dropped a suggested scenario without a title or question" }.count == 2
      && notes.contains { $0.hasPrefix("Dropped the scenario \"Escape\"") && $0.hasSuffix("../api.py") }
      && notes.contains { $0.hasPrefix("Dropped the scenario \"Ghost\"") }
      && notes.contains("Dropped the scenario \"Sixth\": at most 5 automatic scenarios are traced"),
      "every dropped scenario is explained once")
check(!notes.contains { $0.contains("expected") }, "five accepted scenarios raise no shortage note")
var few = model
few.scenarios = [.init(title: "One", question: "How is one done?", scope: "api.py"), .init(title: "Two", question: "How is two done?", scope: "web")]
check(CodeArchitecture.withAcceptedScenarios(few, modules: modules).scenarioNotes == ["The analysis suggested 2 scenarios to trace automatically; 3 were expected"],
      "fewer than three scenarios are reported, not refused")
check(CodeArchitecture.withAcceptedScenarios(model, modules: modules).scenarioNotes == ["The analysis suggested no scenario to trace automatically"]
      && CodeArchitecture.withAcceptedScenarios(model, modules: modules).scenarios == [], "an answer without scenarios is reported as such")
let scenarioCoverage = CodeArchitecture.coverage(modules: modules, model: accepted, skipped: [], capabilities: capabilities)
check(scenarioCoverage.reasons.suffix(6) == notes[...] && scenarioCoverage.languages == analyzed.languages,
      "the coverage report repeats the scenario notes after the language reasons")
// Failed automatic traces and the size cap of the automatic analysis are coverage reasons too.
var untraced = accepted
untraced.tracedSignature = "sig1"
untraced.traceNotes = ["Could not trace the scenario \"Place an order\": the assistant is signed out"]
let untracedCoverage = CodeArchitecture.coverage(modules: modules, model: untraced, skipped: [], capabilities: capabilities)
check(untracedCoverage.reasons.suffix(7) == (notes + untraced.traceNotes!)[...], "trace failures follow the scenario notes in the coverage reasons")
let cappedReason = "Project has 5001 source files; automatic analysis stops at 5000, use Refresh"
let capped = CodeArchitecture.coverage(modules: modules, model: model, skipped: [], capabilities: capabilities, sourceFileCount: 5001)
check(capped.reasons.contains(cappedReason) && capped.reasons.last == cappedReason
      && !CodeArchitecture.coverage(modules: modules, model: model, skipped: [], capabilities: capabilities, sourceFileCount: 5000).reasons.contains(cappedReason)
      && !analyzed.reasons.contains { $0.hasPrefix("Project has") },
      "the size cap is a coverage reason only above 5000 source files of a project X-Ray")
// Sequences: per-sequence staleness through the cited files, automatic ones replaced as a set.
var signed = modules
for i in signed.nodes.indices where signed.nodes[i].kind == "file" { signed.nodes[i].signature = "s-" + signed.nodes[i].path! }
let traced = CodeSequence(scope: "code:", diagram: diagram, modules: signed, auto: true)
check(traced.auto && traced.signature == "sig1" && traced.citedPaths == ["api.py", "repository.py", "service.py"]
      && traced.citedSignatures == ["api.py": "s-api.py", "repository.py": "s-repository.py", "service.py": "s-service.py"],
      "a sequence records the files its participants and messages cite with their signatures")
var lineless = diagram
lineless.nodes.append(.init(id: "browser", label: "Browser", kind: "external", source: "web/app.js"))
check(CodeSequence.citedPaths(of: lineless) == ["api.py", "repository.py", "service.py", "web/app.js"], "citations with and without a line number are both paths")
check(!traced.isStale(modules: signed), "a sequence is fresh while its cited files are unchanged")
var elsewhere = signed
elsewhere.nodes[0].signature = "sig2"
elsewhere.nodes[signed.nodes.firstIndex { $0.path == "web/app.js" }!].signature = "changed"
check(!traced.isStale(modules: elsewhere), "a root change caused by an uncited file does not stale the sequence")
var citedChanged = signed
citedChanged.nodes[signed.nodes.firstIndex { $0.path == "service.py" }!].signature = "changed"
check(traced.isStale(modules: citedChanged), "a changed cited file stales the sequence")
var citedRemoved = signed
citedRemoved.nodes.removeAll { $0.path == "service.py" }
check(traced.isStale(modules: citedRemoved), "a vanished cited file stales the sequence")
let manual = CodeSequence(scope: "code:", signature: "sig1", diagram: diagram, createdAt: Date())
check(!manual.auto && manual.citedPaths.isEmpty && !manual.isStale(modules: signed) && manual.isStale(modules: elsewhere),
      "a sequence without cited paths is manual and falls back to the root signature")
var oldAuto = traced; oldAuto.diagram.title = "Old automatic"
var newAuto = traced; newAuto.diagram.title = "New automatic"
let replaced = CodeArchitecture.replacingAutoSequences(in: [oldAuto, manual], with: [newAuto, manual])
check(replaced.map(\.diagram.title) == ["New automatic", "Place an order"] && replaced.map(\.auto) == [true, false],
      "an automatic refresh replaces automatic sequences and keeps the manual trace")
check(CodeArchitecture.replacingAutoSequences(in: [oldAuto, manual], with: []).map(\.diagram.title) == ["Place an order"],
      "an automatic refresh without results removes nothing manual")
snapshot.codeSequences = [manual, traced]
snapshot.codeModel = untraced
snapshot.codeCoverage = skipped
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let encoded = try encoder.encode(snapshot)
var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
old.removeValue(forKey: "codeSequences"); old.removeValue(forKey: "codeModel"); old.removeValue(forKey: "codeCoverage")
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let legacy = try? decoder.decode(ArchitectureSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
check(legacy != nil && legacy?.codeCoverage == nil, "pre-Code snapshots still decode, without a coverage report")
var beforeScenarios = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
beforeScenarios["codeSequences"] = (beforeScenarios["codeSequences"] as! [[String: Any]]).map { sequence in
    var copy = sequence
    copy.removeValue(forKey: "auto"); copy.removeValue(forKey: "citedPaths"); copy.removeValue(forKey: "citedSignatures")
    return copy
}
var oldModel = beforeScenarios["codeModel"] as! [String: Any]
oldModel.removeValue(forKey: "scenarios"); oldModel.removeValue(forKey: "scenarioNotes")
oldModel.removeValue(forKey: "tracedSignature"); oldModel.removeValue(forKey: "traceNotes")
beforeScenarios["codeModel"] = oldModel
let preScenario = try? decoder.decode(ArchitectureSnapshot.self, from: JSONSerialization.data(withJSONObject: beforeScenarios))
check(preScenario?.codeSequences?.map(\.auto) == [false, false] && preScenario?.codeSequences?.allSatisfy { $0.citedPaths.isEmpty && $0.citedSignatures.isEmpty } == true
      && preScenario?.codeModel?.scenarios == nil && preScenario?.codeModel?.scenarioNotes == nil
      && preScenario?.codeModel?.tracedSignature == nil && preScenario?.codeModel?.traceNotes == nil,
      "sequences and models saved before scenarios decode as manual traces without scenarios or trace records")
let restored = try decoder.decode(ArchitectureSnapshot.self, from: encoded)
check(restored.codeModel?.components.count == 5 && restored.codeSequences?.count == 2, "model and sequences survive snapshot encoding")
check(restored.codeSequences?.map(\.auto) == [false, true] && restored.codeSequences?[1].citedPaths == traced.citedPaths
      && restored.codeSequences?[1].citedSignatures == traced.citedSignatures
      && restored.codeModel?.scenarios == accepted.scenarios && restored.codeModel?.scenarioNotes == notes
      && restored.codeModel?.tracedSignature == "sig1" && restored.codeModel?.traceNotes == untraced.traceNotes,
      "the automatic flag, cited files, scenarios and the trace record survive snapshot encoding")
check(restored.codeCoverage.map { $0.languages == skipped.languages && $0.reasons == skipped.reasons && $0.skipped == skips && $0.version == skipped.version } == true,
      "the coverage report survives snapshot encoding")
snapshot.views.append(CodeArchitecture.view(withSymbols))
let payload: [String: Any] = ["root": fixture.path, "snapshot": try JSONSerialization.jsonObject(with: encoder.encode(snapshot)),
                            "codeSequenceDiagrams": [mermaid, mermaid], "busy": false, "filters": [], "prSources": []]
try JSONSerialization.data(withJSONObject: payload).write(to: output.appendingPathComponent("payload.json"))
try JSONSerialization.data(withJSONObject: CodeArchitecture.schema).write(to: output.appendingPathComponent("schema.json"))
try CodeArchitecture.prompt(root: fixture, files: paths).write(to: output.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
print("\(failures) failures")
exit(failures == 0 ? 0 : 1)
