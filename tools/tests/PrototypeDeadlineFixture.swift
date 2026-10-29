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
        func record(_ label: String) { labels.insert(label) }
    }
    static let audit = Audit()
    static func run(_ request: Request, onDelta: (@Sendable (String) -> Void)? = nil,
                    onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        // The provider boundary must receive no deadline for every stage, including follow-ups.
        if let limit = request.timeout { throw Failure.timedOut(.claude, limit) }
        try Task.checkCancellation()
        await audit.record(request.label)
        let object: [String: Any]
        switch request.label {
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
