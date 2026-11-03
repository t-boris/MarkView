import Foundation

enum CLITool { case claude }
enum CLICompletion {
    struct Request {
        let project: URL?
        var prompt: String
        var systemPrompt: String? = nil
        var jsonSchema: [String: Any]? = nil
        var readableFolder: URL? = nil
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
        /// What the fixture app "looks like" to the assistant: "" at creation, "synced" after the code changed,
        /// "failing" when the planner cannot answer (a sync that must restore the previous version).
        var variant = ""
        func record(_ label: String, prompt: String, system: String) {
            labels.insert(label)
            prompts[label] = prompt
            systems[label] = system
        }
        func reset() { labels = []; prompts = [:]; systems = [:] }
        func set(variant: String) { self.variant = variant }
    }
    static let audit = Audit()
    /// The code-mode plan: every screen names its evidence, and the gaps list what the fixture app does
    /// that a standalone prototype cannot (REQ-001).
    static let codeGaps = ["Saving an order posts to /api/orders (src/app.js); the prototype confirms locally.",
                           "The Export button calls window.electron.saveFile (src/app.js); the prototype shows a toast instead."]
    /// The orders screen of code mode: the list is marked with its template (planned), the toolbar with a file
    /// the plan did not name (found by the markup scan), as the screen writer is told to (REQ-007).
    static func ordersScreen(variant: String) -> String {
        let title = variant == "synced" ? "Orders (synced)" : "Orders"
        return "App.register({id: 'orders', render() { return '<div data-mv-component=\"src/index.html\"><h1>\(title)</h1>"
            + "<nav data-mv-component=\"src/toolbar.html\"></nav></div>'; }});"
    }
    static func run(_ request: Request, onDelta: (@Sendable (String) -> Void)? = nil,
                    onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        // The provider boundary must receive no deadline for every stage, including follow-ups.
        if let limit = request.timeout { throw Failure.timedOut(.claude, limit) }
        try Task.checkCancellation()
        await audit.record(request.label, prompt: request.prompt, system: request.systemPrompt ?? "")
        let variant = await audit.variant
        let object: [String: Any]
        switch request.label {
        case "prototype:plan" where variant == "failing":
            throw Failure.invalidOutput(.claude, "fixture: the planner could not read the code")
        case "prototype:plan" where (request.systemPrompt ?? "").contains("reconstructs an EXISTING web interface"):
            object = ["title": variant == "synced" ? "Fixture Orders (synced)" : "Fixture Orders",
                      "summary": "The orders screen of the fixture app", "assumptions": ["Prices are in EUR"],
                      "gaps": codeGaps, "roles": [], "entities": [],
                      "screens": [["id": "orders", "name": "Orders", "route": "/orders", "purpose": "The order list of src/index.html",
                                   "data": [], "actions": [], "states": [], "rules": [], "requirements": ["Reproduces src/index.html"],
                                   "evidence": ["src/index.html", "src/app.js", "src/styles.css"], "components": ["src/index.html"]]]]
        case "prototype:plan":
            object = ["title": "Fixture", "summary": "One screen", "assumptions": [], "roles": ["Owner"], "entities": [],
                      "screens": [["id": "home", "name": "Home", "route": "/home", "purpose": "Overview",
                                   "data": [], "actions": [], "states": [], "rules": [], "requirements": []]]]
        case "prototype:foundation:shell":
            object = ["summary": "Shell", "files": [
                ["path": "index.html", "content": "<h1>Fixture title</h1>\n<!--SCREENS-->\n"],
                ["path": "styles.css", "content": "body { color: black; }"],
                ["path": "app.js", "content": "window.App = { register() {}, start() {} };"  ]]]
        case "prototype:foundation:data":
            object = ["summary": "Data", "files": [["path": "data.js", "content": "window.DB = {};" ]]]
        case "prototype:screen:home":
            object = ["summary": "Home", "files": [["path": "screens/home.js", "content": "App.register({id: 'home', render() { return 'Home'; }});" ]]]
        case "prototype:screen:orders":
            object = ["summary": "Orders", "files": [["path": "screens/orders.js", "content": ordersScreen(variant: variant)]]]
        case "prototype:component:src-index-html":
            object = ["summary": "Orders list alone", "files": [["path": "components/src-index-html.html",
                "content": "<link rel=\"stylesheet\" href=\"../styles.css\"><main id=\"component\" data-mv-component=\"src/index.html\">Orders alone</main>"]]]
        case "prototype:component:src-toolbar-html":
            // A component the assistant cannot isolate: the build records a gap and goes on (REQ-007).
            throw Failure.invalidOutput(.claude, "the toolbar has no source file to read")
        case "prototype:revise":
            object = ["summary": "Updated", "screens": ["Home"], "files": [], "delete": [],
                      "edits": [["path": "index.html", "find": "Fixture title", "replace": "Revised fixture"]]]
        case "prototype:spec":
            return Result(text: "# Fixture specification\n\nHome screen.", structured: nil, inputTokens: 1, outputTokens: 1)
        default: throw Failure.invalidOutput(.claude, "Unexpected fixture request")
        }
        return Result(text: "", structured: object, inputTokens: 1, outputTokens: 1)
    }
}
