import Foundation

/// The app side of `DiscussionAgentTools`: reads and keeps the window's discussions through its `DiscussionStore`,
/// so the Discussions tab shows what an agent changed at once.
@MainActor
enum DiscussionToolRunner {
    private typealias Invalid = ProjectAgentTools.Invalid

    static func run(_ tool: String, _ args: [String: Any], store: DiscussionStore) -> BrowserAgentTools.Reply {
        do {
            switch tool {
            case "markview_discussions": return .init(text: list(store))
            case "markview_get_discussion": return try get(store, args)
            case "markview_create_discussion": return try create(store, args)
            case "markview_discussion_item": return try item(store, args)
            default: return .error("Unknown tool \(tool).")
            }
        } catch let invalid as Invalid {
            return .error(invalid.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func list(_ store: DiscussionStore) -> String {
        guard !store.discussions.isEmpty else { return "No discussions yet. The person starts one in the Discussions tab, or you can with markview_create_discussion." }
        return ProjectToolRunner.clip(store.discussions.map { d in
            "\(d.slug) — \(d.title) · about: \(d.scopeLabel) · \(d.turns.count) questions · \(d.items(.decision).count) decided, \(d.items(.question).count) open, \(d.items(.rejected).count) rejected"
        }.joined(separator: "\n"))
    }

    private static func named(_ store: DiscussionStore, _ args: [String: Any]) throws -> Discussion {
        let slug = try ProjectAgentTools.text(args, "discussion", required: true)
        guard let discussion = store.discussions.first(where: { $0.slug == slug }) else {
            throw Invalid(message: "No discussion \"\(slug)\". " + list(store))
        }
        return discussion
    }

    private static func get(_ store: DiscussionStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let d = try named(store, args)
        if let number = args["turn"] as? Int {
            guard let turn = d.turns.first(where: { $0.id == number }) else { throw Invalid(message: "\(d.slug) has no question \(number).") }
            return .init(text: ProjectToolRunner.clip("Q\(turn.id): \(turn.question)\n\n\(turn.answer)"))
        }
        var out = "\(d.slug) — \(d.title)\nAbout: \(d.scopeLabel)\n"
        for kind in DiscussionItem.Kind.allCases {
            out += "\n## \(kind.title)\n" + (d.items(kind).isEmpty ? "(none)\n" : d.items(kind).map { "- \($0.id): \($0.text)" }.joined(separator: "\n") + "\n")
        }
        out += "\n## Questions asked\n"
        for turn in d.turns { out += "\nQ\(turn.id): \(turn.question)\n" + String(turn.answer.prefix(600)) + (turn.answer.count > 600 ? " […] (turn: \(turn.id))" : "") + "\n" }
        return .init(text: ProjectToolRunner.clip(out))
    }

    private static func create(_ store: DiscussionStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let title = try ProjectAgentTools.text(args, "title", required: true)
        guard title.count <= 200 else { throw Invalid(message: "`title` is too long (200 characters at most).") }
        let scope = try ProjectAgentTools.text(args, "scope")
        if !scope.isEmpty {
            guard !scope.contains(".."), let root = store.root,
                  FileManager.default.fileExists(atPath: scope.hasPrefix("/") ? scope : root.appendingPathComponent(scope).path) else {
                throw Invalid(message: "`scope` must be an existing path in the project.")
            }
        }
        guard let slug = store.create(title: title, scope: scope) else { return .error(store.lastError ?? "The discussion could not be created.") }
        return .init(text: "Started discussion \(slug).")
    }

    private static func item(_ store: DiscussionStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let d = try named(store, args)
        let action = try ProjectAgentTools.choice(args, "action", in: ["add", "edit", "move", "remove"], default: "")
        let kind = DiscussionItem.Kind(rawValue: try ProjectAgentTools.choice(args, "kind", in: DiscussionItem.Kind.allCases.map(\.rawValue), default: ""))
        let text = try ProjectAgentTools.text(args, "text")
        let id = try ProjectAgentTools.text(args, "id")
        if action == "add" {
            guard let kind, !text.isEmpty else { throw Invalid(message: "add needs `kind` and `text`.") }
            store.addItem(d.slug, kind: kind, text: text)
            return .init(text: "Added to \(d.slug) as \(kind.title.lowercased()).")
        }
        guard !action.isEmpty else { throw Invalid(message: "`action` is required: add, edit, move, remove.") }
        guard d.items.contains(where: { $0.id == id }) else { throw Invalid(message: "\(d.slug) has no item \(id). Read the ids with markview_get_discussion.") }
        switch action {
        case "edit":
            guard !text.isEmpty else { throw Invalid(message: "edit needs `text`.") }
            store.edit(d.slug, item: id, text: text)
        case "move":
            guard let kind else { throw Invalid(message: "move needs `kind`.") }
            store.move(d.slug, item: id, to: kind)
        default:
            store.remove(d.slug, item: id)
        }
        return .init(text: "Done: \(action) \(id) in \(d.slug).")
    }
}
