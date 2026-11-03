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
    enum Failure: Error { case invalidOutput(CLITool, String), timedOut(CLITool, TimeInterval) }
    actor Audit {
        var labels: Set<String> = []
        /// The last prompt and system prompt sent under each label.
        var prompts: [String: String] = [:]
        var systems: [String: String] = [:]
        func record(_ label: String, prompt: String, system: String) {
            labels.insert(label)
            prompts[label] = prompt
            systems[label] = system
        }
        func reset() { labels = []; prompts = [:]; systems = [:] }
    }
    static let audit = Audit()
    /// The code-mode plan: every screen names its evidence, and the gaps list what the fixture app does
    /// that a standalone prototype cannot (REQ-001).
    static let codeGaps = ["Saving an order posts to /api/orders (src/app.js); the prototype confirms locally.",
                           "The Export button calls window.electron.saveFile (src/app.js); the prototype shows a toast instead."]
    static func run(_ request: Request, onDelta: (@Sendable (String) -> Void)? = nil,
                    onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        // The provider boundary must receive no deadline for every stage, including follow-ups.
        if let limit = request.timeout { throw Failure.timedOut(.claude, limit) }
        try Task.checkCancellation()
        await audit.record(request.label, prompt: request.prompt, system: request.systemPrompt ?? "")
        let object: [String: Any]
        switch request.label {
        case "prototype:plan" where (request.systemPrompt ?? "").contains("reconstructs an EXISTING web interface"):
            object = ["title": "Fixture Orders", "summary": "The orders screen of the fixture app", "assumptions": ["Prices are in EUR"],
                      "gaps": codeGaps, "roles": [], "entities": [],
                      "screens": [["id": "orders", "name": "Orders", "route": "/orders", "purpose": "The order list of src/index.html",
                                   "data": [], "actions": [], "states": [], "rules": [], "requirements": ["Reproduces src/index.html"],
                                   "evidence": ["src/index.html", "src/app.js", "src/styles.css"]]]]
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
            object = ["summary": "Orders", "files": [["path": "screens/orders.js", "content": "App.register({id: 'orders', render() { return 'Orders'; }});" ]]]
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
