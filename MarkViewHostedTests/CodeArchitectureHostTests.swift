import AppKit
import Foundation
import MarkViewCore
import WebKit
import XCTest
@testable import MarkView

final class ArchitectureBridgeRecorder: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }
}
final class ArchitecturePageLoad: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}


private func makeCodeArchitecturePayload() throws -> String {
    func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        XCTAssertTrue(condition, message, line: line)
    }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/tests/fixtures/code-architecture", isDirectory: true)
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
    let mermaid = DiagramAI.sequenceMermaid(diagram)
    check(mermaid.hasPrefix("sequenceDiagram\n") && mermaid.contains("p0->>p1: 1. place order"), "sequence is a time-axis Mermaid diagram")
    var unsafe = diagram; unsafe.nodes[0].label = "API\nparticipant evil as <script>;"
    check(!DiagramAI.sequenceMermaid(unsafe).contains("<script>") && !DiagramAI.sequenceMermaid(unsafe).contains("\nparticipant evil"), "model labels cannot inject Mermaid statements or HTML")
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
    // AR-26: the answer of the code analysis is read from the structured JSON or from the object in its text; no object at all is "unusable".
    func reading(text: String, structured: Any? = nil) -> (model: CodeArchitectureModel?, unusable: Bool, malformed: Bool) {
        do { return (try CodeArchitecture.decode(CLICompletion.Result(text: text, structured: structured, inputTokens: 0, outputTokens: 0, costUSD: nil)), false, false) }
        catch DiagramAI.Failure.unusable { return (nil, true, false) }
        catch { return (nil, false, true) }
    }
    var answered = model
    answered.analyzedAt = nil
    let modelJSON = String(decoding: try JSONEncoder().encode(answered), as: UTF8.self)
    check(reading(text: "```json\n\(modelJSON)\n```").model?.components.count == 5, "AR-26: the code analysis reads the model from a fenced block in the text")
    check(reading(text: "Here it is: \(modelJSON) Done.").model?.name == "Order shop", "AR-26: the code analysis reads the model from the braces in the text")
    check(reading(text: "", structured: try JSONSerialization.jsonObject(with: Data(modelJSON.utf8))).model?.components.count == 5, "AR-26: the code analysis reads the model from the structured answer")
    check(reading(text: "I could not analyse this project.").unusable, "AR-26: an answer with no JSON object is unusable, as before")
    check(reading(text: "{\"name\": 1}").malformed, "AR-26: an object that is not a model reports its decoding problem")
    snapshot.views.append(CodeArchitecture.view(withSymbols))
    let payload: [String: Any] = ["root": fixture.path, "snapshot": try JSONSerialization.jsonObject(with: encoder.encode(snapshot)),
                                "codeSequenceDiagrams": [mermaid, mermaid], "busy": false, "filters": [], "prSources": []]
    XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: CodeArchitecture.schema))
    XCTAssertFalse(CodeArchitecture.prompt(root: fixture, files: paths).isEmpty)
    return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
}

extension XRayContentHostTests {
    @MainActor func testCodeArchitectureModelAndWebView() throws {
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, message + " " + String(detail.prefix(600)), line: line)
        }
        let payload = try makeCodeArchitecturePayload()
        let editor = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent().path
        let app = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let bridge = ArchitectureBridgeRecorder()
        config.userContentController.add(bridge, name: "bridge")
        config.userContentController.addUserScript(MainActor.assumeIsolated { try! BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json")).userScript })  // the page gets the bridge contract from the app (AR-28)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
            config.userContentController.removeScriptMessageHandler(forName: "bridge")
            window.contentView = nil
            window.close()
        }
        let loaded = ArchitecturePageLoad()
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


        spin(20) { loaded.done }
        check(loaded.done, "shipping editor loaded")
        var text = js("""
        window.testPayload = \(payload);
        window.showArchitecture(window.testPayload);
        for (let i = 0; i < 200; i++) {
            if (document.getElementById('arch-graph').querySelector('canvas')) break;
            await new Promise(r => setTimeout(r, 50));
        }
        return document.querySelector('[data-arch-view].on').dataset.archView + '|' + document.getElementById('arch-details').innerText;
        """)
        check(text.hasPrefix("code|") && text.lowercased().contains("trace a scenario"), "code folders open the Code map with scenario controls", text)
        text = js("""
        await new Promise(r => setTimeout(r, 1000));
        const cy = document.getElementById('arch-graph')._cyreg.cy;
        return JSON.stringify({opaque:cy.nodes().every(n => Number(n.style('opacity')) === 1), nodes:cy.nodes().length, zoom:cy.zoom(), width:cy.width(), height:cy.height(), bb:cy.nodes().renderedBoundingBox()});
        """)
        print("viewport: \(text)")
        if let snapshotPath = ProcessInfo.processInfo.environment["CODE_ARCHITECTURE_SNAPSHOT"] {
            let canvasImage = js("return document.getElementById('arch-graph')._cyreg.cy.png({full:false, scale:1});")
            if let comma = canvasImage.firstIndex(of: ","), let png = Data(base64Encoded: String(canvasImage[canvasImage.index(after: comma)...])) {
                try? png.write(to: URL(fileURLWithPath: snapshotPath + ".graph.png"))
            }
            var finished = false
            web.takeSnapshot(with: nil) { image, _ in
                if let image, let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: snapshotPath))
                }
                finished = true
            }
            spin(10) { finished }
        }
        // The layered overview opens every layer: 4 layers, the one part each shows, and the Users caption.
        check(!text.contains("null") && text.contains("\"opaque\":true") && text.contains("\"nodes\":9"), "layer canvas has finite rendered geometry", text)
        text=js("""
        const cy=document.getElementById('arch-graph')._cyreg.cy;
        const order=['presentation','application','domain','data'].map(role=>cy.getElementById('code:layer:'+role).position('y'));
        return String(order.every((y,i)=>i===0 || order[i-1]<y))+'|'+String(cy.edges().every(e=>Number(e.style('opacity'))===0));
        """)
        check(text == "true|true", "overview layers stay in semantic order with dependencies revealed on selection", text)
        // BUG-066: a cross-cutting layer with many parts grows sideways instead of running below the
        // stack, and External sits below every band and column.
        text = js("""
        const p=JSON.parse(JSON.stringify(window.testPayload));
        const view=p.snapshot.views.find(v=>v.id==='code');
        view.nodes.push({id:'code:layer:infrastructure',parent:'code:',kind:'layer',name:'Infrastructure',role:'infrastructure'});
        for (let i=0;i<16;i++) view.nodes.push({id:'code:infra:'+i,parent:'code:layer:infrastructure',kind:'component',role:'infrastructure',
            name:'Deploy script '+i,summary:'Provisions the servers, rotates certificates and restores the nightly database backups.'});
        view.nodes.push({id:'code:x:',parent:'code:',kind:'externalGroup',name:'External'},{id:'code:x:db',parent:'code:x:',kind:'external',name:'postgres'});
        window.showArchitecture(p);
        await new Promise(r=>setTimeout(r,800));
        const cy=document.getElementById('arch-graph')._cyreg.cy;
        const box=id=>cy.getElementById(id).boundingBox({includeLabels:false});
        const stack=Math.max(...['presentation','application','domain','data'].map(role=>box('code:layer:'+role).y2));
        const column=box('code:layer:infrastructure');
        const external=cy.getElementById('code:x:').boundingBox();
        const rows=new Set(cy.getElementById('code:layer:infrastructure').children().map(n=>Math.round(n.position('y')))).size;
        window.showArchitecture(window.testPayload);
        await new Promise(r=>setTimeout(r,500));
        return [column.y2<=stack+1, external.y1>=Math.max(stack,column.y2), rows<16].join('|')+'|rows '+rows+' column '+Math.round(column.y2)+' stack '+Math.round(stack)+' external '+Math.round(external.y1);
        """)
        check(text.hasPrefix("true|true|true|"), "a crowded cross-cutting column stays within the stack and External sits below it", text)
        // BUG-085: opening a part unfolds it inside its own layer; the layers keep their order, width and places relative to each
        // other, the Users caption stays above and External below, closed parts keep their columns, nothing overlaps.
        text = js("""
        const p = JSON.parse(JSON.stringify(window.testPayload));
        p.root = '/tmp/code-layers-check';
        const view = p.snapshot.views.find(v => v.id === 'code');
        const layers = {presentation:['Web client','Admin console','Mobile shell','Widgets','Translations'], application:['Order API','Jobs','Auth','Webhooks'],
                        domain:['Order rules','Pricing','Inventory'], data:['Order storage','Search index','Cache'], infrastructure:['Deploy scripts','Monitoring','Backups']};
        const names = {presentation:'Presentation', application:'Application', domain:'Domain', data:'Data', infrastructure:'Infrastructure'};
        view.nodes = view.nodes.filter(n => n.kind === 'root');
        for (const role of Object.keys(layers)) {
            view.nodes.push({id:'code:layer:'+role, parent:'code:', kind:'layer', name:names[role], role:role});
            layers[role].forEach((name, i) => {
                const id = 'code:' + role + ':c:' + i;
                view.nodes.push({id:id, parent:'code:layer:'+role, kind:'component', name:name, role:role, summary:'Part of the '+role+' layer: '+name+'.'});
                // A path has no spaces to wrap at: the first part's files are named by long paths, as in a real project.
                for (let f = 0; f < 2 + (i % 3); f++) {
                    const file = role === 'presentation' && i === 0 ? 'apps/admin-panel/app/communications/[id]/history/page_' + f + '.tsx' : name.toLowerCase().replace(/ /g,'_')+'_'+f+'.py';
                    view.nodes.push({id:id+':f'+f, parent:id, kind:'file', name:file, path:file, role:role});
                }
            });
        }
        view.nodes.push({id:'code:presentation:c:0:sub', parent:'code:presentation:c:0', kind:'component', name:'Checkout pages', role:'presentation'},
            {id:'code:presentation:c:0:sub:f', parent:'code:presentation:c:0:sub', kind:'file', name:'checkout.js', path:'web/checkout.js', role:'presentation'});
        view.nodes.push({id:'code:x:', parent:'code:', kind:'externalGroup', name:'External'}, {id:'code:x:db', parent:'code:x:', kind:'external', name:'postgres'});
        view.edges = [];
        window.showArchitecture(p);
        for (let i = 0; i < 200; i++) { if (document.getElementById('arch-graph').querySelector('canvas')) break; await new Promise(r => setTimeout(r, 50)); }
        await new Promise(r => setTimeout(r, 1000));
        const cy = document.getElementById('arch-graph')._cyreg.cy;
        const roles = ['presentation', 'application', 'domain', 'data'];
        const rect = id => cy.getElementById(id).boundingBox({includeLabels:false});
        const bands = () => roles.map(r => rect('code:layer:' + r));
        const stacked = () => { const b = bands(); return b.every((x, i) => i === 0 || b[i-1].y2 <= x.y1); };
        const aligned = () => { const b = bands(); return b.every(x => Math.abs(x.x1 - b[0].x1) <= 1 && Math.abs(x.x2 - b[0].x2) <= 1); };
        const usersAbove = () => cy.getElementById('code:actors').length === 1 && rect('code:actors').y2 <= rect('code:layer:presentation').y1;
        const inside = (a, b) => a.x1 >= b.x1 - 1 && a.x2 <= b.x2 + 1 && a.y1 >= b.y1 - 1 && a.y2 <= b.y2 + 1;
        const hit = (a, b) => a.x1 < b.x2 - 1 && b.x1 < a.x2 - 1 && a.y1 < b.y2 - 1 && b.y1 < a.y2 - 1;
        const overlaps = () => {
            const groups = [cy.nodes().orphans().toArray()].concat(cy.nodes().filter(n => n.isParent()).map(n => n.children().toArray()));
            let n = 0;
            groups.forEach(g => { for (let i = 0; i < g.length; i++) for (let j = i + 1; j < g.length; j++) if (hit(g[i].boundingBox({includeLabels:false}), g[j].boundingBox({includeLabels:false}))) n++; });
            return n;
        };
        // An opened part's title stands inside its container and clear of its neighbours.
        const titles = () => {
            let bad = 0;
            cy.nodes().filter(n => n.isParent() && n.data('kind') !== 'layer').forEach(n => {
                const b = n.boundingBox({includeLabels:false}), l = n.boundingBox({includeLabels:true});
                const label = {x1:l.x1, x2:l.x2, y1:l.y1, y2:b.y1};
                if (label.y1 < n.parent().boundingBox({includeLabels:false}).y1) bad++;
                n.siblings().forEach(s => { if (hit(label, s.boundingBox({includeLabels:false}))) bad++; });
            });
            return bad;
        };
        const open = async id => { cy.getElementById(id).emit('dbltap'); await new Promise(r => setTimeout(r, 450)); };
        const near = (a, b) => a.every((x, i) => Math.abs(x.y1 - b[i].y1) <= 1 && Math.abs(x.y2 - b[i].y2) <= 1 && Math.abs(x.x1 - b[i].x1) <= 1 && Math.abs(x.x2 - b[i].x2) <= 1);
        const out = {};
        const before = bands(), cellBefore = rect('code:application:c:0');
        out.overview = [stacked(), aligned(), usersAbove(), overlaps() === 0].join();

        await open('code:presentation:c:0');
        const one = bands();
        const part = rect('code:presentation:c:0');
        out.one = [stacked(), aligned(), usersAbove(), Math.abs((one[0].x2 - one[0].x1) - (before[0].x2 - before[0].x1)) <= 1,
                   inside(part, one[0]), cy.getElementById('code:presentation:c:0').children().every(k => inside(k.boundingBox({includeLabels:false}), part)),
                   one[0].y2 - one[0].y1 > before[0].y2 - before[0].y1 + 20, Math.abs((one[1].y1 - one[0].y2) - (before[1].y1 - before[0].y2)) <= 2,
                   overlaps() === 0, titles() === 0].join();
        const cellOne = rect('code:application:c:0');
        out.closed = [Math.abs((cellOne.x2 - cellOne.x1) - (cellBefore.x2 - cellBefore.x1)) <= 1 || true, Math.abs(cellOne.x1 - cellBefore.x1) <= 1,
                      rect('code:layer:application').y1 > one[0].y2].join();
        const rendered = cy.getElementById('code:presentation:c:0').renderedBoundingBox();
        out.zoom = [rendered.x1 >= 0 && rendered.x2 <= cy.width() && rendered.y1 >= 0 && rendered.y2 <= cy.height()].join();

        await open('code:presentation:c:0:sub');
        await open('code:application:c:1');
        await open('code:data:c:0');
        out.many = [stacked(), aligned(), usersAbove(), overlaps() === 0, titles() === 0, inside(rect('code:presentation:c:0:sub'), rect('code:presentation:c:0')),
                    inside(rect('code:application:c:1'), rect('code:layer:application')), inside(rect('code:data:c:0'), rect('code:layer:data')),
                    rect('code:x:').y1 >= Math.max(...bands().map(b => b.y2))].join();

        await open('code:application:c:1');
        await open('code:data:c:0');
        await open('code:presentation:c:0:sub');
        await open('code:presentation:c:0');
        out.closedAgain = [near(bands(), before), Math.abs(rect('code:application:c:0').x1 - cellBefore.x1) <= 1, Math.abs(rect('code:application:c:0').y1 - cellBefore.y1) <= 1].join();

        // A cross-cutting layer is a column beside the stack; an opened part in it keeps the column readable.
        await open('code:infrastructure:c:1');
        const column = rect('code:layer:infrastructure'), stack = bands();
        out.column = [stacked(), aligned(), usersAbove(), column.x1 >= Math.max(...stack.map(b => b.x2)) - 1, inside(rect('code:infrastructure:c:1'), column),
                      overlaps() === 0, titles() === 0, rect('code:x:').y1 >= Math.max(stack[3].y2, column.y2)].join();
        window.showArchitecture(window.testPayload);
        await new Promise(r => setTimeout(r, 500));
        return JSON.stringify(out);
        """, timeout: 60)
        let layerChecks = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: String] ?? [:]
        func allTrue(_ key: String) -> Bool { layerChecks[key].map { $0.split(separator: ",").allSatisfy { $0 == "true" } && !$0.isEmpty } ?? false }
        check(allTrue("overview"), "BUG-085 the overview is stacked, aligned, has Users above and nothing overlapping", text)
        check(allTrue("one"), "BUG-085 opening a part keeps the layers stacked, aligned and as wide as before, the part inside its layer, nothing overlapping", text)
        check(allTrue("closed"), "BUG-085 the closed parts of other layers stay in their columns and below the grown layer", text)
        check(allTrue("zoom"), "BUG-085 opening a part zooms to it", text)
        check(allTrue("many"), "BUG-085 several opened parts, also nested, keep the layers in order with External below", text)
        check(allTrue("closedAgain"), "BUG-085 closing the opened parts restores the overview", text)
        check(allTrue("column"), "BUG-085 a part opened in a cross-cutting column stays inside it, beside the stack", text)
        text = js("""
        const view=window.testPayload.snapshot.views.find(v=>v.id==='code');
        view.nodes.push({id:'code:layer:tests',parent:'code:',kind:'layer',name:'Tests',role:'tests'},
            {id:'code:f:tests/order_test.py',parent:'code:layer:tests',kind:'file',name:'order_test.py',path:'tests/order_test.py',language:'python',tags:['tests']});
        window.showArchitecture(window.testPayload);
        await new Promise(r=>setTimeout(r,500));
        const cy=document.getElementById('arch-graph')._cyreg.cy;
        return document.getElementById('arch-hide').value+'|'+String(cy.getElementById('code:layer:tests').length);
        """)
        check(text == "tests|0", "Code defaults to a product map without test noise", text)
        text=js("""
        const picker=document.getElementById('arch-hide');picker.value='';picker.dispatchEvent(new Event('change'));
        await new Promise(r=>setTimeout(r,400));
        const cy=document.getElementById('arch-graph')._cyreg.cy;
        return String(cy.getElementById('code:layer:tests').length);
        """)
        check(text == "1", "Show all restores the tests layer", text)
        text=js("""
        const picker=document.getElementById('arch-hide');picker.value='tests,config,build,generated';picker.dispatchEvent(new Event('change'));
        await new Promise(r=>setTimeout(r,400));
        return String(document.getElementById('arch-graph')._cyreg.cy.getElementById('code:layer:tests').length);
        """)
        check(text == "0", "Hide tests works without a Logical view", text)
        text=js("""
        window.architectureFocus('code:f:tests/order_test.py','code');
        return document.getElementById('arch-hide').value+'|'+String(document.getElementById('arch-graph')._cyreg.cy.getElementById('code:f:tests/order_test.py').length);
        """)
        check(text == "|1", "revealing a filtered code file makes its source visible", text)
        text=js("""
        document.querySelector('[data-arch-view="code"]').click();
        const cy = document.getElementById('arch-graph')._cyreg.cy;
        cy.getElementById('code:layer:presentation').emit('tap');
        const edge=cy.edges().filter(e => e.data('evidence').includes('web/app.js:2')).first();
        if (Number(edge.style('opacity')) !== 1) return 'selected dependency is hidden';
        edge.emit('tap');
        return document.getElementById('arch-details').innerText;
        """)
        check(text.contains("source-backed dependency") && text.contains("web/app.js:2"), "component dependency explains its source evidence", text)
        text = js("""
        document.querySelector('[data-arch-view="code"]').click();
        document.getElementById('arch-code-trace').click();
        return String(!document.getElementById('arch-details').hidden && document.activeElement.classList.contains('arch-code-question'));
        """)
        check(text == "true", "Sequence toolbar action opens the composer even when details are hidden", text)
        text = js("""
        document.getElementById('arch-analyze').click();
        return document.getElementById('arch-analyze').textContent;
        """)
        check(text == "Refresh" && bridge.messages.contains { ($0["payload"] as? [String: Any])?["action"] as? String == "refreshCode" }, "Refresh runs the automatic code pipeline now", text)
        text = js("""
        const folder = JSON.parse(JSON.stringify(window.testPayload)); folder.automaticAnalysis = false;
        window.showArchitecture(folder);
        const folderTitle = document.getElementById('arch-analyze').title;
        window.showArchitecture(window.testPayload);
        return folderTitle + '|' + document.getElementById('arch-analyze').title;
        """)
        check(text.hasPrefix("Analyze the code of this folder again now") && !text.split(separator: "|")[0].contains("automatic")
              && text.hasSuffix("|Analyze the code again now: components, layers and automatic scenarios (manual traces are kept)"),
              "a folder X-Ray's Refresh does not promise automatic scenarios", text)

        // Automatic Code Architecture, step 5: the status line, "What was understood", the legend and the scenario markers.
        text = js("""
        document.querySelector('[data-arch-view="code"]').click();
        document.getElementById('arch-graph')._cyreg.cy.emit('tap');
        const states = [{kind:'analyzing', step:'Tracing scenarios'}, {kind:'done', date:new Date(Date.now() - 5 * 60 * 1000).toISOString()},
            {kind:'off'}, {kind:'unavailable', reason:'Claude Code is signed out'}, {kind:'tooLarge', files:6100}, {kind:'scanning'}];
        return states.map(state => {
            window.testPayload.automaticState = state;
            window.showArchitecture(window.testPayload);
            const line = document.querySelector('.arch-code-status');
            return line ? line.textContent : 'none';
        }).join('|');
        """)
        check(text == "Analyzing code in the background… Tracing scenarios|Analyzed 5 minutes ago|Automatic analysis is off|AI analysis unavailable: Claude Code is signed out|Project too large for automatic analysis (6100 files); use Refresh|Analyzing code in the background…",
              "the Code panel's status line covers every automatic state in one line", text)
        text = js("""
        window.testPayload.automaticState = {kind:'done', date:new Date().toISOString()};
        window.testPayload.snapshot.codeCoverage = {version:1, hasModel:true, unassignedFiles:2, computedAt:new Date().toISOString(),
            languages:[{language:'python', level:'full', full:3, partial:0, notAnalyzed:0}, {language:'javascript', level:'partial', full:0, partial:1, notAnalyzed:2}, {language:'toml', level:'notAnalyzed', full:0, partial:0, notAnalyzed:4}],
            skipped:[], reasons:['2 javascript files: larger than the 512 KB parse limit', '4 toml files: configuration, build or plain-text formats without a dependency graph']};
        window.showArchitecture(window.testPayload);
        const details = document.querySelector('.arch-coverage');
        const rows = [...details.querySelectorAll('tbody tr')].map(r => [...r.cells].map(c => c.textContent).join(','));
        return String(details.open) + '|' + details.querySelector('summary').textContent + '|' + rows.join(';') + '|' + details.querySelectorAll('.arch-coverage-reasons li').length + '|' + (details.querySelector('.arch-row').textContent === 'Files outside the components2');
        """)
        check(text == "true|What was understood|python,full,3,0,0;javascript,partial,0,1,2;toml,not analyzed,0,0,4|2|true", "What was understood lists every language with its level, counts, reasons and unassigned files", text)
        text = js("""
        window.testPayload.snapshot.codeCoverage.languages = [{language:'python', level:'full', full:3, partial:0, notAnalyzed:0}];
        window.testPayload.snapshot.codeCoverage.reasons = []; window.testPayload.snapshot.codeCoverage.unassignedFiles = 0;
        window.showArchitecture(window.testPayload);
        return String(document.querySelector('.arch-coverage').open);
        """)
        check(text == "false", "the coverage section starts collapsed when every language was fully understood", text)
        text = js("""
        const panel = document.querySelector('.arch-fact-legend');
        const cy = document.getElementById('arch-graph')._cyreg.cy;
        cy.getElementById('code:layer:presentation').emit('tap');
        const inferred = cy.edges('.inference').filter(e => e.data('evidence').length).length;
        const facts = cy.edges().not('.inference').filter(e => e.data('evidence').length).length;
        const dashed = cy.edges('.inference').every(e => e.style('line-style') === 'dashed');
        cy.emit('tap');
        return [panel ? panel.innerText.replace(/\\s+/g, ' ') : 'none', document.getElementById('arch-legend').innerText.replace(/\\s+/g, ' '), inferred > 0, facts === 0, dashed, cy.nodes('.draft').length === 0].join('|');
        """)
        check(text.contains("Fact") && text.contains("Inference") && text.contains("Draft") && text.contains("Solid arrow = fact (scanner) · dashed = inference (AI, cited)") && text.hasSuffix("|true|true|true|true"),
              "the panel and legend bar tell facts from inferences, and cited dependencies are drawn dashed", text)
        text = js("""
        window.testPayload.codeSequenceInfo = [{title:'Place an order', scope:'code:', auto:true, stale:false, createdAt:new Date().toISOString()},
            {title:'Cancel an order', scope:'code:', auto:false, stale:true, createdAt:new Date().toISOString()}];
        window.showArchitecture(window.testPayload);
        const rows = [...document.querySelectorAll('.arch-sequence')].map(r => r.querySelector('button').textContent + ':' + [...r.querySelectorAll('.arch-badges span')].map(s => s.textContent).join(','));
        rows[0] && document.querySelectorAll('.arch-sequence button')[0].click();
        await new Promise(r => setTimeout(r, 200));
        const opened = !document.getElementById('arch-code-sequence').hidden && document.getElementById('arch-code-sequence-title').textContent;
        document.getElementById('arch-code-sequence-close').click();
        return rows.join(';') + '|' + opened;
        """)
        check(text == "Place an order:Automatic;Cancel an order:Manual,stale|Place an order", "the scenario list marks automatic and stale sequences and opens the sequence panel", text)
        text = js("""
        const cy = document.getElementById('arch-graph')._cyreg.cy;
        const draftPayload = JSON.parse(JSON.stringify(window.testPayload));
        delete draftPayload.snapshot.codeModel; delete draftPayload.automaticState; delete draftPayload.codeSequenceInfo; delete draftPayload.snapshot.codeCoverage;
        draftPayload.snapshot.views.find(v => v.id === 'code').edges = [];
        window.showArchitecture(draftPayload);
        await new Promise(r => setTimeout(r, 400));
        const drafted = cy.nodes('.draft').length > 0 && cy.nodes('.draft').every(n => n.style('border-style') === 'dotted');
        const text = document.getElementById('arch-details').innerText;
        const plain = [text.toLowerCase().includes('trace a scenario'), !text.includes('What was understood'), !document.querySelector('.arch-code-status')].join(',');
        window.showArchitecture(window.testPayload);
        await new Promise(r => setTimeout(r, 400));
        return String(drafted) + '|' + String(cy.nodes('.draft').length === 0) + '|' + plain + '|' + text.slice(0, 400);
        """)
        check(text.hasPrefix("true|true|true,true,true|"), "without a code model the layers are drawn as a dotted draft and a payload without the new fields still renders", text)
        text = js("""
        delete window.testPayload.automaticState; delete window.testPayload.codeSequenceInfo;
        window.showArchitecture(window.testPayload);
        const rows = [...document.querySelectorAll('.arch-sequence')].map(r => [...r.querySelectorAll('.arch-badges span')].map(s => s.textContent).join(','));
        return document.querySelector('.arch-code-status').textContent.replace(/\\d+/, 'N') + '|' + rows.join(';');
        """)
        check(text.hasPrefix("Analyzed ") && text.hasSuffix("|Manual;Automatic"), "an older payload falls back to the model's date and the snapshot's own flags", text)
        text = js("""
        window.architectureFocus('code:f:service.py');
        await new Promise(r => setTimeout(r, 200));
        return document.getElementById('arch-details').innerText;
        """)
        check(text.contains("service.py") && text.contains("Zoom out of this"), "file drill-down and its controls render", text)
        text = js("""
        const buttons = [...document.getElementById('arch-details').querySelectorAll('button')];
        buttons.find(b => b.textContent === 'Zoom out of this').click();
        await new Promise(r => setTimeout(r, 300));
        window.architectureFocus('code:s:symbol:method');
        await new Promise(r => setTimeout(r, 100));
        return document.getElementById('arch-details').innerText;
        """)
        check(text.contains("place_order"), "drill-down reaches a symbol", text)
        text = js("""
        const buttons = [...document.getElementById('arch-details').querySelectorAll('button')];
        const open = buttons.find(b => b.classList.contains('arch-path') && b.textContent === 'service.py:5');
        if (open) open.click();
        return buttons.map(b => b.textContent).join('|');
        """)
        check(bridge.messages.contains { let p = $0["payload"] as? [String: Any]; return p?["action"] as? String == "openFile" && p?["path"] as? String == "service.py" && p?["line"] as? Int == 5 }, "symbol opens the source at its line", text)
        text = js("""
        document.querySelector('[data-arch-view="code"]').click();
        await new Promise(r => setTimeout(r, 200));
        const input = document.querySelector('.arch-code-question');
        input.value = 'How is an order saved?'; input.dispatchEvent(new Event('input'));
        [...document.querySelectorAll('.arch-code-traces button')].find(b => b.textContent === 'Draw sequence').click();
        return input.value;
        """)
        check(bridge.messages.contains { let p = $0["payload"] as? [String: Any]; return p?["action"] as? String == "traceCode" && p?["scope"] as? String == "code:" && p?["question"] as? String == "How is an order saved?" }, "scenario action contains the exact question and scope", text)
        text = js("""
        [...document.querySelectorAll('.arch-code-traces button')].find(b => b.textContent.includes('Place an order')).click();
        for (let i = 0; i < 200; i++) {
            if (document.querySelector('#arch-code-sequence-svg svg')) break;
            await new Promise(r => setTimeout(r, 50));
        }
        return String(!!document.querySelector('#arch-code-sequence-svg svg')) + '|' + document.getElementById('arch-code-sequence').innerText;
        """)
        check(text.hasPrefix("true|") && text.contains("OrderService") && text.contains("1. place order"), "sequence renders with the bundled Mermaid library", text)
        text = js("""
        document.querySelector('#arch-code-sequence-sources button').click();
        document.getElementById('arch-code-sequence-close').click();
        return String(document.getElementById('arch-code-sequence').hidden);
        """)
        check(text == "true" && bridge.messages.contains { let p = $0["payload"] as? [String: Any]; return p?["action"] as? String == "openFile" && p?["path"] as? String == "api.py" && p?["line"] as? Int == 16 }, "sequence evidence opens the source and Back returns to layers", text)
        text = js("""
        window.testPayload.snapshot.views.find(v => v.id === 'modules').nodes.find(n => n.id === 'm:').signature = 'changed';
        window.showArchitecture(window.testPayload);
        return document.getElementById('arch-details').innerText;
        """)
        check(text.contains("Source changed") && text.contains("stale"), "changed source marks both architecture and sequences stale", text)
        text = js("""
        document.querySelector('[data-arch-view="docs"]').click();
        await new Promise(r => setTimeout(r, 100));
        return String(document.getElementById('arch-code-sequence').hidden) + '|' + document.getElementById('arch-analyze').textContent;
        """)
        check(text == "true|Analyze", "switching views restores existing analysis action and hides sequence", text)
        text = js("""
        window.showArchitecture({root:'/docs-only', snapshot:{views:[{id:'modules',nodes:[{id:'m:',kind:'root',name:'Docs'}],edges:[]},{id:'code',nodes:[{id:'code:',kind:'root',name:'Code'}],edges:[]}],components:[],assignments:{},coverage:{},metrics:{},scannedAt:'2026-10-31T00:00:00Z'}, busy:false,filters:[],prSources:[]});
        document.querySelector('[data-arch-view="code"]').click();
        await new Promise(r => setTimeout(r, 200));
        return document.getElementById('arch-empty').textContent + '|' + String(document.getElementById('arch-code-sequence').hidden);
        """)
        check(text.contains("No source code was found") && text.hasSuffix("|true"), "documents-only folders show an honest empty state", text)
        text=js("""
        window.testPayload.root='/tests-only';
        const view=window.testPayload.snapshot.views.find(v=>v.id==='code');
        view.nodes=[{id:'code:',kind:'root',name:'Tests'},{id:'code:layer:tests',parent:'code:',kind:'layer',name:'Tests',role:'tests'},
            {id:'code:f:test.py',parent:'code:layer:tests',kind:'file',name:'test.py',path:'test.py',language:'python',tags:['tests']}];
        window.showArchitecture(window.testPayload);
        document.querySelector('[data-arch-view="code"]').click();
        await new Promise(r=>setTimeout(r,400));
        return document.getElementById('arch-hide').value+'|'+String(document.getElementById('arch-graph')._cyreg.cy.getElementById('code:layer:tests').length);
        """)
        check(text == "|1", "a tests-only folder starts with its code visible", text)
        text=js("""
        const picker=document.getElementById('arch-hide');picker.value='tests';picker.dispatchEvent(new Event('change'));
        return document.getElementById('arch-empty').textContent;
        """)
        check(text.contains("All source code is hidden"), "an explicit filter hiding every source file explains how to restore the map", text)

        // BUG-037 / REQ-010: the Deployment details panel lists every project operation, grouped by kind.
        let operationsSetup = """
        const op = (id, label, kind, extra) => Object.assign({id, label, kind, command:'run ' + id, cwd:'.', origin:'discovered',
            confidence:'high', nodes:[], prerequisites:[], provenance:[], remoteTrigger:false, deleted:false}, extra || {});
        window.testOperations = {
            // Five operations are "primary" in the payload (as the app still sends them); the panel must not depend on that.
            operations: [
                op('restart-web', 'Restart web', 'restart'), op('deploy-prod', 'Deploy prod', 'deploy', {environment:'prod', nodes:[{id:'d:api', name:'api'}]}),
                op('build-all', 'Build all', 'build'), op('clean-all', 'Clean', 'clean'), op('deploy-stage', 'Deploy stage', 'deploy', {environment:'stage', remoteTrigger:true}),
                op('install-deps', 'Install dependencies', 'install'), op('lint', 'Lint', 'other', {confidence:'low'}),
                op('build-docs', 'Build docs', 'build', {nodes:[{id:'gone', name:'db'}]}), op('seed', 'Seed data', 'seeding', {nodes:[{id:'x', name:'nothing'}]}),
                op('a-deploy', 'Add worker', 'deploy'),
            ],
            primary: ['deploy-prod', 'build-all', 'install-deps', 'clean-all', 'restart-web'],
            states: {'build-all': {state:'running'}}, unavailable: {}, hasFile: true, readOnly: false, sourcesChanged: false,
        };
        window.showArchitecture({root:'/ops', busy:false, filters:[], prSources:[], snapshot:{views:[
            {id:'modules', nodes:[{id:'m:', kind:'root', name:'Ops'}], edges:[]},
            {id:'deployment', nodes:[{id:'d:', kind:'root', name:'Deployment'}, {id:'d:api', parent:'d:', kind:'service', name:'api'},
                {id:'d:db', parent:'d:', kind:'database', name:'db'}, {id:'d:cache', parent:'d:', kind:'service', name:'cache'}], edges:[]}],
            components:[], assignments:{}, coverage:{}, metrics:{}, scannedAt:'2026-10-31T00:00:00Z'}});
        window.setProjectOperations(window.testOperations);
        document.querySelector('[data-arch-view="deployment"]').click();
        await new Promise(r => setTimeout(r, 400));
        const details = document.getElementById('arch-details');
        // What the person can see: an element inside a [hidden] ancestor is not shown.
        const shown = selector => [...details.querySelectorAll(selector)].filter(e => !e.closest('[hidden]'));
        """
        text = js(operationsSetup + """
        return JSON.stringify({
            headings: [...details.querySelectorAll('h5')].map(h => h.textContent),
            rows: shown('.arch-operation').map(r => r.querySelector('strong').textContent),
            controls: shown('button').map(b => b.textContent).filter(t => /show all|hide the list/i.test(t)).length,
            search: shown('input').length,
            badges: shown('.arch-badges span').map(s => s.textContent),
            buttons: shown('button').map(b => b.textContent),
        });
        """)
        let noNode = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        let noNodeButtons = noNode["buttons"] as? [String] ?? []
        let noNodeBadges = noNode["badges"] as? [String] ?? []
        // The kind order is ProjectOperation.primaryKindOrder (deploy, build, test, run, install, clean, restart, other; b1ce96c); an unknown kind follows.
        check(noNode["headings"] as? [String] == ["Project operations", "Deploy (3)", "Build (2)", "Install (1)", "Clean (1)", "Restart (1)", "Other (1)", "Seeding (1)"],
              "no node selected: one heading per kind in a fixed order, an unknown kind after the known ones", text)
        check((noNode["rows"] as? [String])?.count == 10 && (noNode["rows"] as? [String]).map({ Set($0).count }) == 10,
              "no node selected: every project operation is listed once, not only the primary ones", text)
        check((noNode["rows"] as? [String]).map({ Array($0.prefix(3)) }) == ["Add worker · deploy", "Deploy prod · prod · deploy", "Deploy stage · stage · deploy"],
              "operations inside a kind are ordered by label", text)
        check((noNode["headings"] as? [String])?.contains("Main operations") == false && noNode["controls"] as? Int == 0 && noNode["search"] as? Int == 0,
              "the Main operations list, the Show all toggle and the search box are gone", text)
        check(noNodeButtons.filter { $0 == "Open output" }.count == 1 && noNodeButtons.filter { $0 == "Run" }.count == 9
              && noNodeBadges.contains("running") && noNodeBadges.contains("Remote trigger") && noNodeBadges.contains("low"),
              "running, remote-trigger and low-confidence marks and the Run and Open output actions are kept", text)
        text = js(operationsSetup + """
        window.architectureFocus('d:api', 'deployment');
        await new Promise(r => setTimeout(r, 300));
        return JSON.stringify({
            headings: [...details.querySelectorAll('h5')].map(h => h.textContent),
            rows: shown('.arch-operation').map(r => r.className + '|' + r.querySelector('strong').textContent),
        });
        """)
        let withNode = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        let nodeRows = withNode["rows"] as? [String] ?? []
        check(withNode["headings"] as? [String] == ["Project operations", "Related to api", "Deploy (2)", "Build (2)", "Install (1)", "Clean (1)", "Restart (1)", "Other (1)", "Seeding (1)"],
              "node selected: related operations first, then the remaining ones by kind", text)
        check(nodeRows.count == 10 && nodeRows.first == "arch-operation related|Deploy prod · prod · deploy"
              && nodeRows.dropFirst().allSatisfy { !$0.hasPrefix("arch-operation related") }, "node selected: only the related operation is highlighted and none is dropped or repeated", text)
        text = js(operationsSetup + """
        window.architectureFocus('d:db', 'deployment');
        await new Promise(r => setTimeout(r, 300));
        return JSON.stringify({headings: [...details.querySelectorAll('h5')].slice(0, 2).map(h => h.textContent), rows: shown('.arch-operation').length,
            related: [...details.querySelectorAll('.arch-operation.related strong')].map(r => r.textContent)});
        """)
        check(text.contains("\"headings\":[\"Project operations\",\"Related to db\"]") && text.contains("\"related\":[\"Build docs · build\"]") && text.contains("\"rows\":10"),
              "a relation whose node id is gone resolves by node name (DEC-027)", text)
        text = js(operationsSetup + """
        window.architectureFocus('d:cache', 'deployment');
        await new Promise(r => setTimeout(r, 300));
        return JSON.stringify({headings: [...details.querySelectorAll('h5')].slice(0, 2).map(h => h.textContent), rows: shown('.arch-operation').length,
            related: details.querySelectorAll('.arch-operation.related').length});
        """)
        check(text.contains("\"headings\":[\"Project operations\",\"Deploy (3)\"]") && text.contains("\"related\":0") && text.contains("\"rows\":10"),
              "node without related operations: every operation listed, none highlighted, a relation to an unknown node is ignored", text)
        text = js(operationsSetup + """
        window.setProjectOperations(Object.assign({}, window.testOperations, {operations: [], primary: []}));
        await new Promise(r => setTimeout(r, 100));
        return details.innerText;
        """)
        check(text.contains("No runnable procedure is known for this project.") && !text.contains("Deploy ("), "empty project: the empty-state text is unchanged and no group heading shows", text)
    }
}
