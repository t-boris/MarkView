import Foundation

/// Ollama local LLM client — used for module extraction, classification, and analysis.
/// Free, private, no API tokens needed. Requires Ollama running at localhost:11434.
@MainActor
class OllamaClient: ObservableObject {
    @Published var isConnected = false
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = "llama3.2:3b"

    static let baseURL = "http://localhost:11434"

    // MARK: - Connection Check

    func checkConnection() async {
        WorkspaceManager.debugLog("[Ollama] checkConnection starting...")
        do {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "\(Self.baseURL)/api/tags")!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            WorkspaceManager.debugLog("[Ollama] HTTP \(status), data: \(data.count) bytes")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                availableModels = models.compactMap { $0["name"] as? String }
                isConnected = true
                if !availableModels.contains(selectedModel), let first = availableModels.first {
                    selectedModel = first
                }
                WorkspaceManager.debugLog("[Ollama] Connected: \(availableModels.count) models")
            } else {
                WorkspaceManager.debugLog("[Ollama] Failed to parse response")
                isConnected = false
            }
        } catch {
            isConnected = false
            WorkspaceManager.debugLog("[Ollama] Not available: \(error.localizedDescription)")
        }
    }

    // MARK: - Generate (non-streaming)

    func generate(prompt: String, system: String? = nil) async -> String? {
        var body: [String: Any] = [
            "model": selectedModel,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 4096]
        ]
        if let system = system { body["system"] = system }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/generate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 120

        do {
            let (responseData, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let response = json["response"] as? String else { return nil }
            return response
        } catch {
            NSLog("[Ollama] Generate error: \(error)")
            return nil
        }
    }

    // MARK: - Structured Extraction (JSON mode)

    func extractJSON(prompt: String, system: String) async -> [[String: Any]]? {
        var body: [String: Any] = [
            "model": selectedModel,
            "prompt": prompt,
            "system": system,
            "stream": false,
            "format": "json",
            "options": ["temperature": 0.0, "num_predict": 4096]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/generate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 120

        do {
            let (responseData, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let response = json["response"] as? String else { return nil }

            // Parse the JSON response
            guard let jsonData = response.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }

            // Handle both {"components": [...]} and direct [...]
            if let components = parsed["components"] as? [[String: Any]] {
                return components
            }
            return nil
        } catch {
            NSLog("[Ollama] Extract error: \(error)")
            return nil
        }
    }

    // MARK: - Module Extraction Prompt

    static let extractionSystemPrompt = """
    You are a document analyzer. Extract ALL named components, concepts, and entities from the text.
    The document may be about software, business, trading, finance, or any domain.

    Return JSON with this exact structure:
    {"components": [{"name": "ComponentName", "type": "type", "description": "one sentence"}]}

    Valid types for SOFTWARE: service, database, api, queue, system, library, tool, framework, protocol, storage, cache, gateway, worker, scheduler, proxy, broker, sdk, platform, infrastructure, monitoring, testing, module, pipeline, classifier, resolver, analyzer, generator, processor

    Valid types for BUSINESS: process, strategy, stakeholder, regulation, metric, kpi, workflow, department, policy, objective, initiative, capability

    Valid types for TRADING/FINANCE: instrument, portfolio, strategy, risk, indicator, signal, exchange, broker, algorithm, model, fund, asset, position, order

    Valid types for GENERIC: concept, entity, relationship, document, template, checklist, milestone, resource, constraint, assumption, decision

    Extract EVERY named component. Be thorough. The document may be in any language.
    """
}
