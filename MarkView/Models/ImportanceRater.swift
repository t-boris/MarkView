import Foundation

/// AI filters for the Architecture tab: rate parts of a system or a document
/// against a criterion. Importance is the built-in filter; users add their own
/// ("How involved is this in payments?"). One call rates the children of one
/// container (component, folder or document), so ratings arrive as the user zooms in.
enum ImportanceRater {
    /// A rating criterion. `levels` go from strongest to weakest.
    struct Filter: Codable, Hashable {
        var id: String
        var name: String
        var criterion: String
        var levels: [String]
    }

    static let importance = Filter(id: "importance", name: "Importance", criterion: "",
                                   levels: ["critical", "high", "normal", "low"])

    // MARK: User filters

    private static let storageKey = "ai.customFilters"

    /// The user's own filters ("payment flow", …), shared by the Architecture tab and the
    /// code viewer across projects. Ratings stay per project.
    static var customFilters: [Filter] {
        get {
            (UserDefaults.standard.data(forKey: storageKey)).flatMap { try? JSONDecoder().decode([Filter].self, from: $0) } ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: storageKey)
        }
    }

    /// Importance first, then the user's filters, then the one-off filter if any.
    static var allFilters: [Filter] { [importance] + customFilters + (temporaryFilter.map { [$0] } ?? []) }

    // MARK: One-off filter

    /// Typed into a filter box and applied at once, like the saved ones — but never added
    /// to the list, and its ratings are not written to the database or the notes cache.
    /// Gone when replaced, cleared or the app quits.
    private(set) static var temporaryFilter: Filter?
    static let temporaryPrefix = "tmp-"

    static func isTemporary(_ id: String) -> Bool { id.hasPrefix(temporaryPrefix) }

    /// Replace the one-off filter (an empty criterion clears it); returns the previous one.
    @discardableResult
    static func setTemporaryFilter(_ criterion: String) -> Filter? {
        let previous = temporaryFilter
        let text = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            temporaryFilter = nil
        } else {
            let hash = abs(text.lowercased().unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }) % 1_000_000
            let label = text.count > 32 ? String(text.prefix(30)) + "…" : text
            temporaryFilter = Filter(id: temporaryPrefix + String(hash), name: "⚡ " + label, criterion: text, levels: relevanceLevels)
        }
        return previous
    }

    /// Add a filter from a topic or question; the name defaults to the criterion.
    @discardableResult
    static func addFilter(name: String, criterion: String) -> Filter? {
        let criterion = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !criterion.isEmpty else { return nil }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? criterion : name
        var filter = customFilter(name: label, criterion: criterion)
        var filters = customFilters
        while filters.contains(where: { $0.id == filter.id }) || filter.id == importance.id { filter.id += "-2" }
        filters.append(filter)
        customFilters = filters
        return filter
    }

    static func removeFilter(id: String) {
        customFilters = customFilters.filter { $0.id != id }
    }
    static let relevanceLevels = ["strong", "moderate", "weak", "none"]

    /// A user filter for `criterion`, with an id derived from its name.
    static func customFilter(name: String, criterion: String) -> Filter {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let id = "f-" + String(slug).split(separator: "-").joined(separator: "-").prefix(32)
        return Filter(id: String(id), name: name, criterion: criterion, levels: relevanceLevels)
    }

    enum Subject {
        /// Components, folders and files of a codebase.
        case code
        /// Documents and their sections.
        case documentation
    }

    struct Item {
        /// Stable key the rating is stored under (e.g. "p:src/auth.ts", "c:routing", "d:docs/x.md#L12").
        let key: String
        /// What the model sees as the item's name.
        let label: String
        /// Summary, metrics or the text itself.
        let detail: String
    }

    struct Rating: Codable, Equatable {
        var level: String
        var reason: String
        /// Content signature at rating time; a different signature means re-rate.
        var signature: String?
        /// From the keyword search only, not yet confirmed by the AI.
        var provisional: Bool?
    }

    static func schema(_ filter: Filter) -> [String: Any] { [
        "type": "object",
        "properties": [
            "ratings": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "key": ["type": "string"],
                        "level": ["type": "string", "enum": filter.levels],
                        "reason": ["type": "string", "description": "At most 10 words: why this level."],
                    ],
                    "required": ["key", "level", "reason"],
                ],
            ],
        ],
        "required": ["ratings"],
    ] }

    static func systemPrompt(for subject: Subject, filter: Filter = importance) -> String {
        guard filter.id == importance.id else {
            let what = subject == .code ? "part of a software system" : "part of the documentation"
            return """
            You rate how strongly each listed \(what) relates to this criterion. The criterion may be a \
            topic in a few words (e.g. "payment flow", "auth tokens") or a full question; treat a topic as \
            "how much does this part take part in <topic>".

            Criterion: \(filter.criterion)

            strong: the part is central to it — it implements, owns or defines it. \
            moderate: the part takes a real share in it. \
            weak: the part touches it only indirectly. \
            none: unrelated. \
            Judge by what the part actually does, not by names alone. \
            Work only from what is listed. Rate every key exactly once; keep reasons short.
            """
        }
        switch subject {
        case .code:
            return """
            You rate how important each listed part of a software system is to what the system does. \
            critical: the core the product cannot work without, or code guarding money, data integrity, \
            security or safety; a defect here is an outage or a serious incident. \
            high: important business logic or a widely used foundation. \
            normal: ordinary supporting code. \
            low: tests, samples, scripts, tooling, generated or dead code, cosmetics. \
            Judge by responsibility and consequences, not by size. Use the whole scale; most parts are normal. \
            Work only from what is listed. Rate every key exactly once; keep reasons short.
            """
        case .documentation:
            return """
            You rate how important each listed part of documentation is for the people who build and run the \
            system. critical: requirements, constraints, security or data rules, decisions and procedures whose \
            misreading causes real harm. high: key design, interfaces, how-tos people rely on. normal: useful \
            background and explanation. low: history, changelogs, acknowledgements, boilerplate, placeholders. \
            Judge by the consequence of a reader missing or misunderstanding the part, not by its length. Use \
            the whole scale. Rate every key exactly once.
            """
        }
    }

    static func prompt(context: String, items: [Item]) -> String {
        var text = context.isEmpty ? "" : context + "\n\n"
        text += "Items to rate:\n"
        for item in items {
            text += "\n### key: \(item.key)\nname: \(item.label)\n\(item.detail)\n"
        }
        return text
    }

    /// A rating call: one pass over the given items — no file access, the fast model at
    /// low effort, short reasons — so an answer takes seconds, not minutes.
    static func request(subject: Subject, filter: Filter = importance, context: String, items: [Item],
                        language: String? = nil) -> CLICompletion.Request {
        let languageLine = language.map { "\n\nWrite the reasons in \($0). Keep the level values exactly as specified." } ?? ""
        var request = CLICompletion.Request(prompt: prompt(context: context, items: items),
                                            systemPrompt: systemPrompt(for: subject, filter: filter) + languageLine,
                                            jsonSchema: schema(filter))
        request.model = AIAssistantPreferences.xrayModel(for: request.tool)
        request.effort = "low"
        request.timeout = 240
        return request
    }

    /// Ratings for the requested keys; unknown keys and levels are dropped.
    static func parse(_ structured: Any?, keys: Set<String>, filter: Filter = importance) -> [String: Rating] {
        let rows = (structured as? [String: Any])?["ratings"] as? [[String: Any]] ?? []
        var result: [String: Rating] = [:]
        for row in rows {
            guard let key = row["key"] as? String, keys.contains(key),
                  let level = row["level"] as? String, filter.levels.contains(level) else { continue }
            result[key] = Rating(level: level, reason: row["reason"] as? String ?? "")
        }
        return result
    }

    /// Text of a markdown section: from `line` (1-based, the heading) to the next
    /// heading of level 1–2, clipped to `limit` characters.
    static func sectionText(_ document: String, fromLine line: Int, limit: Int = 1800) -> String {
        let lines = document.editorLines
        guard line >= 1, line <= lines.count else { return "" }
        var out: [Substring] = [lines[line - 1]]
        var inFence = false
        for next in lines[line...] {
            let trimmed = next.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") { break }
            out.append(next)
        }
        let text = out.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) + " …" : text
    }
}
