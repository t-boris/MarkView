import Foundation

// MARK: - Typed AI Operation & JSON Salvage (AR-26)

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

    /// Decode `Output` from `structured` (`JSONSerialization` object), or from `raw` text when `allowTextSalvage` is true.
    static func decode<Output: Decodable>(
        _ type: Output.Type,
        from raw: String,
        structured: Any? = nil,
        operation: String = "AIOperation",
        allowTextSalvage: Bool = true,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Output {
        if let structured, JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let decoded = try? decoder.decode(Output.self, from: data) {
            return decoded
        }

        guard allowTextSalvage else {
            throw AIOperationError.decodingFailed(operation: operation, detail: "Structured JSON output missing")
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
/// Decodes an arbitrary JSON object into a Foundation dictionary for schema-validated CLI outputs (`AR-26`).
struct AIRawJSONObject: Decodable, @unchecked Sendable {
    let dictionary: [String: Any]

    private enum JSONValue: Decodable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let int = try? container.decode(Int.self) {
                self = .int(int)
            } else if let double = try? container.decode(Double.self) {
                self = .double(double)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let array = try? container.decode([JSONValue].self) {
                self = .array(array)
            } else if let object = try? container.decode([String: JSONValue].self) {
                self = .object(object)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
            }
        }

        var foundationValue: Any {
            switch self {
            case .object(let dict): return dict.mapValues(\.foundationValue)
            case .array(let arr): return arr.map(\.foundationValue)
            case .string(let s): return s
            case .int(let i): return i
            case .double(let d): return d
            case .bool(let b): return b
            case .null: return NSNull()
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawObject = try container.decode([String: JSONValue].self)
        self.dictionary = rawObject.mapValues(\.foundationValue)
    }
}

struct AIOperation<Input, Output: Decodable> {
    typealias Runner = (CLICompletion.Request, (@Sendable (CLICompletion.Activity) -> Void)?) async throws -> CLICompletion.Result

    let name: String
    let maxRepairAttempts: Int
    let allowTextSalvage: Bool
    let buildRequest: (Input) -> CLICompletion.Request
    let validate: ((Input, Output) throws -> Void)?
    let repairPrompt: ((Input, String, Error) -> String)?
    let runner: Runner

    init(
        name: String,
        maxRepairAttempts: Int = 1,
        allowTextSalvage: Bool = true,
        buildRequest: @escaping (Input) -> CLICompletion.Request,
        validate: ((Input, Output) throws -> Void)? = nil,
        repairPrompt: ((Input, String, Error) -> String)? = nil,
        runner: @escaping Runner = { req, onActivity in try await CLICompletion.run(req, onActivity: onActivity) }
    ) {
        self.name = name
        self.maxRepairAttempts = max(0, maxRepairAttempts)
        self.allowTextSalvage = allowTextSalvage
        self.buildRequest = buildRequest
        self.validate = validate
        self.repairPrompt = repairPrompt
        self.runner = runner
    }

    /// Execute the operation with JSON decoding and up to `maxRepairAttempts` repair retries.
    func execute(
        _ input: Input
    ) async throws -> (output: Output, result: CLICompletion.Result) {
        try Task.checkCancellation()

        var currentRequest = buildRequest(input)
        if currentRequest.label.isEmpty {
            currentRequest.label = name
        }

        var attempt = 0
        while true {
            try Task.checkCancellation()

            let result = try await runner(currentRequest, nil)

            try Task.checkCancellation()

            do {
                let decoded = try AIJSONSalvage.decode(
                    Output.self,
                    from: result.text,
                    structured: result.structured,
                    operation: name,
                    allowTextSalvage: allowTextSalvage
                )
                try validate?(input, decoded)
                return (decoded, result)
            } catch {
                if attempt < maxRepairAttempts {
                    attempt += 1
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
