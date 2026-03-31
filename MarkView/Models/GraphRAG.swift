import Foundation

/// GraphRAG — community detection + map-reduce research for large codebases (100+ files)
@MainActor
class GraphRAG: ObservableObject {
    @Published var communities: [Community] = []
    @Published var isProcessing = false

    let db: SemanticDatabase
    let providerClient: AIProviderClient

    init(db: SemanticDatabase, providerClient: AIProviderClient) {
        self.db = db
        self.providerClient = providerClient
    }

    struct Community: Identifiable {
        let id: String
        let name: String
        let moduleIds: [String]
        var summary: String?
        let level: Int
    }

    // MARK: - Community Detection (Louvain-like)

    /// Detect communities from the module graph using simple modularity-based clustering
    func detectCommunities() {
        let modules = db.allModules()
        guard modules.count > 5 else { return } // Too few for communities

        // Build adjacency from struct_relations
        var adjacency: [String: Set<String>] = [:]
        for mod in modules {
            let rels = db.relationsForModule(mod.id)
            for rel in rels {
                adjacency[mod.id, default: []].insert(rel.targetId)
                adjacency[rel.targetId, default: []].insert(mod.id) // undirected
            }
        }

        // Simple community detection: group modules by connectivity
        var visited = Set<String>()
        var detectedCommunities: [Community] = []
        var communityIndex = 0

        for mod in modules {
            guard !visited.contains(mod.id) else { continue }

            // BFS to find connected component
            var queue = [mod.id]
            var component: [String] = []
            while !queue.isEmpty {
                let current = queue.removeFirst()
                guard !visited.contains(current) else { continue }
                visited.insert(current)
                component.append(current)

                for neighbor in adjacency[current] ?? [] {
                    if !visited.contains(neighbor) { queue.append(neighbor) }
                }
            }

            if component.count >= 2 { // Only communities with 2+ modules
                communityIndex += 1
                let modNames = component.compactMap { id in modules.first(where: { $0.id == id })?.name }
                detectedCommunities.append(Community(
                    id: "comm_\(communityIndex)",
                    name: "Community \(communityIndex): \(modNames.prefix(3).joined(separator: ", "))",
                    moduleIds: component,
                    summary: nil,
                    level: 0
                ))
            }
        }

        // Isolated modules form their own "community"
        let isolatedModules = modules.filter { !visited.contains($0.id) }
        if !isolatedModules.isEmpty {
            communityIndex += 1
            detectedCommunities.append(Community(
                id: "comm_isolated",
                name: "Standalone Modules",
                moduleIds: isolatedModules.map { $0.id },
                summary: nil,
                level: 0
            ))
        }

        communities = detectedCommunities

        // Save to DB
        for c in communities {
            let idsJSON = (try? JSONSerialization.data(withJSONObject: c.moduleIds))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            try? db.execute_raw(
                "INSERT OR REPLACE INTO communities (community_id, name, module_ids_json, level) VALUES ('\(c.id)', '\(c.name.replacingOccurrences(of: "'", with: "''"))', '\(idsJSON)', \(c.level))",
                text: c.id
            )
        }

        NSLog("[GraphRAG] Detected \(communities.count) communities from \(modules.count) modules")
    }

    // MARK: - Deep Research (map-reduce)

    /// Research across all communities — map each community, then reduce answers
    func deepResearch(question: String) async -> String? {
        guard providerClient.hasAPIKey else { return nil }
        if communities.isEmpty { detectCommunities() }
        guard !communities.isEmpty else { return "No communities detected. Try regular Research instead." }

        isProcessing = true
        defer { isProcessing = false }

        // MAP: ask each community
        var communityAnswers: [(community: String, answer: String)] = []

        for community in communities {
            // Gather context for this community's modules
            let modules = db.allModules().filter { community.moduleIds.contains($0.id) }
            let context = modules.map { "Module: \($0.name) (\($0.fileCount) files)" }.joined(separator: "\n")

            let mapPrompt = """
            Based on this community of modules, answer the question if relevant.
            If this community has no relevant information, respond with "NOT_RELEVANT".

            Community: \(community.name)
            Modules:
            \(context)

            Question: \(question)
            """

            if let answer = try? await callLLM(prompt: mapPrompt, maxTokens: 1024) {
                if !answer.contains("NOT_RELEVANT") {
                    communityAnswers.append((community.name, answer))
                }
            }
        }

        guard !communityAnswers.isEmpty else { return "No relevant information found across communities." }

        // REDUCE: merge all community answers
        let reducePrompt = """
        Merge these partial answers from different parts of the codebase into one coherent answer.
        Preserve all unique information. Resolve any conflicts by noting both perspectives.

        Question: \(question)

        Partial answers:
        \(communityAnswers.map { "--- \($0.community) ---\n\($0.answer)" }.joined(separator: "\n\n"))

        Merged answer:
        """

        let finalAnswer = try? await callLLM(prompt: reducePrompt, maxTokens: 4096)

        // Save as artifact
        db.upsertArtifact(id: "deepresearch_\(fnv1a(question))", moduleId: nil, kind: "deep_research",
                          content: finalAnswer ?? "Failed", model: "sonnet-4")

        return finalAnswer
    }

    // MARK: - Summarize Communities

    /// Generate summaries for all communities
    func summarizeCommunities() async {
        guard providerClient.hasAPIKey else { return }

        for (i, community) in communities.enumerated() where community.summary == nil {
            let modules = db.allModules().filter { community.moduleIds.contains($0.id) }
            let context = modules.map { mod in
                let symbols = db.symbolsForModule(mod.id)
                let headings = symbols.filter { $0.kind == "heading" }.map { $0.name }.prefix(10)
                return "- \(mod.name): \(headings.joined(separator: ", "))"
            }.joined(separator: "\n")

            let prompt = "Summarize this group of modules in 2-3 sentences:\n\(context)"
            if let summary = try? await callLLM(prompt: prompt, maxTokens: 256) {
                communities[i].summary = summary
            }
        }
    }

    // MARK: - Helpers

    private func callLLM(prompt: String, maxTokens: Int = 2048) async throws -> String {
        guard let apiKey = providerClient.apiKeyValue else { throw AIProviderError.noAPIKey }

        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = data
        request.timeoutInterval = 60

        let (responseData, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else { throw AIProviderError.parseError("No text") }

        if let usage = json["usage"] as? [String: Any] {
            let inp = usage["input_tokens"] as? Int ?? 0
            let out = usage["output_tokens"] as? Int ?? 0
            db.addUsage(inputTokens: inp, outputTokens: out, costCents: Double(inp) * 0.0003 + Double(out) * 0.0015)
        }

        return text
    }

    private func fnv1a(_ str: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in str.utf8 { hash ^= UInt32(byte); hash = hash &* 0x01000193 }
        return String(hash, radix: 16)
    }
}
