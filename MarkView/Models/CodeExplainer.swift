import Foundation

extension String {
    /// Lines as the code viewer counts them: CRLF, CR and LF each end a line. (Swift
    /// treats "\r\n" as one Character, so splitting on "\n" alone merges CRLF lines.)
    var editorLines: [Substring] {
        replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
    }
}

/// One logical section of a source file, as explained by the AI.
struct CodeSection: Codable, Hashable {
    var startLine: Int
    var endLine: Int
    var title: String
    var explanation: String
    /// critical | high | normal | low
    var importance: String
}

/// AI explanation of a file for the margin panel next to the code viewer.
struct CodeExplanation: Codable {
    var path: String
    /// SHA-256 of the content that was explained; a mismatch means the file changed.
    var contentHash: String
    var summary: String
    var sections: [CodeSection]
    /// AI filter id → "s<startLine>" → rating of that section.
    var ratings: [String: [String: ImportanceRater.Rating]] = [:]
    var assistant: String
    var createdAt: Date
    /// Output language the explanation was written in.
    var language: String?
    /// "s<startLine>" → Unix time of the newest change in that section (git blame).
    var freshness: [String: Int]?
}

/// Explanations of code files, cached as JSON under `<workspace>/.dde/cache/explain/`.
@MainActor
final class CodeExplainStore: ObservableObject {
    /// Language for rating reasons; nil keeps the model's default (document language).
    static var reasonLanguage: String? {
        ActionOutputLanguage.current == ActionOutputLanguage.documentLanguage ? nil : ActionOutputLanguage.current
    }

    @Published private(set) var explanations: [String: CodeExplanation] = [:]
    @Published private(set) var working: Set<String> = []
    /// What is running for a path, shown in the panel header ("Explaining…", "Rating: …").
    private var activity: [String: String] = [:]
    /// Answer text streamed so far per path, to show sections while they are written.
    private var liveAnswers: [String: String] = [:]
    private var liveRefreshPending: Set<String> = []

    /// Lines longer than this (minified code) are clipped in prompts.
    static let maxLineLength = 400
    @Published private(set) var errors: [String: String] = [:]
    /// Bumped on every change the code viewer must re-render.
    @Published private(set) var revision = 0

    func filtersChanged() { revision += 1 }

    /// Newest change per section from `git blame` (file date without git). No AI.
    func freshness(path: String, root: URL, directory: URL) {
        guard var explanation = explanations[path], explanation.freshness == nil else { return }
        let file = root.appendingPathComponent(path)
        let sections = explanation.sections
        Task {
            let times: [Int] = await Task.detached {
                guard let blame = ArchitectureScanner.runTool("/usr/bin/env",
                        ["git", "-C", root.path, "blame", "--line-porcelain", "--", path]) else { return [] }
                return blame.split(separator: "\n").compactMap { line in
                    line.hasPrefix("author-time ") ? Int(line.dropFirst("author-time ".count)) : nil
                }
            }.value
            let fallback = Int((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?
                .timeIntervalSince1970) ?? 0)
            var result: [String: Int] = [:]
            for section in sections {
                let slice = times.indices.contains(section.startLine - 1)
                    ? times[(section.startLine - 1)..<min(section.endLine, times.count)] : []
                result["s\(section.startLine)"] = slice.max() ?? fallback
            }
            explanation.freshness = result
            explanations[path] = explanation
            save(explanation, directory: directory)
            revision += 1
        }
    }

    func reset() {
        explanations = [:]
        working = []
        activity = [:]
        errors = [:]
        revision += 1
    }

    static let maxLines = 4000

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "summary": ["type": "string", "description": "2-3 sentences: what the file is for and how it fits the system."],
            "sections": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "startLine": ["type": "integer"],
                        "endLine": ["type": "integer"],
                        "title": ["type": "string", "description": "Short name of the section, e.g. \"Retry with backoff\"."],
                        "explanation": ["type": "string", "description": "2-4 sentences: what the code does, why, and how it connects to the rest."],
                        "importance": ["type": "string", "enum": ImportanceRater.importance.levels],
                    ],
                    "required": ["startLine", "endLine", "title", "explanation", "importance"],
                ],
            ],
        ],
        "required": ["summary", "sections"],
    ]

    func load(path: String, directory: URL) {
        guard explanations[path] == nil,
              let data = try? Data(contentsOf: fileURL(path, directory)) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let value = try? decoder.decode(CodeExplanation.self, from: data) {
            explanations[path] = value
            revision += 1
        }
    }

    func isStale(path: String, content: String) -> Bool {
        guard let explanation = explanations[path] else { return false }
        return explanation.contentHash != ContentHash.of(content)
            || (explanation.language ?? ActionOutputLanguage.documentLanguage) != ActionOutputLanguage.current
    }

    /// Split the file into logical sections and explain each (AI, read-only).
    func explain(path: String, content: String, root: URL, directory: URL, db: SemanticDatabase?) {
        guard !working.contains(path) else { return }
        working.insert(path)
        activity[path] = "Explaining…"
        errors[path] = nil
        revision += 1
        let lines = content.editorLines
        let numbered = lines.prefix(Self.maxLines).enumerated().map { index, line -> String in
            let text = line.count > Self.maxLineLength
                ? line.prefix(Self.maxLineLength) + " …[+\(line.count - Self.maxLineLength) chars]" : String(line)
            return "\(index + 1)| \(text)"
        }.joined(separator: "\n")
        let clipped = lines.count > Self.maxLines ? "\n[file continues to line \(lines.count); explain the part shown]" : ""
        let isDocument = FileType.markdownExtensions.contains((path as NSString).pathExtension.lowercased())
        let task = isDocument
            ? """
              You explain a documentation file to someone new to the project, like margin notes in a document \
              review. Split it into 3-25 sections that together cover it in order (contiguous line ranges using \
              the line numbers shown; usually one per heading, merging tiny ones). For each give a short title, \
              what the section says and why it matters, how it relates to the rest of the project, and its \
              importance for the people who build and run the system: critical (requirements, constraints, \
              security or data rules, decisions), high (key design, interfaces, how-tos), normal (background) or \
              low (history, changelogs, boilerplate).
              """
            : """
              You explain source code to an engineer who is new to this project, like margin notes in a \
              document review. Split the file into 3-25 logical sections that together cover it in order \
              (contiguous line ranges, using the line numbers shown; group imports/boilerplate into one short \
              section). For each give a short title, what the code does and why, how it connects to the rest \
              of the system, and its importance: critical (core logic, money, data integrity, security), high, \
              normal or low (boilerplate, logging, trivial helpers). Long lines are clipped (…[+N chars]).
              """
        liveAnswers[path] = ""
        Task {
            defer { working.remove(path); activity[path] = nil; liveAnswers[path] = nil; revision += 1 }
            // One pass over the file itself: no tools, the fast model at low effort.
            var request = CLICompletion.Request(
                prompt: "File: \(path) (\(lines.count) lines)\n\n\(numbered)\(clipped)",
                systemPrompt: task + " Be concise: 2-3 sentences per section.\n\n" + ActionOutputLanguage.explanationLine(),
                jsonSchema: Self.schema)
            request.model = AIAssistantPreferences.xrayModel(for: request.tool)
            request.effort = "low"
            request.timeout = 600
            let contentHash = ContentHash.of(content)
            let lineCount = lines.count
            do {
                let result = try await CLICompletion.run(request, onActivity: { [weak self] activity in
                    guard case .answerDelta(let text) = activity else { return }
                    Task { @MainActor in self?.receive(text, path: path, contentHash: contentHash, lineCount: lineCount) }
                })
                result.record(in: db)
                let object = result.structured as? [String: Any] ?? [:]
                let sections = (object["sections"] as? [[String: Any]] ?? []).compactMap { raw -> CodeSection? in
                    guard let start = raw["startLine"] as? Int, let end = raw["endLine"] as? Int else { return nil }
                    let level = raw["importance"] as? String ?? "normal"
                    return CodeSection(startLine: max(1, start), endLine: max(start, min(end, lines.count)),
                                       title: raw["title"] as? String ?? "Section",
                                       explanation: raw["explanation"] as? String ?? "",
                                       importance: ImportanceRater.importance.levels.contains(level) ? level : "normal")
                }.sorted { $0.startLine < $1.startLine }
                let tool = request.tool
                let explanation = CodeExplanation(
                    path: path, contentHash: ContentHash.of(content),
                    summary: object["summary"] as? String ?? "", sections: sections,
                    assistant: AIAssistantPreferences.summary(tool: tool, model: request.model ?? ""),
                    createdAt: Date(), language: ActionOutputLanguage.current)
                explanations[path] = explanation
                save(explanation, directory: directory)
            } catch is CancellationError {
            } catch {
                errors[path] = "Explain failed: \(error.localizedDescription)"
            }
        }
    }

    /// Show the sections finished so far while the answer is still being written.
    private func receive(_ text: String, path: String, contentHash: String, lineCount: Int) {
        guard liveAnswers[path] != nil else { return }
        liveAnswers[path]? += text
        guard liveRefreshPending.insert(path).inserted else { return }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            liveRefreshPending.remove(path)
            guard let answer = liveAnswers[path], working.contains(path) else { return }
            let sections = XRayDigest.completedObjects(in: answer, key: "sections").compactMap { raw -> CodeSection? in
                guard let start = raw["startLine"] as? Int, let end = raw["endLine"] as? Int else { return nil }
                let level = raw["importance"] as? String ?? "normal"
                return CodeSection(startLine: max(1, start), endLine: max(start, min(end, lineCount)),
                                   title: raw["title"] as? String ?? "Section", explanation: raw["explanation"] as? String ?? "",
                                   importance: ImportanceRater.importance.levels.contains(level) ? level : "normal")
            }
            guard !sections.isEmpty, sections.count != explanations[path]?.sections.count || explanations[path]?.contentHash != contentHash else { return }
            explanations[path] = CodeExplanation(path: path, contentHash: contentHash,
                                                 summary: XRayDigest.completedString(in: answer, key: "summary") ?? "",
                                                 sections: sections.sorted { $0.startLine < $1.startLine },
                                                 assistant: "", createdAt: Date(), language: ActionOutputLanguage.current)
            activity[path] = "Explaining… \(sections.count) sections"
            revision += 1
        }
    }

    /// Rate the explained sections against an AI filter (Importance or a user filter).
    func rate(path: String, content: String, filter: ImportanceRater.Filter, root: URL, directory: URL,
              db: SemanticDatabase?) {
        guard let explanation = explanations[path], explanation.ratings[filter.id] == nil,
              !working.contains(path) else { return }
        working.insert(path)
        activity[path] = "Rating: \(filter.name)…"
        revision += 1
        let lines = content.editorLines
        let items = explanation.sections.map { section -> ImportanceRater.Item in
            let code = lines[(section.startLine - 1)..<min(section.endLine, lines.count)].joined(separator: "\n")
            return ImportanceRater.Item(key: "s\(section.startLine)", label: section.title,
                                        detail: section.explanation + "\n```\n" + String(code.prefix(1500)) + "\n```")
        }
        let texts = explanation.sections.map { section in
            lines[(section.startLine - 1)..<min(section.endLine, lines.count)].joined(separator: "\n")
        }
        Task {
            defer { working.remove(path); activity[path] = nil; revision += 1 }
            // A topic filter: sections get a provisional level from a keyword search at once,
            // then the AI confirms them (Importance comes with the explanation itself).
            if filter.id != ImportanceRater.importance.id,
               let terms = try? await FilterSearch.terms(for: filter, cache: directory.appendingPathComponent("terms")) {
                var scores: [String: Double] = [:]
                var hits: [String: [String]] = [:]
                for (section, text) in zip(explanation.sections, texts) {
                    let match = FilterSearch.score(name: section.title, text: text, terms: terms)
                    scores["s\(section.startLine)"] = match.score
                    hits["s\(section.startLine)"] = match.hits
                }
                if var current = explanations[path], current.ratings[filter.id] == nil {
                    current.ratings[filter.id] = FilterSearch.levels(scores).mapValues { _ in .init(level: "none", reason: "") }
                    for (key, level) in FilterSearch.levels(scores) {
                        let mentions = hits[key] ?? []
                        current.ratings[filter.id]?[key] = .init(level: level,
                            reason: mentions.isEmpty ? "No mention found" : "Mentions " + mentions.prefix(4).joined(separator: ", "),
                            provisional: true)
                    }
                    explanations[path] = current
                    activity[path] = "Checking \(filter.name)…"
                    revision += 1
                }
            }
            let request = ImportanceRater.request(subject: .code, filter: filter, context: "File: \(path)\n\(explanation.summary)",
                                                  items: items,
                                                  language: Self.reasonLanguage)
            do {
                let result = try await CLICompletion.run(request)
                result.record(in: db)
                guard var current = explanations[path] else { return }
                current.ratings[filter.id] = ImportanceRater.parse(result.structured, keys: Set(items.map(\.key)), filter: filter)
                explanations[path] = current
                save(current, directory: directory)
            } catch is CancellationError {
            } catch {
                errors[path] = "\(filter.name) rating failed: \(error.localizedDescription)"
            }
        }
    }

    /// State of `path` for the code viewer's margin panel, as a JSON object literal.
    func payloadJSON(path: String, content: String, filters: [ImportanceRater.Filter]) -> String {
        struct Payload: Encodable {
            let explanation: CodeExplanation?
            let working: Bool
            let activity: String?
            let error: String?
            let stale: Bool
            let filters: [ImportanceRater.Filter]
        }
        let payload = Payload(explanation: explanations[path], working: working.contains(path), activity: activity[path], error: errors[path],
                              stale: isStale(path: path, content: content), filters: filters)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private func fileURL(_ path: String, _ directory: URL) -> URL {
        directory.appendingPathComponent(String(ContentHash.of(path).prefix(24)) + ".json")
    }

    private func save(_ explanation: CodeExplanation, directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var stored = explanation
            stored.ratings = stored.ratings.filter { !ImportanceRater.isTemporary($0.key) }   // one-off filters are never stored
            try encoder.encode(stored).write(to: fileURL(explanation.path, directory), options: .atomic)
        } catch {
            errors[explanation.path] = "Explanation could not be cached: \(error.localizedDescription)"
        }
    }
}
