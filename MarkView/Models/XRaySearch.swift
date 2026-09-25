import Foundation

/// The X-Ray's ⚡ search filter: the AI reads the project (read-only) and returns the
/// places that really matter for the query; the X-Ray colours their files red and
/// leaves everything else uncoloured. A query can also be one code element
/// ("Explain with AI — everything related"): then the map is its definition, what it
/// calls, who calls it, its data and its tests.
enum XRaySearch {
    /// A code element the search starts from.
    struct Symbol: Hashable {
        var name: String
        var path: String
        var line: Int
    }

    /// One place the AI found: a file, a line range and what it does for the query.
    struct Place: Hashable {
        var path: String
        var start: Int
        var end: Int
        var title: String
        var why: String
        /// The group the AI put it in ("Where the photo is received", "Tests", "Called by"…).
        var step: String
    }

    /// Files where `symbol` is defined or used (definitions first), as hints for the AI.
    static func symbolHints(_ symbol: Symbol, root: URL) -> [String] {
        let found = CodeNavigator.find(symbol.name, root: root)
        var lines: [String: [Int]] = [:]
        var kinds: [String: Set<String>] = [:]
        var order: [String] = []
        for location in CodeNavigator.rank(found.definitions, from: symbol.path) + CodeNavigator.sortUsages(found.usages, from: symbol.path) {
            if lines[location.path] == nil { order.append(location.path) }
            if lines[location.path, default: []].count < 5 { lines[location.path, default: []].append(location.line) }
            kinds[location.path, default: []].insert(location.kind)
        }
        return order.prefix(30).map { path in
            "- \(path) (\(kinds[path, default: []].sorted().joined(separator: ", ")); lines \(lines[path, default: []].map(String.init).joined(separator: ", ")))"
        }
    }

    static func request(query: String, symbol: Symbol?, hints: [String], root: URL) -> CLICompletion.Request {
        let prompt: String
        if let symbol {
            prompt = """
            Topic: the code element `\(symbol.name)` at \(symbol.path):\(symbol.line) — what it is and \
            everything related to it.

            Map it like this: first the element itself (its definition) and what it does; then what it \
            depends on (the functions, types, services and data it calls or reads — follow them one or two \
            levels deep); then who uses it (callers, and their callers when that explains why it exists); \
            then the data it reads or writes, its tests, and its configuration. Name each step by that \
            relation (for example "Definition", "Calls", "Called by", "Data", "Tests"). Leave out code \
            that only shares the name without being connected.

            Files where the name occurs (definitions first; some may be unrelated elements with the \
            same name):
            \(hints.isEmpty ? "(none found)" : hints.joined(separator: "\n"))
            """
        } else {
            prompt = """
            Topic: \(query)

            Files that mention the topic's keywords (a starting point only — some are noise, and \
            relevant code may use other words):
            \(hints.isEmpty ? "(none found by keyword)" : hints.joined(separator: "\n"))
            """
        }
        let place: [String: Any] = [
            "type": "object",
            "properties": [
                "path": ["type": "string"], "start": ["type": "integer"], "end": ["type": "integer"],
                "title": ["type": "string"], "why": ["type": "string"],
            ],
            "required": ["path", "start", "end", "title", "why"],
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "steps": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["title": ["type": "string"], "places": ["type": "array", "items": place]],
                    "required": ["title", "places"],
                ]],
            ],
            "required": ["summary", "steps"],
        ]
        var request = CLICompletion.Request(
            prompt: prompt,
            systemPrompt: """
            You show an engineer exactly where a topic lives in this project, so they can see only the code \
            that is about it and nothing else. The project is the working directory: search it with Grep and \
            Glob and read files with Read. Never modify anything.

            Find every place that really takes part in the topic — follow the flow from where it starts (UI, \
            endpoint, command, job) through where the input is received and validated, processed, sent to \
            models or services, stored, and returned or shown; then the tests that cover it, and the \
            configuration, prompts, fixtures and docs that shape it. Follow calls and imports from the \
            candidate files to find parts that use other words. Leave out code that only mentions a keyword.

            Group the places into steps in the order of the flow; tests, configuration and docs get their own \
            steps at the end. If the topic asks questions (for example "how do we test it"), make sure the steps \
            answer them, and say so in the summary when something does not exist (for example no tests).

            Each place: `path` relative to the working directory, `start` and `end` as the exact 1-based line \
            range of the function, type, block or test that matters (read the file to get them right; not the \
            whole file unless it is short), a short `title`, and `why` — one sentence on what this code does \
            for the topic. Usually 5-40 places; one place per function or block, no duplicates.

            `summary`: 2-4 sentences on how the topic works end to end in this project, naming the key files; \
            if the project has nothing about the topic, say so and return no steps.
            """ + "\n\n" + ActionOutputLanguage.explanationLine(),
            jsonSchema: schema,
            readableFolder: root)
        request.timeout = 900
        return request
    }

    /// Places from the AI answer's `steps`: paths inside the project only, line ranges
    /// clamped to the file.
    static func places(from value: Any?, root: URL) -> [Place] {
        guard let steps = value as? [[String: Any]] else { return [] }
        let base = root.standardizedFileURL.path
        var lineCounts: [String: Int] = [:]
        var seen = Set<String>()
        var result: [Place] = []
        for step in steps {
            let title = (step["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            for raw in step["places"] as? [[String: Any]] ?? [] {
                guard var path = (raw["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
                      let start = (raw["start"] as? NSNumber)?.intValue else { continue }
                if path.hasPrefix(base + "/") { path = String(path.dropFirst(base.count + 1)) }
                if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
                let url = root.appendingPathComponent(path).standardizedFileURL
                guard !path.hasPrefix("/"), url.path.hasPrefix(base + "/") else { continue }
                if lineCounts[path] == nil {
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    lineCounts[path] = text.editorLines.count
                }
                let count = max(1, lineCounts[path] ?? 1)
                let first = min(max(1, start), count)
                let last = min(max(first, (raw["end"] as? NSNumber)?.intValue ?? first), count)
                guard seen.insert("\(path)#\(first)-\(last)").inserted else { continue }
                result.append(Place(path: path, start: first, end: last,
                                    title: raw["title"] as? String ?? "", why: raw["why"] as? String ?? "", step: title))
            }
        }
        return result
    }

    /// The reason shown for a file: what the places in it do for the query.
    static func reason(for places: [Place]) -> String {
        let titles = places.prefix(3).map { $0.step.isEmpty ? $0.title : "\($0.step): \($0.title)" }
        return titles.joined(separator: " · ") + (places.count > 3 ? " (+\(places.count - 3))" : "")
    }
}
