import Foundation

/// HTTP client for Claude API — uses Tool Use (SGR) for structured extraction
class AIProviderClient {
    private var apiKey: String?
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let model = "claude-sonnet-4-6"
    private let session = URLSession.shared

    static let defaultDiagramPrompts: [String: String] = [
        "software": """
            You are a senior software architect. Analyze the entities and claims, identify SEPARATE systems/domains, and create ONE Mermaid diagram PER SYSTEM.

            IMPORTANT: Do NOT create one giant diagram. Create separate diagrams for each logical system/domain.
            Plus ONE overview diagram showing how systems communicate with each other.

            Return a JSON array of diagrams:
            [{"title": "System Name", "mermaid": "graph TD\\n..."}, {"title": "Overview", "mermaid": "graph TD\\n..."}]

            Rules per diagram:
            - Use `graph TD`, subgraph for grouping within a system
            - Services as `(Name)`, databases as `[(DB)]`, APIs as `{{API}}`, queues as `[/Queue/]`
            - Label ALL connections. Use classDef for colors.
            - Keep each diagram focused — max 15 nodes per system diagram
            - Overview diagram shows only system-to-system connections

            Return ONLY valid JSON array, no markdown, no explanation.
            """,
        "dataflow": """
            You are a data architect. Identify separate data pipelines/flows and create ONE diagram PER pipeline.

            IMPORTANT: Do NOT mix all flows into one diagram. Each pipeline gets its own diagram.
            Plus ONE overview showing how pipelines connect.

            Return a JSON array: [{"title": "Pipeline Name", "mermaid": "graph LR\\n..."}]

            Rules per diagram:
            - Use `graph LR` (left-to-right)
            - Sources left, processing middle, storage right
            - Label edges with data type. Use classDef for colors.
            - Max 12 nodes per diagram

            Return ONLY valid JSON array, no markdown, no explanation.
            """,
        "deployment": """
            You are a DevOps architect. Identify separate deployment domains and create ONE diagram PER domain/environment.

            Return a JSON array: [{"title": "Domain Name", "mermaid": "graph TD\\n..."}]

            Rules per diagram:
            - Use `graph TD`, subgraph per environment
            - Services, databases, caches as separate nodes
            - Label connections with protocols
            - Max 15 nodes per diagram

            Return ONLY valid JSON array, no markdown, no explanation.
            """
    ]

    var hasAPIKey: Bool { apiKey != nil && !(apiKey?.isEmpty ?? true) }

    init(apiKey: String? = nil) {
        self.apiKey = apiKey ?? Self.loadKeyFromKeychain()
    }

    func updateAPIKey(_ key: String?) {
        self.apiKey = key
    }

    // MARK: - Extraction via Tool Use (SGR)

    struct ExtractionResponse {
        let result: BlockExtractionResult
        let inputTokens: Int
        let outputTokens: Int
    }

    /// Extract semantics from markdown content using Claude Tool Use.
    /// Sends the FULL content (split into chunks if needed), gets structured JSON back via tool call.
    func extractBlockSemantics(blockContent: String, jobType: AIJobType) async throws -> ExtractionResponse {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            throw AIProviderError.noAPIKey
        }

        // 100K chars ≈ 25K tokens. Split only truly huge files.
        let chunks = splitIntoChunks(blockContent, maxChars: 100000)

        // Process ALL chunks in PARALLEL
        let chunkResults = try await withThrowingTaskGroup(of: (BlockExtractionResult, Int, Int).self) { group in
            for (i, chunk) in chunks.enumerated() {
                group.addTask {
                    try await self.extractSingleChunk(chunk: chunk, index: i, total: chunks.count)
                }
            }
            var results: [(BlockExtractionResult, Int, Int)] = []
            for try await result in group { results.append(result) }
            return results
        }

        // Merge all chunk results
        var mergedResult = BlockExtractionResult(entities: [], claims: [], relations: [], temporalContexts: [], transitions: [])
        var totalInput = 0
        var totalOutput = 0
        for (result, inp, out) in chunkResults {
            mergedResult.entities = (mergedResult.entities ?? []) + (result.entities ?? [])
            mergedResult.claims = (mergedResult.claims ?? []) + (result.claims ?? [])
            mergedResult.relations = (mergedResult.relations ?? []) + (result.relations ?? [])
            mergedResult.temporalContexts = (mergedResult.temporalContexts ?? []) + (result.temporalContexts ?? [])
            totalInput += inp
            totalOutput += out
        }

        return ExtractionResponse(result: mergedResult, inputTokens: totalInput, outputTokens: totalOutput)
    }

    /// Process a single chunk — called in parallel from extractBlockSemantics
    private func extractSingleChunk(chunk: String, index: Int, total: Int) async throws -> (BlockExtractionResult, Int, Int) {
        guard let apiKey = apiKey else { throw AIProviderError.noAPIKey }
        let chunkLabel = total > 1 ? " (part \(index+1)/\(total))" : ""

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16384,
            "system": """
                Extract entities and claims from technical documentation. Return ONLY valid JSON.
                {"entities":[...],"claims":[...],"relations":[]}
                Entity: {"id":"ent_xxx","name":"...","type":"Service|System|Component|API|Database|Queue|Event|Team|Environment|Phase","canonicalName":"...","description":"..."}
                Claim (MANDATORY): {"id":"clm_xxx","type":"Definition|Decision|Constraint|Requirement|Assumption|Risk|CurrentState|TargetState","subjectEntityId":"ent_xxx","predicate":"uses|depends_on|stores|calls|requires|owns","object":"what","rawText":"original sentence","confidence":0.9}
                Relation: {"id":"rel_xxx","sourceId":"ent_xxx","targetId":"ent_yyy","type":"uses|depends_on|stores|calls"}
                IMPORTANT: Every factual statement is a claim. You MUST return claims.\(chunkLabel)
                """,
            "messages": [["role": "user", "content": chunk]]
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = data
        request.timeoutInterval = 180

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw AIProviderError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw AIProviderError.parseError("Invalid JSON")
        }

        let usage = json["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0

        if let content = json["content"] as? [[String: Any]] {
            for block in content {
                if let text = block["text"] as? String {
                    let jsonText = extractJSON(from: text)
                    if let jsonData = jsonText.data(using: .utf8) {
                        do {
                            let result = try JSONDecoder().decode(BlockExtractionResult.self, from: jsonData)
                            NSLog("[AIProvider] Chunk \(index+1)/\(total): \(result.safeEntities.count) entities, \(result.safeClaims.count) claims")
                            return (result, inputTokens, outputTokens)
                        } catch {
                            NSLog("[AIProvider] JSON decode error chunk \(index+1): \(error). Raw: \(jsonText.prefix(200))")
                        }
                    }
                }
            }
        }

        return (BlockExtractionResult(entities: [], claims: [], relations: [], temporalContexts: [], transitions: []), inputTokens, outputTokens)
    }

    // MARK: - Tool Schema (SGR)

    /// The tool definition for structured extraction — Claude returns data matching this schema
    private var extractionToolSchema: [String: Any] {
        [
            "name": "extract_semantics",
            "description": "Extract entities, claims, and relations from technical documentation",
            "input_schema": [
                "type": "object",
                "properties": [
                    "entities": [
                        "type": "array",
                        "description": "Technical entities found in the text",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string", "description": "Unique ID like ent_xxx"],
                                "name": ["type": "string", "description": "Entity name"],
                                "type": ["type": "string", "enum": ["System","Service","Component","API","Event","Database","Queue","Team","Environment","Phase"]],
                                "canonicalName": ["type": "string", "description": "Normalized name"],
                                "aliases": ["type": "array", "items": ["type": "string"]],
                                "description": ["type": "string", "description": "Brief description"]
                            ],
                            "required": ["id", "name", "type", "canonicalName"]
                        ]
                    ],
                    "claims": [
                        "type": "array",
                        "description": "Factual claims and decisions stated in the text",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "type": ["type": "string", "enum": ["Definition","Decision","Constraint","Requirement","Assumption","Risk","OwnershipClaim","StatusClaim","CurrentState","TargetState"]],
                                "subjectEntityId": ["type": "string", "description": "ID of the entity this claim is about"],
                                "predicate": ["type": "string", "description": "What is being stated: uses, depends_on, owns, etc."],
                                "object": ["type": "string", "description": "The object of the claim"],
                                "rawText": ["type": "string", "description": "The original sentence from the document"],
                                "confidence": ["type": "number", "description": "0.0 to 1.0"],
                                "lineNumber": ["type": "integer", "description": "Approximate line number in the source document"]
                            ],
                            "required": ["id", "type", "rawText"]
                        ]
                    ],
                    "relations": [
                        "type": "array",
                        "description": "Relationships between entities",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "sourceId": ["type": "string", "description": "Source entity ID"],
                                "targetId": ["type": "string", "description": "Target entity ID"],
                                "type": ["type": "string", "enum": ["depends_on","uses","owns","publishes","consumes","stores","supersedes","conflicts_with","references","calls","deployed_in"]]
                            ],
                            "required": ["id", "sourceId", "targetId", "type"]
                        ]
                    ],
                    "temporalContexts": [
                        "type": "array",
                        "description": "Phases, milestones, versions mentioned",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "label": ["type": "string"],
                                "kind": ["type": "string", "enum": ["phase","milestone","release","version"]],
                                "orderIndex": ["type": "integer"]
                            ],
                            "required": ["id", "label", "kind"]
                        ]
                    ]
                ],
                "required": ["entities", "claims", "relations"]
            ]
        ]
    }

    // MARK: - Chunking

    /// Split content into chunks, breaking at paragraph boundaries
    private func splitIntoChunks(_ content: String, maxChars: Int) -> [String] {
        guard content.count > maxChars else { return [content] }

        var chunks: [String] = []
        var current = ""

        for paragraph in content.components(separatedBy: "\n\n") {
            if current.count + paragraph.count + 2 > maxChars && !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n\n" }
            current += paragraph
        }
        if !current.isEmpty { chunks.append(current) }

        return chunks
    }

    // MARK: - Fallback JSON extraction (for text responses)

    private func extractJSON(from text: String) -> String {
        if let range = text.range(of: "```json\n"),
           let endRange = text.range(of: "\n```", range: range.upperBound..<text.endIndex) {
            return String(text[range.upperBound..<endRange.lowerBound])
        }
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }

    // MARK: - Mermaid Diagram Generation (uses Opus 4.6 for quality)

    private let diagramModel = "claude-opus-4-6"

    static func defaultDiagramPrompt(for mode: String) -> String {
        defaultDiagramPrompts[mode] ?? defaultDiagramPrompts["software"]!
    }

    struct DiagramResult {
        let title: String
        let mermaid: String
    }

    /// Strip markdown code fences from mermaid code
    static func stripMermaidFences(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("```") {
            s = String(s.drop(while: { $0 != "\n" }).dropFirst())
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while s.hasSuffix("```") {
            s = String(s.dropLast(3))
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Generate multiple Mermaid diagrams (one per system/domain). Uses Opus + SGR (Tool Use) for structured output.
    func generateMermaidDiagrams(
        mode: String,
        entitiesSummary: String,
        claimsSummary: String,
        customPrompt: String? = nil
    ) async throws -> [DiagramResult] {
        guard let apiKey = apiKey, !apiKey.isEmpty else { throw AIProviderError.noAPIKey }
        let trimmedPrompt = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = (trimmedPrompt?.isEmpty == false)
            ? trimmedPrompt!
            : Self.defaultDiagramPrompt(for: mode)

        // SGR tool schema for structured diagram output
        let tool: [String: Any] = [
            "name": "generate_diagrams",
            "description": "Generate architecture diagrams as Mermaid.js flowcharts. Each diagram must start with 'graph TD' or 'graph LR'. Node IDs must be alphanumeric/underscore only. Labels in square brackets [].",
            "input_schema": [
                "type": "object",
                "properties": [
                    "diagrams": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string", "description": "Short descriptive title for this diagram"],
                                "mermaid": ["type": "string", "description": "Complete Mermaid.js code starting with 'graph TD'. Node IDs: alphanumeric+underscore only. Labels in []. Edges: -->. subgraph/end for grouping. classDef for colors."]
                            ],
                            "required": ["title", "mermaid"]
                        ]
                    ]
                ],
                "required": ["diagrams"]
            ]
        ]

        let body: [String: Any] = [
            "model": diagramModel,
            "max_tokens": 16384,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": "Entities:\n\(entitiesSummary)\n\nClaims:\n\(claimsSummary)"]
            ],
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "generate_diagrams"]
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = data
        request.timeoutInterval = 180

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw AIProviderError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]] else {
            throw AIProviderError.parseError("No content in response")
        }

        // Track cost (Opus: $15/1M in, $75/1M out)
        if let usage = json["usage"] as? [String: Any] {
            let inp = usage["input_tokens"] as? Int ?? 0
            let out = usage["output_tokens"] as? Int ?? 0
            // Cost tracking is done at a higher level if needed
            NSLog("[AIProvider] Diagram generation: \(inp) in, \(out) out tokens")
        }

        // Parse tool_use response
        var results: [DiagramResult] = []
        for block in contentBlocks {
            if block["type"] as? String == "tool_use",
               let input = block["input"] as? [String: Any],
               let diagrams = input["diagrams"] as? [[String: Any]] {
                for diagram in diagrams {
                    let title = diagram["title"] as? String ?? "Diagram"
                    var mermaid = diagram["mermaid"] as? String ?? ""
                    mermaid = Self.stripMermaidFences(mermaid)
                    if !mermaid.isEmpty {
                        results.append(DiagramResult(title: title, mermaid: mermaid))
                    }
                }
            }
        }

        return results
    }

    // MARK: - Architecture Graph Generation (legacy — kept for backward compat)

    func generateArchitecture(mode: String, entitiesSummary: String, claimsSummary: String) async throws -> String {
        guard let apiKey = apiKey, !apiKey.isEmpty else { throw AIProviderError.noAPIKey }

        let prompts: [String: String] = [
            "software": "You are a software architect. Build a SOFTWARE ARCHITECTURE diagram as JSON from the given entities and claims. Return JSON with: title, groups (nested: system→services→components), connections (from, to, label, style). Group by domain. Max 25 nodes.",
            "dataflow": "You are a data architect. Build a DATA FLOW diagram as JSON. Return JSON with: title, nodes (name, type, layer 0-3), flows (from, to, label). Layer 0=sources, 1=processing, 2=queues, 3=storage.",
            "deployment": "You are a DevOps architect. Build a DEPLOYMENT diagram as JSON. Return JSON with: title, environments (name, type, services[], infrastructure[]), connections."
        ]

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": prompts[mode] ?? prompts["software"]!,
            "messages": [
                ["role": "user", "content": "Entities:\n\(entitiesSummary)\n\nClaims:\n\(claimsSummary)"]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = data
        request.timeoutInterval = 60

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw AIProviderError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw AIProviderError.parseError("No text in response")
        }

        return extractJSON(from: text)
    }

    // MARK: - Key Storage

    private static let storageKey = "com.markview.dde.apikey"

    static func loadKeyFromKeychain() -> String? {
        UserDefaults.standard.string(forKey: storageKey)
    }

    static func saveKeyToKeychain(_ key: String) {
        UserDefaults.standard.set(key, forKey: storageKey)
    }
}

enum AIProviderError: Error, LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(Int, String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .invalidResponse: return "Invalid response from API"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .parseError(let msg): return "Parse error: \(msg)"
        }
    }
}
