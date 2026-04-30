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

    /// Internal accessor used by sibling models (e.g. `ActionEngine`) that need to redact the
    /// in-memory key value from log/error strings without re-reading the keychain. Never expose
    /// publicly — kept `internal` because it is only meant for sanitization helpers.
    internal var apiKeySnapshot: String? { return apiKey }

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

    // MARK: - Streaming (Anthropic SSE)

    /// Maximum size of a single SSE line. Per tech-spec Decision 10 §7 — protects against a
    /// pathological/oversized response line buffering unboundedly in memory. Enforced at the
    /// byte level, before the line is fully accumulated, so a hostile server cannot OOM us
    /// by sending one giant unterminated line.
    private static let maxSSELineBytes = 65_536            // 64 KB
    /// Maximum accumulated payload across multi-line `data:` field continuation per SSE spec.
    /// Per tech-spec Decision 10 §7 — bounds memory per event regardless of line count.
    private static let maxSSEEventBytes = 1 * 1024 * 1024  // 1 MB
    private static let maxErrorBodyBytes = 16 * 1024       // 16 KB cap when reading HTTP-error body

    /// Sample SSE event handled by this parser:
    /// ```
    /// event: content_block_delta
    /// data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
    /// ```
    /// Stream Anthropic Messages API completions via SSE. Calls `onDelta` for each text delta.
    /// Returns normally on `message_stop` (or when the underlying byte stream ends without one).
    /// Throws `AIProviderError.streamingError` for `event: error`, oversized SSE lines, or
    /// `AIProviderError.httpError` for non-200 responses (mirrors `extractSingleChunk` shape).
    /// `onDelta` is invoked off-main; caller is responsible for marshalling to its own actor.
    /// `onDelta` is non-throwing by design. Callers that need to abort mid-stream should call
    /// `Task.cancel()` on the wrapping task; cancellation is observed between SSE lines and
    /// exits cleanly within ~1s.
    func streamCompletion(
        systemPrompt: String,
        userMessage: String,
        model: String = "claude-sonnet-4-6",
        maxTokens: Int = 8192,
        onDelta: @escaping (String) -> Void
    ) async throws {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            throw AIProviderError.noAPIKey
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]],
            "stream": true
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = data
        request.timeoutInterval = 600   // streams may run long; rely on TCP-level timeouts

        let (bytes, response) = try await session.bytes(for: request)

        // HTTP guard — drain a bounded body for diagnostics, then throw.
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var errorBody = Data()
            do {
                for try await byte in bytes {
                    if errorBody.count >= Self.maxErrorBodyBytes { break }
                    errorBody.append(byte)
                }
            } catch {
                // ignore — we already have the status; surface what we collected so far.
            }
            let bodyString = String(data: errorBody, encoding: .utf8) ?? ""
            throw AIProviderError.httpError(status, sanitize(bodyString))
        }

        // SSE parser: accumulate `event:` and `data:` (multi-line allowed per spec) until a
        // blank line dispatches the event. Keepalive-comments (`:` lines) and empty lines
        // outside an event reset the state cleanly.
        //
        // DoS hardening (Decision 10 §7): we MUST NOT use `bytes.lines` here — that
        // AsyncSequence buffers an arbitrary-length line into memory before yielding, so a
        // post-yield size check is too late. Instead iterate raw bytes, enforce the 64 KB
        // line cap as bytes arrive, and enforce a 1 MB cap on accumulated multi-line
        // `data:` payloads.
        var currentEvent: String = ""
        var dataBuffer: String = ""
        var lineBuf: [UInt8] = []
        lineBuf.reserveCapacity(4096)

        do {
            for try await byte in bytes {
                if byte == 0x0A {  // LF — end of line
                    // Strip a trailing CR for CRLF line endings.
                    if let last = lineBuf.last, last == 0x0D {
                        lineBuf.removeLast()
                    }
                    let line = String(decoding: lineBuf, as: UTF8.self)
                    lineBuf.removeAll(keepingCapacity: true)

                    try Task.checkCancellation()

                    if try processSSELine(
                        line,
                        currentEvent: &currentEvent,
                        dataBuffer: &dataBuffer,
                        onDelta: onDelta
                    ) {
                        return  // message_stop — clean exit
                    }
                } else {
                    if lineBuf.count >= Self.maxSSELineBytes {
                        throw AIProviderError.streamingError("SSE line exceeds 64 KB cap")
                    }
                    lineBuf.append(byte)
                }
            }

            // EOF without trailing blank line: dispatch any pending event so the final
            // frame is not silently dropped (SSE spec allows EOF-as-terminator).
            if !lineBuf.isEmpty {
                let line = String(decoding: lineBuf, as: UTF8.self)
                lineBuf.removeAll(keepingCapacity: true)
                _ = try processSSELine(
                    line,
                    currentEvent: &currentEvent,
                    dataBuffer: &dataBuffer,
                    onDelta: onDelta
                )
            }
            if !currentEvent.isEmpty || !dataBuffer.isEmpty {
                _ = try handleSSEEvent(event: currentEvent, data: dataBuffer, onDelta: onDelta)
            }
        } catch let error as AIProviderError {
            throw error
        } catch is CancellationError {
            // Cooperative cancellation — return normally, caller's Task is already cancelled.
            return
        } catch {
            // Network / decode-from-bytes errors — surface sanitized.
            throw AIProviderError.streamingError(sanitize(String(describing: error)))
        }

        // Stream ended without `message_stop` (EOF or cancellation). Both are valid for caller.
    }

    /// Process a single (already line-bounded, ≤64 KB) SSE line. Mutates the parser state and
    /// returns `true` when an event dispatch indicates the stream is complete (`message_stop`).
    private func processSSELine(
        _ line: String,
        currentEvent: inout String,
        dataBuffer: inout String,
        onDelta: (String) -> Void
    ) throws -> Bool {
        // Empty line → dispatch accumulated event.
        if line.isEmpty {
            if !currentEvent.isEmpty || !dataBuffer.isEmpty {
                if try handleSSEEvent(event: currentEvent, data: dataBuffer, onDelta: onDelta) {
                    return true
                }
            }
            currentEvent = ""
            dataBuffer = ""
            return false
        }

        // SSE comment (keepalive) — line starts with `:`.
        if line.hasPrefix(":") {
            return false
        }

        if line.hasPrefix("event:") {
            currentEvent = String(line.dropFirst("event:".count))
                .trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            let chunk = String(line.dropFirst("data:".count))
                .trimmingCharacters(in: .whitespaces)
            // Per-event payload cap — bounds memory across multi-line `data:` accumulation.
            let projected = dataBuffer.utf8.count
                + (dataBuffer.isEmpty ? 0 : 1)  // joining "\n"
                + chunk.utf8.count
            if projected > Self.maxSSEEventBytes {
                throw AIProviderError.streamingError("SSE event payload exceeds 1 MB cap")
            }
            if dataBuffer.isEmpty {
                dataBuffer = chunk
            } else {
                dataBuffer += "\n" + chunk
            }
        }
        // Any other field (id:, retry:, …) — ignore per SSE spec & forward compat.
        return false
    }

    /// Dispatch a single fully-accumulated SSE event. Returns `true` if the stream should end
    /// normally (i.e. `message_stop`).
    private func handleSSEEvent(event: String, data: String, onDelta: (String) -> Void) throws -> Bool {
        // Anthropic always sends an `event:` line, so an empty event name lands in the
        // silent-ignore branch below (forward-compat with future spec relaxations).
        let trimmedEvent = event.trimmingCharacters(in: .whitespaces)

        switch trimmedEvent {
        case "content_block_delta":
            guard let payload = parseJSONObject(data) else {
                NSLog("[AIProvider] SSE parse warning: malformed content_block_delta payload (skipped)")
                return false
            }
            if let delta = payload["delta"] as? [String: Any],
               (delta["type"] as? String) == "text_delta",
               let text = delta["text"] as? String {
                onDelta(text)
            }
            return false

        case "message_stop":
            return true

        case "error":
            let payload = parseJSONObject(data)
            let message = (payload?["error"] as? [String: Any])?["message"] as? String
                ?? (payload?["message"] as? String)
                ?? "unknown error"
            throw AIProviderError.streamingError(sanitize(message))

        case "ping", "message_delta", "message_start",
             "content_block_start", "content_block_stop", "":
            // Silent ignore — keepalives / lifecycle events not relevant to text assembly.
            return false

        default:
            // Forward-compat: unknown event names are ignored silently.
            return false
        }
    }

    /// Parse a JSON object from a raw `data:` payload string. Returns nil on failure.
    private func parseJSONObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Strip the API key (if any) from a string before it is thrown, logged, or returned.
    /// Applied to every error-path string to satisfy the invariant: API key never leaks.
    private func sanitize(_ msg: String) -> String {
        guard let key = apiKey, !key.isEmpty else { return msg }
        return msg.replacingOccurrences(of: key, with: "[REDACTED]")
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
    case streamingError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .invalidResponse: return "Invalid response from API"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .parseError(let msg): return "Parse error: \(msg)"
        // The `msg` payload here is produced by `AIProviderClient.sanitize(_:)` before being
        // attached to this case — see Models/AIProviderClient.swift `streamCompletion`. Do not
        // include any value here that could re-introduce the API key.
        case .streamingError(let msg): return "Streaming error: \(msg.prefix(200))"
        }
    }
}
