import Foundation

/// Test generation engine — analyzes module structure, finds untested components, generates tests
@MainActor
class TestGenerator: ObservableObject {
    @Published var isGenerating = false
    @Published var generatedTests: [GeneratedTest] = []

    let db: SemanticDatabase
    let providerClient: AIProviderClient

    init(db: SemanticDatabase, providerClient: AIProviderClient) {
        self.db = db
        self.providerClient = providerClient
    }

    struct GeneratedTest: Identifiable {
        let id = UUID()
        let fileName: String
        let content: String
        let targetModule: String
        let testType: String  // unit, integration, contract
        var status: TestStatus = .preview
    }

    enum TestStatus { case preview, saved, skipped }

    // MARK: - Generate

    /// Generate tests for a module
    func generateTests(moduleId: String, workspacePath: URL) async -> [GeneratedTest] {
        guard let apiKey = providerClient.apiKeyValue else { return [] }
        isGenerating = true
        defer { isGenerating = false }

        let modules = db.allModules()
        guard let mod = modules.first(where: { $0.id == moduleId }) else { return [] }

        let symbols = db.symbolsForModule(moduleId)
        let rels = db.relationsForModule(moduleId)

        // Find existing test files
        let dirURL = URL(fileURLWithPath: mod.path)
        let fm = FileManager.default
        var existingTests: [String] = []
        var sourceFiles: [(name: String, content: String)] = []

        if let files = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
            for file in files {
                let name = file.lastPathComponent.lowercased()
                if name.contains("test") || name.contains("spec") {
                    existingTests.append(file.lastPathComponent)
                } else if file.pathExtension.lowercased() == "md" {
                    if let content = try? String(contentsOf: file, encoding: .utf8) {
                        sourceFiles.append((file.lastPathComponent, String(content.prefix(3000))))
                    }
                }
            }
        }

        let headings = symbols.filter { $0.kind == "heading" }.map { $0.name }
        let dependencies = rels.map { "\($0.type): \($0.targetId)" }

        let prompt = """
        You are a QA engineer. Analyze this module and generate test specifications.

        Module: \(mod.name)
        Headings (components): \(headings.joined(separator: ", "))
        Dependencies: \(dependencies.joined(separator: ", "))
        Existing tests: \(existingTests.isEmpty ? "None" : existingTests.joined(separator: ", "))

        Source files:
        \(sourceFiles.map { "--- \($0.name) ---\n\($0.content)" }.joined(separator: "\n\n"))

        Generate test specifications as a JSON array:
        [{"fileName": "test_xxx.md", "testType": "unit|integration|contract", "content": "# Test: ...\\n\\n## Test Cases\\n..."}]

        Rules:
        - Generate markdown test specs, not code
        - Include: test name, preconditions, steps, expected results
        - Cover: main functionality, edge cases, error handling
        - testType: unit (single component), integration (component interactions), contract (API boundaries)
        - Return ONLY JSON array
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

            // Parse
            let jsonText = text.contains("[") ? String(text[text.firstIndex(of: "[")!...text.lastIndex(of: "]")!]) : "[]"
            guard let jsonData = jsonText.data(using: .utf8),
                  let tests = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: String]] else { return [] }

            generatedTests = tests.compactMap { t in
                guard let name = t["fileName"], let type = t["testType"], let content = t["content"] else { return nil }
                return GeneratedTest(fileName: name, content: content, targetModule: mod.name, testType: type)
            }

            return generatedTests
        } catch {
            NSLog("[TestGenerator] Error: \(error)")
            return []
        }
    }

    // MARK: - Save

    /// Save a generated test to disk
    func saveTest(at index: Int, to directory: URL) -> Bool {
        guard index < generatedTests.count else { return false }
        let test = generatedTests[index]
        let fileURL = directory.appendingPathComponent(test.fileName)

        do {
            try test.content.write(to: fileURL, atomically: true, encoding: .utf8)
            generatedTests[index].status = .saved
            return true
        } catch {
            return false
        }
    }
}
