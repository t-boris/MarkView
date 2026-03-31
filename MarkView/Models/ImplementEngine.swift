import Foundation

/// Controlled implementation engine — generates diffs, shows preview, applies only on explicit approval
@MainActor
class ImplementEngine: ObservableObject {
    @Published var isProcessing = false
    @Published var currentStep: String?
    @Published var steps: [ChangeStep] = []

    let db: SemanticDatabase
    let providerClient: AIProviderClient

    init(db: SemanticDatabase, providerClient: AIProviderClient) {
        self.db = db
        self.providerClient = providerClient
    }

    struct ChangeStep: Identifiable {
        let id = UUID()
        let filePath: String
        let description: String
        let original: String
        let proposed: String
        var status: StepStatus = .pending
    }

    enum StepStatus {
        case pending, approved, skipped, applied, failed(String)
    }

    // MARK: - Plan Change

    /// Generate a change plan from user description
    func planChange(moduleId: String, description: String, workspacePath: URL) async -> [ChangeStep] {
        guard let apiKey = providerClient.apiKeyValue else { return [] }
        isProcessing = true; currentStep = "Analyzing module..."
        defer { isProcessing = false; currentStep = nil }

        // Gather module context
        let modules = db.allModules()
        guard let mod = modules.first(where: { $0.id == moduleId }) else { return [] }

        let symbols = db.symbolsForModule(moduleId)
        let rels = db.relationsForModule(moduleId)

        // Read actual files
        var fileContents: [(name: String, content: String)] = []
        let dirURL = URL(fileURLWithPath: mod.path)
        if let files = try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "md" {
                if let content = try? String(contentsOf: file, encoding: .utf8) {
                    fileContents.append((file.lastPathComponent, String(content.prefix(4000))))
                }
            }
        }

        let filesContext = fileContents.map { "--- \($0.name) ---\n\($0.content)" }.joined(separator: "\n\n")

        currentStep = "Generating change plan..."

        let prompt = """
        You are a technical writer. Generate a change plan for the following modification.

        Module: \(mod.name) (\(mod.path))
        Headings: \(symbols.filter { $0.kind == "heading" }.map { $0.name }.joined(separator: ", "))
        Links: \(rels.map { "\($0.type): \($0.targetId)" }.joined(separator: ", "))

        Change requested: \(description)

        Current files:
        \(filesContext)

        For each file that needs changes, return a JSON array:
        [{"file": "filename.md", "description": "what to change", "original": "exact text to replace", "proposed": "new text"}]

        Rules:
        - Only modify files that actually need changes
        - "original" must be an EXACT substring from the current file
        - "proposed" is the replacement text
        - Keep changes minimal and focused
        - Return ONLY the JSON array, no explanation

        If no changes needed, return []
        """

        do {
            let body: [String: Any] = [
                "model": "claude-sonnet-4-6",
                "max_tokens": 8192,
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

            let (responseData, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else { return [] }

            // Track cost
            if let usage = json["usage"] as? [String: Any] {
                let inp = usage["input_tokens"] as? Int ?? 0
                let out = usage["output_tokens"] as? Int ?? 0
                db.addUsage(inputTokens: inp, outputTokens: out, costCents: Double(inp) * 0.0003 + Double(out) * 0.0015)
            }

            // Parse JSON array from response
            let jsonText = extractJSON(from: text)
            guard let jsonData = jsonText.data(using: .utf8),
                  let changes = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: String]] else {
                return []
            }

            steps = changes.compactMap { change in
                guard let file = change["file"],
                      let desc = change["description"],
                      let original = change["original"],
                      let proposed = change["proposed"] else { return nil }
                let fullPath = dirURL.appendingPathComponent(file).path
                return ChangeStep(filePath: fullPath, description: desc, original: original, proposed: proposed)
            }

            // Save plan to DB
            let planId = "plan_\(UUID().uuidString.prefix(8))"
            let stepsJSON = try? JSONSerialization.data(withJSONObject: changes)
            let stepsStr = stepsJSON.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            try? db.execute_raw("INSERT INTO change_plans (plan_id, module_id, description, steps_json, status, created_at) VALUES (?, ?, ?, ?, 'draft', ?)",
                               text: planId) // Simplified — would need proper multi-param

            return steps
        } catch {
            NSLog("[ImplementEngine] Error: \(error)")
            return []
        }
    }

    // MARK: - Apply Step

    /// Apply a single approved change step
    func applyStep(at index: Int) -> Bool {
        guard index < steps.count else { return false }
        let step = steps[index]

        guard let content = try? String(contentsOfFile: step.filePath, encoding: .utf8) else {
            steps[index].status = .failed("Cannot read file")
            return false
        }

        guard content.contains(step.original) else {
            steps[index].status = .failed("Original text not found in file")
            return false
        }

        let newContent = content.replacingOccurrences(of: step.original, with: step.proposed)

        do {
            try newContent.write(toFile: step.filePath, atomically: true, encoding: .utf8)
            steps[index].status = .applied
            return true
        } catch {
            steps[index].status = .failed(error.localizedDescription)
            return false
        }
    }

    func skipStep(at index: Int) {
        guard index < steps.count else { return }
        steps[index].status = .skipped
    }

    private func extractJSON(from text: String) -> String {
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]") {
            return String(text[start...end])
        }
        return text
    }
}
