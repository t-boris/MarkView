import Foundation

/// Research Engine — question → hybrid search → LLM answer with citations
@MainActor
class ResearchEngine: ObservableObject {
    @Published var isResearching = false
    @Published var lastAnswer: ResearchAnswer?

    let db: SemanticDatabase
    let hybridSearch: HybridSearch
    let providerClient: AIProviderClient

    init(db: SemanticDatabase, hybridSearch: HybridSearch, providerClient: AIProviderClient) {
        self.db = db
        self.hybridSearch = hybridSearch
        self.providerClient = providerClient
    }

    struct ResearchAnswer {
        let question: String
        let answer: String
        let citations: [Citation]
        let searchResults: [HybridSearch.HybridResult]
    }

    struct Citation {
        let documentId: String
        let lineStart: Int?
        let quote: String
    }

    /// Ask a question about the workspace, get a cited answer.
    /// Returns ResearchAnswer on success, or ResearchAnswer with error text on failure.
    func research(question: String, moduleId: String? = nil) async -> ResearchAnswer? {
        guard providerClient.hasAPIKey else {
            return ResearchAnswer(question: question, answer: "Error: No API key configured. Go to Settings to add your Anthropic API key.", citations: [], searchResults: [])
        }
        isResearching = true
        defer { isResearching = false }

        guard let apiKey = providerClient.apiKeyValue else {
            return ResearchAnswer(question: question, answer: "Error: Could not read API key.", citations: [], searchResults: [])
        }

        // Step 1: Build structural context — module graph, components, relations (capped at 6000 chars)
        let structuralContext = String(buildStructuralContext().prefix(6000))

        // Step 2: Hybrid search for relevant chunks
        var results = await hybridSearch.search(query: question, limit: 10)

        // Step 3: Gather document context from top results
        var sourceContext = ""
        if results.isEmpty {
            NSLog("[Research] FTS empty, falling back to direct file read")
            let allDocs = db.allModules()
            for mod in allDocs.prefix(5) {
                let fm = FileManager.default
                let dirURL = URL(fileURLWithPath: mod.path)
                if let files = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
                    for file in files.prefix(3) where file.pathExtension.lowercased() == "md" {
                        if let content = try? String(contentsOf: file, encoding: .utf8) {
                            sourceContext += "--- Source: \(file.lastPathComponent) ---\n\(String(content.prefix(3000)))\n\n"
                            results.append(HybridSearch.HybridResult(documentId: file.lastPathComponent, title: file.lastPathComponent, snippet: String(content.prefix(200)), score: 0.5, ftsScore: 0, semanticScore: 0, graphScore: 0))
                        }
                    }
                }
            }
        } else {
            for (i, r) in results.prefix(8).enumerated() {
                sourceContext += "--- Source \(i+1): \(r.title) ---\n\(r.snippet)\n\n"
            }
        }

        // Cap total source context to avoid exceeding token limits
        sourceContext = String(sourceContext.prefix(12000))

        // Step 4: Ask LLM with full context (structure + sources)
        let prompt = """
        You are an expert software architect analyzing a documentation repository.
        Answer the question using the Architecture Context and Document Sources below.
        Include citations as [Source N] where N matches the source number.

        Question: \(question)

        === Architecture Context ===
        \(structuralContext)

        === Document Sources ===
        \(sourceContext)

        Provide a thorough, structured answer with citations:
        """

        NSLog("[Research] Prompt size: \(prompt.count) chars, \(results.count) sources")

        let body: [String: Any] = [
            "model": "claude-opus-4-6",
            "max_tokens": 4096,
            "messages": [["role": "user", "content": prompt]]
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = data
            request.timeoutInterval = 120

            let (responseData, response) = try await URLSession.shared.data(for: request)

            // Check HTTP status
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return ResearchAnswer(question: question, answer: "Error: Invalid response from API (HTTP \(httpStatus))", citations: [], searchResults: [])
            }

            // Check for API error
            if let error = json["error"] as? [String: Any] {
                let msg = error["message"] as? String ?? "Unknown API error"
                let type = error["type"] as? String ?? ""
                NSLog("[Research] API error: \(type): \(msg)")
                return ResearchAnswer(question: question, answer: "API Error (\(type)): \(msg)", citations: [], searchResults: [])
            }

            guard let content = json["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else {
                let raw = String(data: responseData, encoding: .utf8)?.prefix(500) ?? "empty"
                NSLog("[Research] Unexpected response: \(raw)")
                return ResearchAnswer(question: question, answer: "Error: Unexpected API response format. HTTP \(httpStatus).", citations: [], searchResults: [])
            }

            // Track cost
            if let usage = json["usage"] as? [String: Any] {
                let inp = usage["input_tokens"] as? Int ?? 0
                let out = usage["output_tokens"] as? Int ?? 0
                db.addUsage(inputTokens: inp, outputTokens: out, costCents: Double(inp) * 0.0015 + Double(out) * 0.0075)
            }

            // Parse citations from answer
            var citations: [Citation] = []
            let pattern = #"\[Source (\d+)\]"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for match in matches {
                    if let range = Range(match.range(at: 1), in: text),
                       let idx = Int(text[range]),
                       idx > 0, idx <= results.count {
                        let r = results[idx - 1]
                        citations.append(Citation(documentId: r.documentId, lineStart: nil, quote: r.snippet))
                    }
                }
            }

            // Save as artifact — include question in content for history
            let artifactId = "research_\(fnv1a(question))_\(Int(Date().timeIntervalSince1970))"
            let fullContent = "## Q: \(question)\n\n\(text)"
            db.upsertArtifact(id: artifactId, moduleId: moduleId, kind: "research", content: fullContent, model: "opus-4")

            // Save citations
            for (i, c) in citations.enumerated() {
                db.insertCitation(id: "\(artifactId)_c\(i)", artifactId: artifactId, documentId: c.documentId,
                                  lineStart: c.lineStart, lineEnd: nil, quoteText: c.quote)
            }

            let answer = ResearchAnswer(question: question, answer: text, citations: citations, searchResults: Array(results))
            lastAnswer = answer
            return answer
        } catch {
            NSLog("[Research] Error: \(error)")
            return ResearchAnswer(question: question, answer: "Error: \(error.localizedDescription)", citations: [], searchResults: [])
        }
    }

    /// Build structural context from the module graph: components, types, relations
    private func buildStructuralContext() -> String {
        let modules = db.allModules()
        var lines: [String] = []

        // Components by type
        var byType: [String: [String]] = [:]
        for mod in modules where mod.id.hasPrefix("cmod_") {
            let symbols = db.symbolsForModule(mod.id)
            let typeSymbol = symbols.first(where: { $0.kind == "component" })
            let typeName: String
            if let ctx = typeSymbol?.context, ctx.hasPrefix("["), let end = ctx.firstIndex(of: "]") {
                typeName = String(ctx[ctx.index(after: ctx.startIndex)..<end])
            } else {
                typeName = "component"
            }
            let desc = typeSymbol?.context ?? ""
            byType[typeName, default: []].append("\(mod.name): \(desc)")
        }

        if !byType.isEmpty {
            lines.append("Components (\(modules.filter { $0.id.hasPrefix("cmod_") }.count) total):")
            for (type, comps) in byType.sorted(by: { $0.key < $1.key }) {
                lines.append("  [\(type)] (\(comps.count)):")
                for comp in comps.prefix(20) {
                    lines.append("    - \(comp)")
                }
                if comps.count > 20 { lines.append("    ... and \(comps.count - 20) more") }
            }
        }

        // Directory modules
        let dirModules = modules.filter { !$0.id.hasPrefix("cmod_") }
        if !dirModules.isEmpty {
            lines.append("\nDirectory structure (\(dirModules.count) modules):")
            for mod in dirModules.prefix(30) {
                let indent = String(repeating: "  ", count: mod.level)
                lines.append("\(indent)- \(mod.name) (\(mod.fileCount) files)")
            }
        }

        // Relations
        var relations: [String] = []
        for mod in modules.prefix(50) {
            let rels = db.relationsForModule(mod.id)
            for rel in rels {
                relations.append("\(mod.name) --[\(rel.type)]--> \(rel.targetId)")
            }
        }
        if !relations.isEmpty {
            lines.append("\nRelations (\(relations.count)):")
            for rel in relations.prefix(50) {
                lines.append("  \(rel)")
            }
            if relations.count > 50 { lines.append("  ... and \(relations.count - 50) more") }
        }

        return lines.joined(separator: "\n")
    }

    private func fnv1a(_ str: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in str.utf8 { hash ^= UInt32(byte); hash = hash &* 0x01000193 }
        return String(hash, radix: 16)
    }
}
