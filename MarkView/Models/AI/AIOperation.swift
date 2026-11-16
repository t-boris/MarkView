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

    /// An answer as text: the structured answer as JSON when there is one, else the plain text.
    static func answerText(_ result: CLICompletion.Result) -> String {
        if let object = result.structured, JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return result.text
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

/// Decodes an arbitrary JSON object into a Foundation dictionary for schema-validated CLI outputs (`AR-26`).
// unchecked Sendable: the dictionary holds JSON values only (String, Int, Double, Bool, NSNull, Array, Dictionary), is a `let`, and is never mutated.
struct AIRawJSONObject: Decodable, @unchecked Sendable {
    let dictionary: [String: Any]

    /// A dictionary that is JSON already (an answer read back from the cache, or one that was decoded earlier).
    init(_ dictionary: [String: Any]) { self.dictionary = dictionary }

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

/// The runner every operation uses unless a test supplies another: one completion through the window's own assistant.
enum AIAssistantRunner {
    static func run(_ request: CLICompletion.Request, _ onDelta: (@Sendable (String) -> Void)?,
                    _ onActivity: (@Sendable (CLICompletion.Activity) -> Void)?) async throws -> CLICompletion.Result {
        try await CLICompletion.run(request, onDelta: onDelta, onActivity: onActivity)
    }
}

/// An error of `parse` or `validate` that asking again cannot mend: the operation ends with it at once, attempts left or not.
protocol AIUnrepairable: Error {}

/// Which attempt of an operation is being judged: the first is 1, `isLast` when no repair request follows a rejection.
struct AIAttempt: Equatable, Sendable {
    let number: Int
    let isLast: Bool
}

/// What a repair request is built from: the request that was just answered, the answer and why it was not accepted.
struct AIRepair<Input> {
    let input: Input
    /// The first request of the operation (the repair prompt of the default policy is always built on it, never on a repair).
    let original: CLICompletion.Request
    /// The request whose answer was rejected.
    let request: CLICompletion.Request
    let result: CLICompletion.Result
    let error: Error
    /// The rejected attempt.
    let attempt: AIAttempt

    /// The rejected answer as text for a repair prompt: the structured answer as JSON, else the plain text.
    var previousAnswer: String { AIJSONSalvage.answerText(result) }
}

/// The one pipeline that asks the assistant: builds the request, runs it through `CLICompletion` (project assistant, model, call log,
/// cancellation), interprets the answer (`parse`: plain text, a structured object or a decoded type), judges it (`validate`), and
/// when it is rejected asks again with a repair request, at most `maxRepairAttempts` more times (`AR-26`).
///
/// A feature declares what is its own: the request (prompt, system prompt, schema, timeout, effort, label), what its answer
/// becomes, what makes it unacceptable, and how the next request differs. Errors of the run itself (CLI missing, failed, timed out)
/// and cancellation are never repaired, and neither is an `AIUnrepairable` rejection: they end the operation at once.
struct AIOperation<Input, Output> {
    typealias Delta = @Sendable (String) -> Void
    typealias Activity = @Sendable (CLICompletion.Activity) -> Void
    typealias Runner = (CLICompletion.Request, Delta?, Activity?) async throws -> CLICompletion.Result

    let name: String
    let maxRepairAttempts: Int
    let buildRequest: (Input) -> CLICompletion.Request
    /// The answer as the feature's output; throws when the answer cannot be read. A rejection is repaired like a failed `validate`.
    let parse: (Input, CLICompletion.Result, AIAttempt) async throws -> Output
    /// Throws what is wrong with a readable answer.
    let validate: ((Input, Output, AIAttempt) async throws -> Void)?
    /// The request that follows a rejected answer; nil = the original request with the problem and the previous answer appended.
    let repair: ((AIRepair<Input>) -> CLICompletion.Request)?
    /// Called with every completed run, including one that is then rejected (usage accounting).
    let onResult: ((CLICompletion.Result) async -> Void)?
    let runner: Runner

    init(
        name: String,
        maxRepairAttempts: Int = 0,
        buildRequest: @escaping (Input) -> CLICompletion.Request,
        parse: @escaping (Input, CLICompletion.Result, AIAttempt) async throws -> Output,
        validate: ((Input, Output, AIAttempt) async throws -> Void)? = nil,
        repair: ((AIRepair<Input>) -> CLICompletion.Request)? = nil,
        onResult: ((CLICompletion.Result) async -> Void)? = nil,
        runner: @escaping Runner = AIAssistantRunner.run
    ) {
        self.name = name
        self.maxRepairAttempts = max(0, maxRepairAttempts)
        self.buildRequest = buildRequest
        self.parse = parse
        self.validate = validate
        self.repair = repair
        self.onResult = onResult
        self.runner = runner
    }

    /// Run the operation. `onDelta` and `onActivity` report the streaming answer and the assistant's activity of every attempt.
    /// It runs on the caller's actor, so the feature's closures (`parse`, `validate`, `repair`, `onResult`) keep the isolation
    /// they were written in; only the assistant's run itself leaves it.
    func execute(
        _ input: Input,
        onDelta: Delta? = nil,
        onActivity: Activity? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> (output: Output, result: CLICompletion.Result) {
        let original = Self.labelled(buildRequest(input), as: name)
        var request = original
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let result = try await runner(request, onDelta, onActivity)
            await onResult?(result)
            let judged = AIAttempt(number: attempt + 1, isLast: attempt >= maxRepairAttempts)
            do {
                let output = try await parse(input, result, judged)
                try await validate?(input, output, judged)
                return (output, result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !judged.isLast, !(error is AIUnrepairable) else { throw error }
                let context = AIRepair(input: input, original: original, request: request, result: result, error: error, attempt: judged)
                request = Self.labelled(repair?(context) ?? Self.defaultRepair(context), as: name)
                attempt += 1
            }
        }
    }

    private static func labelled(_ request: CLICompletion.Request, as name: String) -> CLICompletion.Request {
        var request = request
        if request.label.isEmpty { request.label = name }
        return request
    }

    /// The original request with the problem and the previous answer appended.
    static func defaultRepair(_ context: AIRepair<Input>) -> CLICompletion.Request {
        var next = context.original
        next.prompt = defaultRepairPrompt(originalPrompt: context.original.prompt, previousOutput: context.previousAnswer, error: context.error)
        return next
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

extension AIOperation where Input == CLICompletion.Request {
    /// An operation whose input is the request itself.
    init(
        name: String,
        maxRepairAttempts: Int = 0,
        parse: @escaping (CLICompletion.Result) async throws -> Output,
        validate: ((Output, AIAttempt) async throws -> Void)? = nil,
        repair: ((AIRepair<CLICompletion.Request>) -> CLICompletion.Request)? = nil,
        onResult: ((CLICompletion.Result) async -> Void)? = nil,
        runner: @escaping Runner = AIAssistantRunner.run
    ) {
        self.init(name: name, maxRepairAttempts: maxRepairAttempts, buildRequest: { $0 },
                  parse: { _, result, _ in try await parse(result) },
                  validate: validate.map { check in { _, output, attempt in try await check(output, attempt) } },
                  repair: repair, onResult: onResult, runner: runner)
    }
}

extension AIOperation where Input == CLICompletion.Request, Output == CLICompletion.Result {
    /// One run, answered as it came: for a feature that reads `text`, `structured` and the usage itself.
    static func run(name: String, runner: @escaping Runner = AIAssistantRunner.run) -> AIOperation {
        AIOperation(name: name, parse: { $0 }, runner: runner)
    }

    /// Ask once and take the run as it came.
    static func ask(_ request: CLICompletion.Request, name: String,
                    onDelta: Delta? = nil, onActivity: Activity? = nil,
                    isolation: isolated (any Actor)? = #isolation) async throws -> CLICompletion.Result {
        try await run(name: name).execute(request, onDelta: onDelta, onActivity: onActivity).result
    }
}

extension AIOperation where Input == CLICompletion.Request, Output == String {
    /// One run answered in plain text, as it is written.
    static func text(name: String, runner: @escaping Runner = AIAssistantRunner.run) -> AIOperation {
        AIOperation(name: name, parse: { $0.text }, runner: runner)
    }
}

extension AIOperation where Input == CLICompletion.Request, Output == [String: Any] {
    /// One run whose structured answer is read as an object; an answer that is no object reads as an empty one.
    static func object(name: String, runner: @escaping Runner = AIAssistantRunner.run) -> AIOperation {
        AIOperation(name: name, parse: { $0.structured as? [String: Any] ?? [:] }, runner: runner)
    }
}

extension AIOperation where Output: Decodable {
    /// The answer decoded as `Output` from the structured answer, or from the JSON in the text when `allowTextSalvage`.
    init(
        name: String,
        maxRepairAttempts: Int = 1,
        allowTextSalvage: Bool = true,
        buildRequest: @escaping (Input) -> CLICompletion.Request,
        validate: ((Input, Output) throws -> Void)? = nil,
        repair: ((AIRepair<Input>) -> CLICompletion.Request)? = nil,
        onResult: ((CLICompletion.Result) async -> Void)? = nil,
        runner: @escaping Runner = AIAssistantRunner.run
    ) {
        self.init(
            name: name, maxRepairAttempts: maxRepairAttempts, buildRequest: buildRequest,
            parse: { _, result, _ in
                try AIJSONSalvage.decode(Output.self, from: result.text, structured: result.structured,
                                         operation: name, allowTextSalvage: allowTextSalvage)
            },
            validate: validate.map { check in { input, output, _ in try check(input, output) } },
            repair: repair, onResult: onResult, runner: runner)
    }
}
