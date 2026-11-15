import Foundation

/// HTTP has no window, screenshots or visual review. Every branch receives fresh sessions and captured values.
final class QAAPIActor: QAActorDriver, QAAPIExecuting {
    private let client: QAAPIClient
    private let address: String
    private var latest = "No requests sent yet."

    init(request: QADriverRequest, credentials: QACredentials) throws {
        address = request.address
        client = try QAAPIClient(address: request.address, credentials: credentials)
    }
    func open(_ address: String) async throws { _ = try client.resolved(address) }
    func execute(_ request: QAAPIRequest) async throws -> QAAPIResult {
        let result = try await client.execute(request)
        latest = result.evidence
        return result
    }
    func observe() async throws -> QAObservation { QAObservation(address: address, title: "HTTP API", snapshot: latest) }
    func perform(_ action: QAAction) async throws -> String {
        guard action.kind == .http else { throw QAAPIError.invalid("API preparation supports HTTP requests only.") }
        let result = try await execute(QAAPIRequest(method: action.method.isEmpty ? "GET" : action.method, path: action.url, body: action.text,
                                                   statuses: Array(100...599)))
        return result.evidence
    }
    func screenshot() async -> Data? { nil }
    func arm(_ fault: QAFault) async throws { throw QAAPIError.invalid("API faults require service-side or manual preparation.") }
    func faultHits() async -> Int { 0 }
    func close() async { client.close() }
}

final class QAAPIDriverFactory: QADriverFactory {
    func makeDriver(_ request: QADriverRequest) async throws -> QAActorDriver {
        var credentials = QACredentials(username: request.login?.username, password: nil)
        if let login = request.login {
            credentials.password = await Task.detached(priority: .userInitiated) {
                BrowserPasswordStore.shared.password(host: login.host, username: login.username)
            }.value
        }
        return try QAAPIActor(request: request, credentials: credentials)
    }
}
