import Foundation

// MARK: - Typed AI Operation & JSON Salvage (AR-26)

/// Lifecycle stage of a typed `AIOperation` (`AR-26`).
enum AIOperationStage: Equatable, Sendable {
    case preparing
    case running(String)
    case validating
    case repairing(attempt: Int)
    case completed
    case failed(String)
}

/// Errors emitted by `AIOperation` and `AIJSONSalvage` (`AR-26`).
enum AIOperationError: LocalizedError, Equatable {
    case emptyResponse(String)
    case decodingFailed(operation: String, detail: String)
    case validationFailed(operation: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse(let op):
            return "\(op) returned an empty response."
        case .decodingFailed(let op, let detail):
            return "\(op) failed to decode structured JSON output: \(detail)"
        case .validationFailed(let op, let reason):
            return "\(op) output failed validation: \(reason)"
        }
    }
}

/// Salvages and decodes JSON payloads from raw assistant text or pre-parsed structured objects (`AR-26`).
enum AIJSONSalvage {
    /// Extract the JSON payload from markdown code fences (` ```json ... ``` `) or the outermost `{...}` / `[...]` span.
    static func extractJSONString(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // 1. Check for ```json ... ``` or ``` ... ``` fenced blocks
        if let fenceRange = trimmed.range(of: #"```(?:json)?\s*\n([\s\S]*?)\n```"#, options: .regularExpression) {
            let fenced = String(trimmed[fenceRange])
            let lines = fenced.components(separatedBy: "\n")
            if lines.count >= 2 {
                let inner = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { return inner }
            }
        }

        // 2. Find outermost balanced-looking JSON object or array
        let objStart = trimmed.firstIndex(of: "{")
        let arrStart = trimmed.firstIndex(of: "[")
        let startIdx: String.Index?
        let closingChar: Character
        switch (objStart, arrStart) {
        case let (o?, a?):
            if o < a { startIdx = o; closingChar = "}" }
            else { startIdx = a; closingChar = "]" }
        case let (o?, nil):
            startIdx = o; closingChar = "}"
        case let (nil, a?):
            startIdx = a; closingChar = "]"
        case (nil, nil):
            return trimmed
        }

        if let start = startIdx, let end = trimmed.lastIndex(of: closingChar), start <= end {
            return String(trimmed[start...end])
        }
        return trimmed
    }

    /// Decode `Output` from either `structured` (`JSONSerialization` object) or `raw` text.
    static func decode<Output: Decodable>(
        _ type: Output.Type,
        from raw: String,
        structured: Any? = nil,
        operation: String = "AIOperation",
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Output {
        if let structured, JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let decoded = try? decoder.decode(Output.self, from: data) {
            return decoded
        }

        let extracted = extractJSONString(from: raw)
        guard !extracted.isEmpty else {
            throw AIOperationError.emptyResponse(operation)
        }
        guard let data = extracted.data(using: .utf8) else {
            throw AIOperationError.decodingFailed(operation: operation, detail: "Invalid UTF-8 encoding")
        }
        do {
            return try decoder.decode(Output.self, from: data)
        } catch {
            throw AIOperationError.decodingFailed(operation: operation, detail: error.localizedDescription)
        }
    }
}

/// Typed, cancellable, schema-validated AI operation runner (`AR-26`).
///
/// Centralises prompt construction, CLI invocation, JSON fence/brace salvage, `Decodable` parsing,
/// domain validation, bounded repair retries, and activity stage reporting.
struct AIOperation<Input, Output: Decodable> {
    typealias Runner = (CLICompletion.Request, (@Sendable (CLICompletion.Activity) -> Void)?) async throws -> CLICompletion.Result

    let name: String
    let maxRepairAttempts: Int
    let buildRequest: (Input) -> CLICompletion.Request
    let validate: ((Input, Output) throws -> Void)?
    let repairPrompt: ((Input, String, Error) -> String)?
    let runner: Runner

    init(
        name: String,
        maxRepairAttempts: Int = 1,
        buildRequest: @escaping (Input) -> CLICompletion.Request,
        validate: ((Input, Output) throws -> Void)? = nil,
        repairPrompt: ((Input, String, Error) -> String)? = nil,
        runner: @escaping Runner = { req, onActivity in try await CLICompletion.run(req, onActivity: onActivity) }
    ) {
        self.name = name
        self.maxRepairAttempts = max(0, maxRepairAttempts)
        self.buildRequest = buildRequest
        self.validate = validate
        self.repairPrompt = repairPrompt
        self.runner = runner
    }

    /// Execute the operation with automatic JSON salvage and up to `maxRepairAttempts` repair retries.
    func execute(
        _ input: Input,
        onStage: (@Sendable (AIOperationStage) -> Void)? = nil
    ) async throws -> (output: Output, result: CLICompletion.Result) {
        try Task.checkCancellation()
        onStage?(.preparing)

        var currentRequest = buildRequest(input)
        if currentRequest.label.isEmpty {
            currentRequest.label = name
        }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            onStage?(.running(attempt == 0 ? "Running \(name)" : "Repairing \(name) (attempt \(attempt))"))

            let result = try await runner(currentRequest) { activity in
                switch activity {
                case .read(let path):
                    onStage?(.running("Reading \(path)"))
                case .search(let pattern):
                    onStage?(.running("Searching \(pattern)"))
                case .run(let cmd):
                    onStage?(.running("Running \(cmd)"))
                case .webSearch(let query):
                    onStage?(.running("Searching web: \(query)"))
                case .webFetch(let url):
                    onStage?(.running("Fetching \(url)"))
                case .thinking:
                    onStage?(.running("Thinking…"))
                case .writing(let count):
                    onStage?(.running("Writing (\(count) chars)…"))
                case .answerDelta:
                    break
                }
            }

            try Task.checkCancellation()
            onStage?(.validating)

            do {
                let decoded = try AIJSONSalvage.decode(
                    Output.self,
                    from: result.text,
                    structured: result.structured,
                    operation: name
                )
                try validate?(input, decoded)
                onStage?(.completed)
                return (decoded, result)
            } catch {
                if attempt < maxRepairAttempts {
                    attempt += 1
                    onStage?(.repairing(attempt: attempt))
                    let repairText: String
                    if let customRepair = repairPrompt {
                        repairText = customRepair(input, result.text, error)
                    } else {
                        repairText = Self.defaultRepairPrompt(
                            originalPrompt: currentRequest.prompt,
                            previousOutput: result.text,
                            error: error
                        )
                    }
                    currentRequest.prompt = repairText
                    continue
                }
                onStage?(.failed(error.localizedDescription))
                throw error
            }
        }
    }

    static func defaultRepairPrompt(originalPrompt: String, previousOutput: String, error: Error) -> String {
        """
        \(originalPrompt)

        IMPORTANT — Your previous response failed validation:
        Error: \(error.localizedDescription)

        Previous response:
        \(previousOutput.prefix(2000))

        Return ONLY valid JSON matching the required schema with no markdown prose or commentary.
        """
    }
}

// MARK: - Assistant Provider Protocol & Registry (AR-35)

/// Unified protocol describing an AI assistant CLI or ACP backend (`AR-35`).
protocol AssistantProvider: Sendable {
    var tool: CLITool { get }
    var id: String { get }
    var displayName: String { get }
    var binaryName: String { get }
    var usesACP: Bool { get }
    var overrideKey: String { get }
    var versionArgs: [String] { get }
    var authStatusArgs: [String] { get }
    var loginCommand: String { get }
    var fullAccessArgs: [String] { get }
    var continueArgs: [String] { get }
    var defaultXRayModel: String { get }
    func modelArgs(_ model: String?) -> [String]
}

extension AssistantProvider {
    var id: String { tool.rawValue }
    var overrideKey: String { "settings.cli.\(tool.rawValue)Path" }
    var versionArgs: [String] { ["--version"] }
}

struct ClaudeAssistantProvider: AssistantProvider {
    let tool: CLITool = .claude
    let displayName = "Claude Code"
    let binaryName = "claude"
    let usesACP = false
    let authStatusArgs = ["auth", "status"]
    let loginCommand = "auth login"
    let fullAccessArgs = ["--dangerously-skip-permissions"]
    let continueArgs = ["--continue"]
    let defaultXRayModel = "sonnet"

    func modelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["--model", model]
    }
}

struct CodexAssistantProvider: AssistantProvider {
    let tool: CLITool = .codex
    let displayName = "Codex"
    let binaryName = "codex"
    let usesACP = false
    let authStatusArgs = ["login", "status"]
    let loginCommand = "login"
    let fullAccessArgs = ["--dangerously-bypass-approvals-and-sandbox"]
    let continueArgs = ["resume", "--last"]
    let defaultXRayModel = "gpt-5.6-luna"

    func modelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["-m", model]
    }
}

struct ClineAssistantProvider: AssistantProvider {
    let tool: CLITool = .cline
    let displayName = "Cline"
    let binaryName = "cline"
    let usesACP = true
    let authStatusArgs: [String] = []
    let loginCommand = "auth"
    let fullAccessArgs = ["--auto-approve", "true"]
    let continueArgs: [String] = []
    let defaultXRayModel = ""

    func modelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["-m", model]
    }
}

struct CopilotAssistantProvider: AssistantProvider {
    let tool: CLITool = .copilot
    let displayName = "Copilot"
    let binaryName = "copilot"
    let usesACP = true
    let authStatusArgs: [String] = []
    let loginCommand = "login"
    let fullAccessArgs = ["--allow-all"]
    let continueArgs = ["--continue"]
    let defaultXRayModel = ""

    func modelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["--model", model]
    }
}

struct AntigravityAssistantProvider: AssistantProvider {
    let tool: CLITool = .antigravity
    let displayName = "Antigravity"
    let binaryName = "agy"
    let usesACP = false
    let authStatusArgs: [String] = []
    let loginCommand = ""
    let fullAccessArgs = ["--dangerously-skip-permissions"]
    let continueArgs = ["--continue"]
    let defaultXRayModel = ""

    func modelArgs(_ model: String?) -> [String] {
        guard let model, !model.isEmpty else { return [] }
        return ["--model", model]
    }
}

/// Central registry of all supported `AssistantProvider` backends (`AR-35`).
enum AssistantProviderRegistry {
    static let claude = ClaudeAssistantProvider()
    static let codex = CodexAssistantProvider()
    static let cline = ClineAssistantProvider()
    static let copilot = CopilotAssistantProvider()
    static let antigravity = AntigravityAssistantProvider()

    static let all: [any AssistantProvider] = [
        claude,
        codex,
        cline,
        copilot,
        antigravity,
    ]

    static func provider(for tool: CLITool) -> any AssistantProvider {
        switch tool {
        case .claude: return claude
        case .codex: return codex
        case .cline: return cline
        case .copilot: return copilot
        case .antigravity: return antigravity
        }
    }

    static func provider(id: String) -> (any AssistantProvider)? {
        guard let tool = CLITool(rawValue: id) else { return nil }
        return provider(for: tool)
    }
}
