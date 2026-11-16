import Foundation

/// The one-time review of an environment that was prepared before it could say how the application's transport wraps its answers and
/// which lists the application changes with other requests (DEC-015). The assistant reads the project once and answers in the preparation
/// schema plus three things: which rules its new ones replace, which writes push which change event, and notes. This file is the pure
/// part: the prompt, the schema, reading the answer and applying it atomically to a simulator. The session runs it (UIStudioSession+Review).
enum StudioReview {
    /// A write of an entity that pushes a message to a channel's connections: the event the page listens to for changes, so that it
    /// loads the list again.
    struct Link: Equatable {
        var channel: String
        var entity: String
        var message: StudioJSON
    }

    struct Outcome {
        var proposal: StudioProposal
        /// Ids of the registered rules the proposal's rules take the place of (fixed answers that stood in for state).
        var replaces: [String]
        var links: [Link]
        var notes: String
    }

    // MARK: Prompt and schema

    static let task = """

        This is a review of an environment that was prepared rule by rule. Two things are often wrong in it; you correct both, once.

        1. The envelope. Find how the application reads the answers of its requests: the function that unwraps a result (`unwrap`, \
        `invoke`, a fetch helper, the handler behind a preload bridge). When every answer of a service has the same wrapper, return it in \
        `envelopes` as described above (`prefix`, `resultKey`, `successFields`, `failure`). When the answers are not wrapped, return an \
        empty list: that is a real answer and is kept. The body of a `respond` rule already holds its wrapper and stays as it is.
        2. State the application changes. Find the fixed (`respond`) rules whose data the application changes with other requests: a list \
        that an answer, dismissal, confirmation, stop, save or delete shrinks or changes (pending questions, notifications, tasks, \
        drafts, lists of accounts). For each such group return the entity (and records taken from the old fixed body, with the ids the \
        writes use), the new rules (the list over the entity; each write as `delete` or `update` with `idParam` naming the body field \
        that holds the id), and the ids of the old rules they replace in `replaces`. In `links` give, for each entity whose writes \
        change what the page lists, the event the application's listener waits for to load the list again: `channel` is the id of one \
        of the channels listed below (the application's event channel), `entity`, and `message` the JSON text of the event as the \
        application's code expects it (read it where the page subscribes, for example `{"type": "changed", "scope": "accounts"}`).
        Leave alone what is truly static (an application's version, a list of installed engines). Do not repeat the records of an \
        entity that already exists. Return empty lists when there is nothing to correct. `notes` is one short sentence on what you found.
        """

    static var system: String { StudioPrompts.preparationSystem + "\n" + task }

    /// The preparation schema with what a review also answers. All three are required so that "nothing to correct" is an explicit answer.
    static var schema: [String: Any] {
        var schema = StudioPrompts.preparationSchema
        var properties = schema["properties"] as? [String: Any] ?? [:]
        properties["replaces"] = ["type": "array", "items": ["type": "string"], "description": "Ids of registered rules the new rules replace"]
        properties["links"] = ["type": "array", "items": ["type": "object", "properties": [
            "channel": ["type": "string"], "entity": ["type": "string"],
            "message": ["type": "string", "description": "JSON text of the event the page listens to"]],
            "required": ["channel", "entity", "message"]]]
        properties["notes"] = ["type": "string"]
        schema["properties"] = properties
        schema["required"] = ((schema["required"] as? [String]) ?? []) + ["envelopes", "replaces", "links", "notes"]
        return schema
    }

    /// What the assistant is shown: the registered rules (a fixed answer with the start of its body), the entities and the channels.
    static func prompt(spec: StudioEnvironmentSpec, appFolder: String) -> String {
        let rules = spec.rules.map { rule -> String in
            var line = "- \(rule.id): \(rule.method) \(rule.path) → \(rule.operation.rawValue)"
            if let entity = rule.entity { line += " \(entity)" }
            if let envelope = rule.envelope { line += " [envelope: \(envelope.prefix(60))]" }
            if rule.operation == .respond, let body = rule.response?.body?.text { line += " [fixed: \(body.prefix(140))]" }
            return line
        }
        let channels = (spec.channels ?? []).map { "- \($0.id): \($0.path) (\($0.wire.rawValue))" }
        return ["Application folder (relative to the project): \(appFolder.isEmpty ? "." : appFolder)",
                "Registered rules:\n" + rules.joined(separator: "\n"),
                "Entities: " + (spec.entities.map(\.name).joined(separator: ", ").nonEmptyOr("(none)")),
                "Channels:\n" + (channels.isEmpty ? "(none)" : channels.joined(separator: "\n")),
                "Review this environment against the application's code."].joined(separator: "\n\n")
    }

    // MARK: The answer

    static func outcome(from structured: Any?) -> Outcome? {
        guard let object = structured as? [String: Any], var proposal = StudioPrompts.proposal(from: structured) else { return nil }
        // "Looked at" is the point of the review: a missing answer is "none", never "not looked at".
        if proposal.envelopes == nil { proposal.envelopes = [] }
        let links = (object["links"] as? [[String: Any]] ?? []).compactMap { item -> Link? in
            guard let channel = item["channel"] as? String, let entity = item["entity"] as? String, !entity.isEmpty,
                  let message = (item["message"] as? String).flatMap({ StudioJSON(text: $0) }) else { return nil }
            return Link(channel: channel, entity: entity, message: message)
        }
        return Outcome(proposal: proposal, replaces: object["replaces"] as? [String] ?? [], links: links, notes: object["notes"] as? String ?? "")
    }

    // MARK: Applying it

    /// Applies the review to `simulator` as one step: the replaced rules go, a template in a rule's `envelope` is cleaned, the proposal is
    /// validated and registered, and the links are added to the channels. The simulator is unchanged when anything is refused.
    static func apply(_ outcome: Outcome, to simulator: inout StudioSimulator) -> [String] {
        var trial = simulator
        var next = trial.spec
        next.rules.removeAll { outcome.replaces.contains($0.id) }
        for index in next.rules.indices {
            if let envelope = next.rules[index].envelope, !StudioValidator.isPlainKey(envelope) { next.rules[index].envelope = nil }
        }
        trial.replaceSpec(next)
        let problems = trial.register(outcome.proposal)
        guard problems.isEmpty else { return problems }

        var spec = trial.spec
        var channelProblems: [String] = []
        for link in outcome.links {
            guard spec.entity(link.entity) != nil else { channelProblems.append("Link: entity \(link.entity) is not defined."); continue }
            let channels = spec.channels ?? []
            let raw = channels.indices.filter { channels[$0].wire == .raw }
            guard let index = channels.firstIndex(where: { $0.id == link.channel }) ?? (raw.count == 1 ? raw[0] : nil) else {
                channelProblems.append("Link: no channel \(link.channel).")
                continue
            }
            var channel = channels[index]
            channel.links.removeAll { $0.entity == link.entity }
            channel.links.append(StudioChannelLink(entity: link.entity, on: StudioChannelWrite.allCases, message: StudioChannelMessage(data: link.message)))
            spec.channels?[index] = channel
        }
        guard channelProblems.isEmpty else { return channelProblems }
        trial.replaceSpec(spec)
        simulator = trial
        return []
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}
