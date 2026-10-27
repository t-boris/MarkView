import Foundation

/// Failure injection at URLSession's HTTP boundary: the production channel encrypts, queues,
/// retries and acknowledges real requests; no network listener is required for this layer.
private final class RelayBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [(Int, String)] = []
    private var seen: Set<String> = []
    private var postIDs: [String] = []
    private var cursors: [Int] = []
    private var failFirstSend = true
    func handle(_ request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if request.url!.path == "/v1/rooms" { return Data("{}".utf8) }
        if request.httpMethod == "POST" {
            let value = try JSONDecoder().decode(RemoteJSON.self, from: request.httpBody ?? Data())
            let id = value["id"].string!, body = value["body"].string!
            postIDs.append(id)
            if seen.insert(id).inserted { messages.append((messages.count + 1, body)) }
            if failFirstSend { failFirstSend = false; throw URLError(.networkConnectionLost) }
            return Data("{}".utf8)
        }
        let after = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "after" }!.value!)!
        cursors.append(after)
        let result = RemoteJSON.object(["messages": .array(messages.filter { $0.0 > after }.map { .object(["seq": .int($0.0), "body": .string($0.1)]) })])
        return try JSONEncoder().encode(result)
    }
    func snapshot() -> (ids: [String], cursors: [Int], bodies: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (postIDs, cursors, messages.map(\.1))
    }
}
private final class RelayURLProtocol: URLProtocol {
    static let relay = RelayBoundary()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "relay.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var request = request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer[..<count])
                }
                request.httpBody = data
            }
            let data = try Self.relay.handle(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private actor Deliveries {
    private(set) var ids: [UUID] = []
    func add(_ id: UUID) -> Int { ids.append(id); return ids.count }
}

@main
enum RemoteChannelTests {
    static func main() async throws {
        func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RelayURLProtocol.self]
            return URLSession(configuration: configuration)
        }
        let invitation = try RemoteInvitation(relay: URL(string: "https://relay.example.invalid")!)
        let home = RemoteChannel(invitation: invitation, role: .home, session: session())
        let work = RemoteChannel(invitation: invitation, role: .work, session: session())
        try await home.register()
        let message = RemoteMessage("toolCall", .object(["private": .string("work file contents")]))
        try await work.send(message)
        let deliveries = Deliveries()
        try await home.receive { received in
            precondition(received.id == message.id && received.payload == message.payload, "Encrypted tool calls must arrive intact.")
            if await deliveries.add(received.id) == 1 { throw URLError(.timedOut) }
            await home.close()
        }
        await work.close()
        let log = RelayURLProtocol.relay.snapshot()
        precondition(log.ids == [message.id.uuidString, message.id.uuidString], "A send with an ambiguous result must retry the same message ID.")
        precondition(log.cursors == [0, 0], "A failed handler must not acknowledge the message.")
        precondition(log.bodies.count == 1 && !log.bodies[0].contains("work file contents"), "Retries must not duplicate encrypted commands or expose plaintext.")
        print("Remote HTTPS channel: encryption, ambiguous-send retry, delivery and acknowledgement checks passed.")
    }
}
