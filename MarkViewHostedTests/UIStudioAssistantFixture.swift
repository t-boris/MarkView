import Foundation
@testable import MarkView

/// A test-only assistant that records real requests and supplies controlled responses.
// unchecked Sendable: the lock guards the handlers and request logs; test requests are not mutated after dispatch.
final class UIStudioAssistantFixture: @unchecked Sendable {
    typealias Handler = @Sendable (CLICompletion.Request) async throws -> CLICompletion.Result
    private let lock = NSLock()
    private var recorded: [CLICompletion.Request] = []
    private var recordedMaps: [CLICompletion.Request] = []
    private var response: Handler = { _ in
        try CLICompletion.Result(text: "", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
    }
    private var mapResponse: Handler?

    func reset() {
        lock.withLock {
            recorded.removeAll()
            recordedMaps.removeAll()
            response = { _ in
                try CLICompletion.Result(text: "", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
            }
            mapResponse = nil
        }
    }

    var requests: [CLICompletion.Request] { lock.withLock { recorded } }
    var mapRequests: [CLICompletion.Request] { lock.withLock { recordedMaps } }
    var answer: Handler {
        get { lock.withLock { response } }
        set { lock.withLock { response = newValue } }
    }
    var mapAnswer: Handler? {
        get { lock.withLock { mapResponse } }
        set { lock.withLock { mapResponse = newValue } }
    }

    func run(_ request: CLICompletion.Request, _ delta: (@Sendable (String) -> Void)?,
             _ activity: (@Sendable (CLICompletion.Activity) -> Void)?) async throws -> CLICompletion.Result {
        let isMap = request.label.hasPrefix("ui-studio:map")
        let handler: Handler? = lock.withLock {
            if isMap {
                recordedMaps.append(request)
                return mapResponse
            }
            recorded.append(request)
            return response
        }
        if let handler {
            if !isMap { activity?(.thinking) }
            return try await handler(request)
        }
        return try CLICompletion.Result(text: "", structured: ["services": [], "endpoints": [], "notes": []],
                                        inputTokens: 0, outputTokens: 0, costUSD: nil)
    }
}
