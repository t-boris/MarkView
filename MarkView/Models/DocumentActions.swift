import Foundation
import CryptoKit

/// One thing the AI can produce from a document — a button in the Actions tab.
struct DocumentAction: Codable, Identifiable, Hashable {
    let id: String
    /// Button label, a few words.
    let title: String
    /// One line on what the result will contain.
    let detail: String
    let kind: Kind
    /// Self-contained instruction the AI gets together with the document.
    let instruction: String

    enum Kind: String, Codable, CaseIterable {
        case summary, diagram, flow, table, checklist, analysis, rewrite, other

        /// Suggestions come from a model; an unknown kind must not drop the action.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }

        var symbol: String {
            switch self {
            case .summary: return "text.alignleft"
            case .diagram: return "chart.dots.scatter"
            case .flow: return "arrow.triangle.branch"
            case .table: return "tablecells"
            case .checklist: return "checklist"
            case .analysis: return "magnifyingglass"
            case .rewrite: return "pencil.and.outline"
            case .other: return "sparkles"
            }
        }
    }

    /// Actions offered for every document, before or without an analysis.
    static let base: [DocumentAction] = [
        DocumentAction(
            id: "executive-summary", title: "Executive summary",
            detail: "One page for a busy decision-maker", kind: .summary,
            instruction: "Write an executive summary for a busy decision-maker: purpose, key points, decisions needed, risks and next steps. At most one page."),
        DocumentAction(
            id: "key-decisions", title: "Key decisions",
            detail: "Decisions, rationale, alternatives, status", kind: .table,
            instruction: "List every decision made or proposed in the document as a table: decision, rationale, alternatives considered, status, owner (when stated). Add short notes below the table where a decision needs context."),
        DocumentAction(
            id: "risks-questions", title: "Risks & open questions",
            detail: "Gaps, contradictions and what is still undecided", kind: .analysis,
            instruction: "Identify risks, open questions, gaps and contradictions in the document. For each: what it is, where it appears, why it matters and a suggested way to resolve it."),
        DocumentAction(
            id: "action-items", title: "Action items",
            detail: "Tasks and follow-ups as a checklist", kind: .checklist,
            instruction: "Extract all action items, tasks and follow-ups as a markdown task list (- [ ]), grouped by owner or area, with due dates when the document states them."),
        DocumentAction(
            id: "glossary", title: "Glossary",
            detail: "Terms, acronyms and named entities", kind: .table,
            instruction: "Build a glossary of the terms, acronyms and named entities used in the document, each with a short definition drawn from the document."),
        DocumentAction(
            id: "faq", title: "FAQ",
            detail: "Questions a new reader would ask", kind: .other,
            instruction: "Write an FAQ a new reader would need: 8–15 questions with answers grounded in the document."),
    ]
}

/// Result of analysing one document: what it is and which actions suit it.
struct DocumentAnalysis: Codable {
    let documentName: String
    /// SHA-256 of the content that was analysed; a mismatch means the document changed.
    let contentHash: String
    let documentType: String
    let summary: String
    let actions: [DocumentAction]
    let analyzedAt: Date
    /// Assistant and model that produced it, e.g. "Claude Code · opus".
    let assistant: String
}

/// Language the action results are written in.
enum ActionOutputLanguage {
    static let storageKey = "actions.outputLanguage"
    /// Stored value meaning "same language as the source document".
    static let documentLanguage = "document"

    /// (stored value, menu label). Values other than `documentLanguage` go into the prompt.
    static let options: [(value: String, label: String)] = [
        (documentLanguage, "Document language"),
        ("English", "English"),
        ("Russian", "Русский"),
        ("Ukrainian", "Українська"),
        ("German", "Deutsch"),
        ("French", "Français"),
        ("Spanish", "Español"),
        ("Hebrew", "עברית"),
        ("Chinese (Simplified)", "中文"),
    ]

    static func label(for value: String) -> String {
        options.first { $0.value == value }?.label ?? value
    }

    /// The language chosen for everything the AI writes (Actions tab and DDE Settings).
    static var current: String { UserDefaults.standard.string(forKey: storageKey) ?? documentLanguage }

    /// Instruction for generated text that is not a transformation of one document:
    /// code explanations, architecture descriptions, rating reasons, reviews.
    static func explanationLine(_ value: String = current) -> String {
        value == documentLanguage
            ? "Write all natural-language text in the language the project's documents and code comments mostly use; English when unclear."
            : "Write every natural-language text you produce (names, titles, summaries, explanations, reasons) in \(value). Keep code, identifiers, file paths and the fixed enum values of the JSON schema exactly as specified."
    }

    static func promptLine(for value: String) -> String {
        value == documentLanguage
            ? "Write in the same language as the source document."
            : "Write the whole result in \(value), even if the source document is in another language. Keep code, identifiers, file names and Mermaid node IDs unchanged."
    }
}

// MARK: - Prompts

enum DocumentActionPrompts {
    static let analysisSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "documentType": ["type": "string", "description": "Short label such as \"API design doc\", \"meeting notes\", \"product spec\"."],
            "summary": ["type": "string", "description": "One or two sentences on what the document is about."],
            "actions": [
                "type": "array",
                "minItems": 4,
                "maxItems": 10,
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Lowercase slug, unique in this list."],
                        "title": ["type": "string", "description": "Button label, imperative, at most 5 words."],
                        "detail": ["type": "string", "description": "One line on what the result will contain."],
                        "kind": ["type": "string", "enum": DocumentAction.Kind.allCases.map(\.rawValue)],
                        "instruction": ["type": "string", "description": "Complete, self-contained instruction for producing the result from this document, naming the specific parts of the document it covers."],
                    ],
                    "required": ["id", "title", "detail", "kind", "instruction"],
                ],
            ],
        ],
        "required": ["documentType", "summary", "actions"],
    ]

    static var analysisSystem: String {
        let base = DocumentAction.base.map(\.title).joined(separator: ", ")
        return """
        You analyse one markdown document and suggest what an AI assistant could produce FROM it that \
        would help its reader. Return JSON matching the schema.

        - documentType and summary describe the document.
        - actions: 6 to 10 suggestions specific to THIS document. Name the concrete flows, components, \
        decisions, entities or sections each one covers — "Diagram the checkout payment flow", not \
        "Create a diagram". Prefer outputs that add structure the document lacks: Mermaid diagrams of \
        specific flows, architectures, state machines or sequences; comparison tables; timelines; \
        checklists; test cases; briefs for a specific audience; gap analyses; rewrites for another reader.
        - Suggest only what the document has enough material for.
        - Do not suggest these, they are always available: \(base).
        - Write documentType, summary, title and detail in English. The instruction may quote the \
        document in its own language.
        """
    }

    static func runSystem(language: String) -> String {
        """
        You produce a new markdown document derived from a source document. Output only the markdown \
        of the new document, starting with a level-1 heading; no preamble and no closing remarks.
        Base everything on the source document. Do not invent facts: when something is not stated, say \
        so or mark it clearly as an assumption.
        Use ```mermaid code blocks for diagrams (flowchart, sequenceDiagram, stateDiagram-v2, erDiagram, \
        timeline, …), markdown tables for comparisons and task lists (- [ ]) for action items.
        \(ActionOutputLanguage.promptLine(for: language))
        """
    }

    static func document(name: String, content: String) -> String {
        "Source document (\(name)):\n<document>\n\(content)\n</document>"
    }
}

// MARK: - Store

/// Cached analyses per document, plus what is analysing or running right now.
/// Analyses live as JSON under `<workspace>/.dde/cache/actions/` so reopening a
/// document never re-analyses it.
@MainActor
final class DocumentActionsStore: ObservableObject {
    @Published private(set) var analyses: [String: DocumentAnalysis] = [:]
    @Published private(set) var analyzing: Set<String> = []
    /// "<file path>|<action id>" of actions currently generating.
    @Published private(set) var running: Set<String> = []
    @Published var errors: [String: String] = [:]

    /// Forget everything loaded from the workspace (its metadata was removed).
    func reset() {
        analyses = [:]
        errors = [:]
    }

    static func contentHash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func isAnalyzing(_ url: URL) -> Bool { analyzing.contains(url.path) }
    func isRunning(_ action: DocumentAction, for url: URL) -> Bool { running.contains(runKey(action, url)) }

    /// Load the cached analysis for `url` if there is one (idempotent).
    func load(for url: URL, storeDirectory: URL) {
        guard analyses[url.path] == nil,
              let data = try? Data(contentsOf: fileURL(for: url, in: storeDirectory)) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let analysis = try? decoder.decode(DocumentAnalysis.self, from: data) {
            analyses[url.path] = analysis
        }
    }

    /// Analyse the document and cache the result. Errors land in `errors[url.path]`.
    func analyze(url: URL, content: String, storeDirectory: URL, db: SemanticDatabase?) async {
        guard !analyzing.contains(url.path) else { return }
        analyzing.insert(url.path)
        errors[url.path] = nil
        defer { analyzing.remove(url.path) }

        var request = CLICompletion.Request(
            prompt: DocumentActionPrompts.document(name: url.lastPathComponent, content: content),
            systemPrompt: DocumentActionPrompts.analysisSystem,
            jsonSchema: DocumentActionPrompts.analysisSchema)
        request.timeout = 300
        do {
            let result = try await CLICompletion.run(request)
            result.record(in: db)
            let object = result.structured as? [String: Any] ?? [:]
            let actionData = try JSONSerialization.data(withJSONObject: object["actions"] ?? [])
            var actions = try JSONDecoder().decode([DocumentAction].self, from: actionData)
            // Keep ids unique and clear of the base actions so run keys never collide.
            var seen = Set(DocumentAction.base.map(\.id))
            actions = actions.map { action in
                var id = action.id.isEmpty ? "action" : action.id
                while seen.contains(id) { id += "-x" }
                seen.insert(id)
                return DocumentAction(id: id, title: action.title, detail: action.detail,
                                      kind: action.kind, instruction: action.instruction)
            }
            let tool = request.tool
            let analysis = DocumentAnalysis(
                documentName: url.lastPathComponent,
                contentHash: Self.contentHash(content),
                documentType: object["documentType"] as? String ?? "",
                summary: object["summary"] as? String ?? "",
                actions: actions,
                analyzedAt: Date(),
                assistant: AIAssistantPreferences.summary(tool: tool, model: AIAssistantPreferences.model(for: tool) ?? ""))
            analyses[url.path] = analysis
            save(analysis, for: url, in: storeDirectory)
        } catch is CancellationError {
            return
        } catch {
            errors[url.path] = "Analysis failed: \(error.localizedDescription)"
        }
    }

    func markRunning(_ action: DocumentAction, for url: URL, _ isRunning: Bool) {
        if isRunning { running.insert(runKey(action, url)) } else { running.remove(runKey(action, url)) }
    }

    private func runKey(_ action: DocumentAction, _ url: URL) -> String { "\(url.path)|\(action.id)" }

    private func fileURL(for url: URL, in directory: URL) -> URL {
        let key = Self.contentHash(url.standardizedFileURL.path).prefix(24)
        return directory.appendingPathComponent("\(key).json")
    }

    private func save(_ analysis: DocumentAnalysis, for url: URL, in directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(analysis).write(to: fileURL(for: url, in: directory), options: .atomic)
        } catch {
            errors[url.path] = "Analysis done but could not be cached: \(error.localizedDescription)"
        }
    }
}

/// Text collected from a streaming run. Each delta hands the main actor a full
/// snapshot, so the order in which those hops land does not matter.
final class StreamedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) -> String {
        lock.lock(); defer { lock.unlock() }
        text += chunk
        return text
    }
}
