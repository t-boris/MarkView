import Foundation

/// The preparation prompt's part for real-time channels and GraphQL (REQ-015): what the agent may return besides REST
/// rules, the schema fields that carry it, and how they are read back. Channels and GraphQL operations arrive as JSON text,
/// so the schema stays strict for every assistant.
enum StudioRealtimePrompts {
    static let system = """

        Real-time channels and GraphQL (REQ-015). They are simulated like REST, over the same state; return them with \
        their entities and records:
        - A contract that starts with `WS` or `SSE` is a WebSocket or EventSource connection: return it in `channels` (JSON \
          text of an array). A channel is {"id", "path" (a path, or the full ws/wss/https URL of another origin; `:name` and \
          `*` allowed), "protocol": "raw" | "socketio" | "phoenix" | "graphql-ws", "onConnect": [message], "onMessage": \
          [{"match": {"<dotted field>": value or "*"}, "reply": [message], "broadcast": [message], "entity", "operation": \
          "create" | "update" | "delete", "recordPath"}], "events": [{"afterMs", "everyMs", "count", "message"}], "links": \
          [{"entity", "on": ["create", "update", "delete"], "message", "table"}], "evidence": [evidence]}. A message is \
          {"event", "topic", "data", "delayMs"}: `data` is JSON (a string is sent as text) with placeholders `{{record}}`, \
          `{{record.<field>}}`, `{{old}}`, `{{message.<field>}}`, `{{type}}` (INSERT, UPDATE, DELETE), `{{params.<name>}}`, \
          `{{now}}`, `{{uuid}}`.
        - "socketio" is Socket.IO (path `/socket.io`): `event` is the event name, `data` its argument, `topic` the namespace; \
          a client's emit reads as {"event", "data", "args", "topic"}. "phoenix" is Phoenix channels and Supabase Realtime \
          (`<project URL>/realtime/v1/websocket`): MarkView answers joins, heartbeats, broadcast and presence itself, and a \
          link without a message pushes `postgres_changes` to the clients subscribed to that table. "graphql-ws" is GraphQL \
          over WebSocket, answered by `graphql` operations of kind subscription (and query or mutation). "raw" is plain JSON \
          or text messages, and server-sent events (`event` is the SSE event name); on a raw WebSocket a client's binary \
          message reads as {"binary": base64, "size"}, and a message with event "binary" sends its base64 `data` as bytes.
        - Links make the page live: when any request writes the linked entity (REST, GraphQL or a channel message), the \
          link's message is pushed to every connection of the channel. Use them for chats, notifications, feeds and \
          dashboards; `events` push messages on a timer.
        - A contract that starts with `GRAPHQL` names GraphQL root fields: return one operation per field in `graphql` (JSON \
          text of an array). An operation is {"id", "path" (the endpoint: `/graphql` or the full URL), "kind": "query" | \
          "mutation" | "subscription", "field", "action": "list" | "get" | "create" | "update" | "delete" | "respond", \
          "entity", "idArgument", "inputArgument", "connection" (true for a Relay connection: edges, node, pageInfo), \
          "envelope" (a list wrapped as {<envelope>: [...], total}), "typeName" (__typename of the records), "response" (JSON \
          of a respond answer, `{{args.<name>}}` placeholders), "on" (the writes a subscription pushes), "evidence"}. Records \
          answer any selection set: aliases, fragments, `__typename`, and a record's `authorId` resolves `author`. Add the \
          operations the same screens use (the list, the detail and the mutations of the entity).
        - Send `[]` as the text of `channels` or `graphql` when there are none.
        """

    /// The base system prompt with the real-time part.
    static func system(_ base: String) -> String { base + system }

    /// The base prompt with the channels and operations already registered, and what to return for a channel or GraphQL contract.
    static func prompt(_ base: String, context: StudioPreparationContext, spec: StudioEnvironmentSpec) -> String {
        var lines = [base]
        let channels = (spec.channels ?? []).map { "- \($0.id): \($0.wire.rawValue) \($0.path)" }
        if !channels.isEmpty { lines.append("Channels already registered (do not repeat them):\n" + channels.joined(separator: "\n")) }
        let operations = (spec.graphQL ?? []).map { "- \($0.id): \($0.kind.rawValue) \($0.field) at \($0.path) → \($0.action.rawValue) \($0.entity ?? "")" }
        if !operations.isEmpty { lines.append("GraphQL operations already registered (do not repeat them):\n" + operations.joined(separator: "\n")) }
        if context.contract.hasPrefix("WS ") || context.contract.hasPrefix("SSE ") {
            lines.append("This is a real-time connection, not a REST request: return a channel for it in `channels` (`rules` may be empty), "
                         + "with the entities and records its messages use.")
        } else if context.contract.hasPrefix("GRAPHQL ") {
            lines.append("This is a GraphQL request: return an operation in `graphql` for each field the contract names (`rules` may be "
                         + "empty), with the entities and records they answer from. The document is in the request body.")
        }
        return lines.joined(separator: "\n\n")
    }

    /// The base schema with `channels` and `graphql`, both required (JSON text).
    static func schema(_ base: [String: Any]) -> [String: Any] {
        var schema = base
        var properties = schema["properties"] as? [String: Any] ?? [:]
        properties["channels"] = ["type": "string", "description": "JSON text of an array of channels; [] when none"]
        properties["graphql"] = ["type": "string", "description": "JSON text of an array of GraphQL operations; [] when none"]
        schema["properties"] = properties
        schema["required"] = (schema["required"] as? [String] ?? []) + ["channels", "graphql"]
        return schema
    }

    /// The base proposal with the channels and operations of the answer; damaged entries are left out (the validator names
    /// what is missing).
    static func proposal(_ base: StudioProposal?, from structured: Any?) -> StudioProposal? {
        guard var proposal = base, let object = structured as? [String: Any] else { return base }
        let decoder = JSONDecoder()
        if let text = object["channels"] as? String, let data = text.data(using: .utf8),
           let channels = try? decoder.decode([StudioLossy<StudioChannel>].self, from: data) {
            let usable = channels.compactMap(\.value).filter(\.isUsable)
            if !usable.isEmpty { proposal.channels = usable }
        }
        if let text = object["graphql"] as? String, let data = text.data(using: .utf8),
           let operations = try? decoder.decode([StudioLossy<StudioGraphQLOperation>].self, from: data) {
            let usable = operations.compactMap(\.value).filter(\.isUsable)
            if !usable.isEmpty { proposal.graphQL = usable }
        }
        return proposal
    }
}
