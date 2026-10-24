import Foundation

/// The Discussions tools of the "markview" MCP server: an assistant can read the conversations a person had about an
/// idea, with what they decided, left open and rejected, and keep those lists. It cannot ask the in-app assistant
/// anything (no agent calls an agent). Declarations only; the app side is `DiscussionToolRunner`.
enum DiscussionAgentTools {
    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:],
                             required: [String] = []) -> BrowserAgentTools.Tool {
        BrowserAgentTools.Tool(name: name, description: description, properties: properties, required: required)
    }

    private static let slug: [String: Any] = ["type": "string", "description": "The discussion's slug, from markview_discussions"]

    static let tools: [BrowserAgentTools.Tool] = [
        tool("markview_discussions", "The discussions of this project (conversations about an idea, a file, a folder or the whole project): slug, title, scope, number of questions, decided and open points."),
        tool("markview_get_discussion", "One discussion: what it is about, what was decided, what is open, what was rejected (with ids), and the questions asked with their answers. With `turn`, the full answer of that question.",
             ["discussion": slug, "turn": ["type": "integer"]], required: ["discussion"]),
        tool("markview_create_discussion", "Start a discussion. The person talks in it with MarkView's assistant; you keep its decisions and open points with markview_discussion_item.",
             ["title": ["type": "string"], "scope": ["type": "string", "description": "A path in the project the talk is about; empty for the whole project"]],
             required: ["title"]),
        tool("markview_discussion_item", "Keep a discussion's decisions, open questions and rejected options: add one, change its text, move it to another kind, or remove it.",
             ["discussion": slug, "action": ["type": "string", "enum": ["add", "edit", "move", "remove"]],
              "kind": ["type": "string", "enum": ["decision", "question", "rejected"], "description": "add, move: the kind"],
              "id": ["type": "string", "description": "edit, move, remove: the item id, from markview_get_discussion"],
              "text": ["type": "string", "description": "add, edit"]],
             required: ["discussion", "action"]),
    ]

    static let names: Set<String> = Set(tools.map(\.name))
}
