import Foundation

/// Action Engine — structured workflows for module-level actions.
/// LLM is called ONLY when user clicks an action button, never automatically.
@MainActor
class ActionEngine: ObservableObject {
    @Published var isProcessing = false
    @Published var currentAction: String?
    @Published var lastResult: ActionResult?

    let db: SemanticDatabase
    let providerClient: AIProviderClient

    init(db: SemanticDatabase, providerClient: AIProviderClient) {
        self.db = db
        self.providerClient = providerClient
    }

    struct ActionResult {
        let kind: String    // summary, c4_diagram, description, adr
        let content: String
        let moduleId: String?
    }

    // MARK: - Actions

    /// Describe: generate module description from its files
    func describe(moduleId: String) async -> ActionResult? {
        guard providerClient.hasAPIKey else { return nil }
        isProcessing = true; currentAction = "Describe"
        defer { isProcessing = false; currentAction = nil }

        let context = gatherContext(moduleId: moduleId)
        let prompt = """
        You are a technical writer. Describe this module/directory based on its contents.
        Write 2-3 paragraphs explaining: what this module does, its main components, and how it fits in the larger system.

        Module: \(context.moduleName)
        Files: \(context.fileNames.joined(separator: ", "))
        Headings found: \(context.headings.prefix(20).joined(separator: ", "))
        Links to: \(context.outgoingLinks.prefix(10).joined(separator: ", "))
        Referenced by: \(context.incomingLinks.prefix(10).joined(separator: ", "))

        File contents (excerpts):
        \(context.contentExcerpts)
        """

        let result = try? await callLLM(prompt: prompt)
        let artifact = ActionResult(kind: "description", content: result ?? "Failed to generate", moduleId: moduleId)

        // Save as artifact
        db.upsertArtifact(id: "desc_\(moduleId)", moduleId: moduleId, kind: "description", content: artifact.content, model: "sonnet-4")
        lastResult = artifact
        return artifact
    }

    /// Summarize: one-paragraph summary
    func summarize(moduleId: String) async -> ActionResult? {
        guard providerClient.hasAPIKey else { return nil }
        isProcessing = true; currentAction = "Summarize"
        defer { isProcessing = false; currentAction = nil }

        let context = gatherContext(moduleId: moduleId)
        let prompt = """
        Write a single paragraph summary (3-4 sentences) of this module.
        Module: \(context.moduleName)
        Files: \(context.fileNames.joined(separator: ", "))
        Key headings: \(context.headings.prefix(15).joined(separator: ", "))

        Content excerpts:
        \(context.contentExcerpts)
        """

        let result = try? await callLLM(prompt: prompt)
        let artifact = ActionResult(kind: "summary", content: result ?? "Failed", moduleId: moduleId)
        db.upsertArtifact(id: "sum_\(moduleId)", moduleId: moduleId, kind: "summary", content: artifact.content, model: "sonnet-4")
        lastResult = artifact
        return artifact
    }

    /// Diagram: generate C4 Component diagram as Mermaid
    func diagram(moduleId: String) async -> ActionResult? {
        guard providerClient.hasAPIKey else { return nil }
        isProcessing = true; currentAction = "Diagram"
        defer { isProcessing = false; currentAction = nil }

        let context = gatherContext(moduleId: moduleId)
        let prompt = """
        Generate a Mermaid.js flowchart for this module. Return ONLY raw Mermaid code, no markdown fences.

        STRICT SYNTAX RULES:
        - Start with exactly: graph TD
        - Node IDs must be alphanumeric only (A-Z, a-z, 0-9, underscore). NO dots, hyphens, spaces, or special chars in IDs.
        - Labels in square brackets: NodeId[Label Text Here]
        - Edges: NodeId1 --> NodeId2  or  NodeId1 -->|edge label| NodeId2
        - Subgraphs: subgraph Title\\n ... end
        - classDef for styling: classDef className fill:#color,stroke:#color,color:#textcolor
        - Apply classes: class NodeId className
        - Do NOT use parentheses () for nodes — only square brackets []
        - Do NOT use HTML tags in labels
        - Do NOT use quotes around labels
        - Max 15 nodes

        Module: \(context.moduleName)
        Components: \(context.headings.prefix(15).joined(separator: ", "))
        Outgoing links: \(context.outgoingLinks.prefix(10).joined(separator: ", "))
        Incoming links: \(context.incomingLinks.prefix(10).joined(separator: ", "))

        Content:
        \(String(context.contentExcerpts.prefix(4000)))
        """

        let result = try? await callLLM(prompt: prompt, model: "claude-opus-4-6")
        var mermaid = (result ?? "graph TD\n  A[No data]").trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip code fences: ```mermaid ... ``` or ``` ... ```
        while mermaid.hasPrefix("```") {
            mermaid = String(mermaid.drop(while: { $0 != "\n" }).dropFirst())
            mermaid = mermaid.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while mermaid.hasSuffix("```") {
            mermaid = String(mermaid.dropLast(3))
            mermaid = mermaid.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let artifact = ActionResult(kind: "c4_diagram", content: mermaid.trimmingCharacters(in: .whitespacesAndNewlines), moduleId: moduleId)
        db.upsertArtifact(id: "diag_\(moduleId)", moduleId: moduleId, kind: "c4_diagram", content: artifact.content, model: "opus-4")
        lastResult = artifact
        return artifact
    }

    /// ADR: generate Architecture Decision Record
    func generateADR(moduleId: String, topic: String) async -> ActionResult? {
        guard providerClient.hasAPIKey else { return nil }
        isProcessing = true; currentAction = "ADR"
        defer { isProcessing = false; currentAction = nil }

        let context = gatherContext(moduleId: moduleId)
        let prompt = """
        Generate an Architecture Decision Record (ADR) in arc42/MADR format for this topic.

        Topic: \(topic)
        Module: \(context.moduleName)

        Use this template:
        # ADR: [Title]
        ## Status: Proposed
        ## Context: [What is the issue?]
        ## Decision: [What was decided?]
        ## Consequences: [What are the results?]
        ## Alternatives Considered: [What else was considered?]

        Base your ADR on the module contents:
        \(context.contentExcerpts)
        """

        let result = try? await callLLM(prompt: prompt)
        let artifact = ActionResult(kind: "adr", content: result ?? "Failed", moduleId: moduleId)
        db.upsertArtifact(id: "adr_\(moduleId)_\(fnv1a(topic))", moduleId: moduleId, kind: "adr", content: artifact.content, model: "sonnet-4")
        lastResult = artifact
        return artifact
    }

    // MARK: - Context Gathering (deterministic)

    struct ModuleContext {
        let moduleName: String
        let fileNames: [String]
        let headings: [String]
        let outgoingLinks: [String]
        let incomingLinks: [String]
        let contentExcerpts: String
    }

    private func gatherContext(moduleId: String) -> ModuleContext {
        let modules = db.allModules()
        let mod = modules.first(where: { $0.id == moduleId })

        let symbols = db.symbolsForModule(moduleId)
        let outRels = db.relationsForModule(moduleId)
        let inRels = db.incomingRelationsForModule(moduleId)

        // Get file contents from FTS (first 500 chars per file)
        let fileSymbols = symbols.filter { $0.kind == "heading" }
        let fileNames = Array(Set(symbols.compactMap { $0.doc }))

        // Read actual file content for excerpts
        var excerpts = ""
        if let mod = mod {
            let dirURL = URL(fileURLWithPath: mod.path)
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
                for file in files.prefix(5) where file.pathExtension.lowercased() == "md" {
                    if let content = try? String(contentsOf: file, encoding: .utf8) {
                        excerpts += "--- \(file.lastPathComponent) ---\n\(String(content.prefix(2000)))\n\n"
                    }
                }
            }
        }

        return ModuleContext(
            moduleName: mod?.name ?? moduleId,
            fileNames: fileNames,
            headings: fileSymbols.map { $0.name },
            outgoingLinks: outRels.map { "\($0.type): \($0.targetId)" },
            incomingLinks: inRels.map { "\($0.type): \($0.sourceId)" },
            contentExcerpts: String(excerpts.prefix(8000))
        )
    }

    // MARK: - LLM Call

    private func callLLM(prompt: String, model: String = "claude-sonnet-4-6") async throws -> String {
        guard let apiKey = providerClient.apiKeyValue else { throw AIProviderError.noAPIKey }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": [["role": "user", "content": prompt]]
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = data
        request.timeoutInterval = 120

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AIProviderError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, String(data: responseData, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw AIProviderError.parseError("No text")
        }

        // Track cost
        if let usage = json["usage"] as? [String: Any] {
            let inp = usage["input_tokens"] as? Int ?? 0
            let out = usage["output_tokens"] as? Int ?? 0
            let cost = Double(inp) * 0.0003 + Double(out) * 0.0015
            db.addUsage(inputTokens: inp, outputTokens: out, costCents: cost)
        }

        return text
    }

    private func fnv1a(_ str: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in str.utf8 { hash ^= UInt32(byte); hash = hash &* 0x01000193 }
        return String(hash, radix: 16)
    }
}

// Expose apiKey for ActionEngine
extension AIProviderClient {
    var apiKeyValue: String? {
        hasAPIKey ? UserDefaults.standard.string(forKey: "com.markview.dde.apikey") : nil
    }
}
