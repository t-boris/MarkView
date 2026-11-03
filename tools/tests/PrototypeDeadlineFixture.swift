import Foundation

enum CLITool { case claude }
enum CLICompletion {
    struct Request {
        let project: URL?
        var prompt: String
        var systemPrompt: String? = nil
        var jsonSchema: [String: Any]? = nil
        var readableFolder: URL? = nil
        var extraReadableFolders: [URL] = []
        var images: [URL] = []
        var timeout: TimeInterval? = 180
        var effort: String? = nil
        var label = ""
    }
    struct Result { let text: String; let structured: Any?; let inputTokens: Int; let outputTokens: Int }
    enum Activity { case read(String), search(String), run(String), thinking, writing(Int), answerDelta(String), webSearch(String), webFetch(String) }
    enum Failure: LocalizedError {
        case invalidOutput(CLITool, String)
        case timedOut(CLITool, TimeInterval)
        var errorDescription: String? {
            switch self {
            case .invalidOutput(_, let detail): return detail
            case .timedOut(_, let limit): return "timed out after \(limit) s"
            }
        }
    }
    actor Audit {
        var labels: Set<String> = []
        /// The last prompt and system prompt sent under each label.
        var prompts: [String: String] = [:]
        var systems: [String: String] = [:]
        /// The effort asked for under each label.
        var efforts: [String: String] = [:]
        /// How many runs each label had.
        var calls: [String: Int] = [:]
        /// What the fixture app "looks like" to the assistant: "" at creation, "synced" after the code changed,
        /// "failing" when the planner cannot answer (a sync that must restore the previous version).
        var variant = ""
        func record(_ label: String, prompt: String, system: String, effort: String?) {
            labels.insert(label)
            prompts[label] = prompt
            systems[label] = system
            efforts[label] = effort
            calls[label, default: 0] += 1
        }
        func reset() { labels = []; prompts = [:]; systems = [:]; efforts = [:]; calls = [:] }
        func set(variant: String) { self.variant = variant }
    }
    static let audit = Audit()
    /// The code-mode plan: every screen names its evidence, and the gaps list what the fixture app does
    /// that a standalone prototype cannot (REQ-001).
    static let codeGaps = ["Saving an order posts to /api/orders (src/app.js); the prototype confirms locally.",
                           "The Export button calls window.electron.saveFile (src/app.js); the prototype shows a toast instead."]
    /// The orders screen of code mode: the list is marked with its template (planned), the toolbar with a file
    /// the plan did not name (found by the markup scan), as the screen writer is told to (REQ-007), and a
    /// phantom with a file that does not exist, which the build must drop as a gap rather than link.
    static func ordersScreen(variant: String) -> String {
        let title = variant == "synced" ? "Orders (synced)" : "Orders"
        return "App.register({id: 'orders', render() { return '<div data-mv-component=\"src/index.html\"><h1>\(title)</h1>"
            + "<nav data-mv-component=\"src/toolbar.html\"></nav><span data-mv-component=\"src/phantom.html\"></span></div>'; }});"
    }
    static var fragmentFiles: [String: String] {
        ["index.html": "<head><link rel=\"stylesheet\" href=\"styles.css\"></head>\n<!--SCREENS-->\n",
         "app.js": "window.App = { register() {}, start() {} };",
         "styles.css": "body { color: black; }",
         "data.js": "window.DB = { text: \"" + String(repeating: "escaped\\\"value \u{1F680} ", count: 900) + "\" };\n",
         "screens/orders.js": ordersScreen(variant: ""),
         "components/src-index-html.html": "<main data-mv-component=\"src/index.html\">Orders alone</main>"]
    }
    static func run(_ request: Request, onDelta: (@Sendable (String) -> Void)? = nil,
                    onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        // The provider boundary must receive no deadline for every stage, including follow-ups.
        if let limit = request.timeout { throw Failure.timedOut(.claude, limit) }
        try Task.checkCancellation()
        await audit.record(request.label, prompt: request.prompt, system: request.systemPrompt ?? "", effort: request.effort)
        let variant = await audit.variant
        if variant.hasPrefix("fragments") {
            if let range = request.label.range(of: ":part:") {
                let path = String(request.label[range.upperBound...].split(separator: ":")[0])
                let line = String(request.prompt.split(separator: "\n").last ?? "")
                let saved = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: String]
                let prefix = saved["content"]!
                let whole = fragmentFiles[path]!
                precondition(saved["path"] == path && whole.hasPrefix(prefix), "Every part receives the exact saved prefix.")
                precondition(request.jsonSchema?["required"] as? [String] == ["content", "done"])
                if path == "data.js", !prefix.isEmpty {
                    if variant == "fragments-fail" { throw Failure.invalidOutput(.claude, "fixture: fragment failed") }
                    if variant == "fragments-cancel" { throw CancellationError() }
                }
                let rest = String(whole.dropFirst(prefix.count))
                let content = String(rest.prefix(4_096))
                let fragment: [String: Any] = ["content": content, "done": rest.count <= 4_096]
                return Result(text: "", structured: fragment, inputTokens: 1, outputTokens: 1)
            }
            if request.label.hasPrefix("prototype:foundation:") || request.label == "prototype:screen:orders"
                || request.label == "prototype:component:src-index-html" {
                throw Failure.invalidOutput(.claude, "the answer was cut off before its JSON ended (261514 characters after 3 continuation turns)")
            }
        }
        let object: [String: Any]
        switch request.label {
        case "prototype:plan" where variant == "failing":
            throw Failure.invalidOutput(.claude, "fixture: the planner could not read the code")
        case "prototype:plan" where variant == "widgets":
            // A window of docked widgets (BUG-050): a host, a widget and a modal, the last two with a source file each.
            func entry(_ id: String, _ name: String, _ route: String, evidence: [String], components: [String],
                       embedded: Bool, hosts: [String]) -> [String: Any] {
                ["id": id, "name": name, "route": route, "purpose": name, "data": [], "actions": [], "states": [], "rules": [],
                 "requirements": [], "evidence": evidence, "components": components, "embedded": embedded, "hosts": hosts]
            }
            object = ["title": "Fixture Desk", "summary": "A window of widgets", "assumptions": [], "gaps": [], "roles": [], "entities": [],
                      "styles": ["src/styles.css"],
                      "screens": [entry("workspace", "Workspace", "/", evidence: ["src/app.js", "src/index.html"], components: [],
                                        embedded: false, hosts: ["order-list", "settings", "ghost"]),
                                  entry("order-list", "Order list", "/widgets/order-list", evidence: ["src/index.html"],
                                        components: ["src/index.html"], embedded: true, hosts: []),
                                  entry("settings", "Settings", "/modals/settings", evidence: ["src/toolbar.html"],
                                        components: ["src/toolbar.html"], embedded: true, hosts: [])]]
        case "prototype:screen:workspace" where variant == "widgets":
            object = ["summary": "Host", "files": [["path": "screens/workspace.js", "content": "App.register({id: 'workspace', route: '/', render() { return App.renderScreen('order-list'); }});"]]]
        case "prototype:screen:order-list" where variant == "widgets":
            object = ["summary": "Widget", "files": [["path": "screens/order-list.js", "content":
                "App.register({id: 'order-list', route: '/widgets/order-list', embedded: true, render() { return '<div data-mv-component=\"src/index.html\">Orders</div>'; }});"]]]
        case "prototype:screen:settings" where variant == "widgets":
            object = ["summary": "Modal", "files": [["path": "screens/settings.js", "content":
                "App.register({id: 'settings', route: '/modals/settings', embedded: true, render() { return '<div data-mv-component=\"src/toolbar.html\">Settings</div>'; }});"]]]
        case "prototype:plan" where (request.systemPrompt ?? "").contains("reconstructs an EXISTING web interface"):
            object = ["title": variant == "synced" ? "Fixture Orders (synced)" : "Fixture Orders",
                      "summary": "The orders screen of the fixture app", "assumptions": ["Prices are in EUR"],
                      "gaps": codeGaps, "roles": [], "entities": [], "styles": ["src/styles.css"],
                      "screens": [["id": "orders", "name": "Orders", "route": "/orders", "purpose": "The order list of src/index.html",
                                   "data": [], "actions": [], "states": [], "rules": [], "requirements": ["Reproduces src/index.html"],
                                   // src/ghost.vue is not in the fixture: the plan named it, the build must not link it.
                                   "evidence": ["src/index.html", "src/app.js", "src/styles.css"], "components": ["src/index.html", "src/ghost.vue"]]]]
        case "prototype:plan":
            // The schema requires `gaps` and `components` in every mode; what the planner fills in here must not surface.
            object = ["title": "Fixture", "summary": "One screen", "assumptions": [], "roles": ["Owner"], "entities": [],
                      "gaps": ["A gap that requirements mode must drop"],
                      "screens": [["id": "home", "name": "Home", "route": "/home", "purpose": "Overview",
                                   "data": [], "actions": [], "states": [], "rules": [], "requirements": [], "components": ["src/x.vue"]]]]
        case "prototype:foundation:shell":
            object = ["summary": "Shell", "files": [
                ["path": "index.html", "content": "<head><link rel=\"stylesheet\" href=\"styles.css\"></head>\n<h1>Fixture title</h1>\n<!--SCREENS-->\n"],
                ["path": "app.js", "content": "window.App = { register() {}, start() {} };"  ]]]
        case "prototype:foundation:styles":
            object = ["summary": "Styles", "files": [["path": "styles.css", "content": "body { color: black; }"]]]
        case "prototype:foundation:seed" where variant == "broken-seed":
            // BUG-056: an unescaped quote in a string, as in the strikedesk data.js run.
            object = ["summary": "Seed", "files": [["path": "seed.js", "content": "DB.seed({ \"Ticket\": [{ id: \"t-1\", title: \"Say \"hi\"\" }] });"]]]
        case "prototype:foundation:seed":
            object = ["summary": "Seed", "files": [["path": "seed.js", "content": "DB.seed({ \"Ticket\": [{ id: \"t-1\", title: \"Printer\", opened: DB.days(-2) }] });"]]]
        case "prototype:foundation:data":
            object = ["summary": "Data", "files": [["path": "data.js", "content": "window.DB = {};" ]]]
        case "prototype:screen:home" where variant == "stub-once" || variant == "stub-always":
            // BUG-053: the Settings screen of the strikedesk build was only a comment saying it is not implemented.
            let first = await audit.calls["prototype:screen:home"] == 1
            let stub = variant == "stub-always" || first
            object = ["summary": "Home", "files": [["path": "screens/home.js", "content": stub
                ? "/* The home screen is not implemented: the forms and the rules must be studied first. */"
                : "App.register({id: 'home', render() { return 'Home'; }});"]]]
        case "prototype:screen:home" where variant == "loader-once" || variant == "loader-always":
            // BUG-062: strikedesk's Trade screen cleared the element its loader sits in, so it was blank and threw nothing.
            let first = await audit.calls["prototype:screen:home"] == 1
            let broken = variant == "loader-always" || first
            object = ["summary": "Home", "files": [["path": "screens/home.js", "content": broken
                ? "App.register({id: 'home', render() { const root = h('div'); function draw() { root.replaceChildren(h('p')); } root.append(App.load(() => { draw(); return root; })); return root; }});"
                : "App.register({id: 'home', render() { return App.load(() => h('p', {}, 'Home')); }});"]]]
        case "prototype:screen:home":
            object = ["summary": "Home", "files": [["path": "screens/home.js", "content": "App.register({id: 'home', render() { return 'Home'; }});" ]]]
        case "prototype:screen:orders" where variant == "orders-stub":
            // An incremental sync whose only changed screen comes back as a stub: nothing could be rebuilt.
            object = ["summary": "Orders", "files": [["path": "screens/orders.js", "content": "// The orders screen is not implemented yet."]]]
        case "prototype:screen:orders":
            object = ["summary": "Orders", "files": [["path": "screens/orders.js", "content": ordersScreen(variant: variant)]]]
        case "prototype:component:src-index-html":
            object = ["summary": "Orders list alone", "files": [["path": "components/src-index-html.html",
                "content": "<link rel=\"stylesheet\" href=\"../styles.css\"><main id=\"component\" data-mv-component=\"src/index.html\">Orders alone</main>"]]]
        case "prototype:component:src-toolbar-html":
            // A component the assistant cannot isolate: the build records a gap and goes on (REQ-007).
            throw Failure.invalidOutput(.claude, "the toolbar has no source file to read")
        // A request for many files (BUG-051): the first run lists them; one run per file follows.
        case "prototype:revise" where variant.hasPrefix("sweep"):
            // Repeats, a path with the prototype folder, a file that does not exist and one outside the site are listed too.
            let site = "docs/prototypes/fixture/site/"
            object = ["summary": "Listed the files.", "screens": [], "files": [], "edits": [], "delete": [],
                      "remaining": ["index.html", "app.js", "app.js", "data.js", "styles.css", site + "screens/home.js",
                                    "screens/ghost.js", "../outside.js"]]
        case "prototype:revise" where variant == "explain":
            object = ["summary": "The prototype is already in English.", "screens": [], "files": [], "edits": [], "delete": [], "remaining": []]
        case "prototype:revise" where variant == "silent":
            object = ["summary": "  ", "screens": [], "files": [], "edits": [], "delete": [], "remaining": []]
        case let label where label.hasPrefix("prototype:revise:"):
            let path = String(label.dropFirst("prototype:revise:".count))
            if variant == "sweep-all-fail" { throw Failure.invalidOutput(.claude, "fixture: the run for \(path) failed") }
            if variant == "sweep-slow" { try await Task.sleep(nanoseconds: 3_000_000_000) }
            func answer(edits: [[String: String]] = [], delete: [String] = []) -> [String: Any] {
                ["summary": "Revised \(path)", "screens": [], "files": [], "edits": edits, "delete": delete, "remaining": []]
            }
            switch path {
            case "index.html":
                object = answer(edits: [["path": "index.html", "find": "Fixture title", "replace": "Titre du fixture"]])
            case "data.js":
                // The first answer does not match the file; the retry carries the reason and is right.
                let retry = request.prompt.contains("could not be applied")
                object = answer(edits: [["path": "data.js", "find": retry ? "window.DB = {}" : "window.DBB = {}", "replace": "window.DB = { ok: 1 }"]])
            case "styles.css":
                // A run owns its file: the edit of another file and the delete are not applied.
                object = answer(edits: [["path": "styles.css", "find": "black", "replace": "navy"],
                                        ["path": "index.html", "find": "Fixture title", "replace": "WRONG"]], delete: ["app.js"])
            case "screens/home.js":
                throw Failure.invalidOutput(.claude, "fixture: home cannot be revised")
            default:
                object = answer()
            }
        case "prototype:revise":
            object = ["summary": "Updated", "screens": ["Home"], "files": [], "delete": [],
                      "edits": [["path": "index.html", "find": variant == "runtime" ? "<title>Fixture</title>" : "Fixture title",
                                 "replace": variant == "runtime" ? "<title>Revised fixture</title>" : "Revised fixture"]]]
        case "prototype:spec":
            return Result(text: "# Fixture specification\n\nHome screen.", structured: nil, inputTokens: 1, outputTokens: 1)
        default: throw Failure.invalidOutput(.claude, "Unexpected fixture request")
        }
        return Result(text: "", structured: object, inputTokens: 1, outputTokens: 1)
    }
}
