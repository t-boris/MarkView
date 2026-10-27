import Foundation

/// Acknowledged HTTPS mailboxes. Only successfully handled messages advance the cursor.
/// Retried sends retain their ID; a relay must deduplicate before assigning a sequence.
actor RemoteChannel {
    private let invitation: RemoteInvitation
    private let role: RemoteRole
    private let session: URLSession
    private let consumer = UUID().uuidString
    private var cursor = 0
    private var closed = false
    private var pending: [(RemoteMessage, CheckedContinuation<Void, Error>)] = []
    private var sending = false
    private var reassembler = RemoteReassembler()

    init(invitation: RemoteInvitation, role: RemoteRole, session: URLSession? = nil) {
        self.invitation = invitation; self.role = role
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 35
            config.timeoutIntervalForResource = 40
            config.httpShouldSetCookies = false
            config.urlCache = nil
            self.session = URLSession(configuration: config, delegate: RemoteNoRedirects(), delegateQueue: nil)
        }
    }

    func register(accessKey: String = "") async throws {
        guard accessKey.utf8.count <= 1024, !accessKey.contains("\r"), !accessKey.contains("\n"), !accessKey.contains("\0") else {
            throw RemoteFailure.invalid("The relay access key is invalid. Paste the key without a line break.")
        }
        let body = RemoteJSON.object([
            "room": .string(invitation.room.uuidString.lowercased()),
            "homeToken": .string(invitation.token(for: .home)),
            "workToken": .string(invitation.token(for: .work))])
        // Managed free services may need a cold start. Retrying registration is safe because the
        // same invitation and credentials are retained; an existing room returns success.
        for attempt in 0..<3 {
            do { _ = try await request("POST", path: "v1/rooms", body: body, registrationKey: accessKey); return }
            catch {
                if Task.isCancelled { throw CancellationError() }
                if case RemoteFailure.invalid = error { throw error }
                if case RemoteFailure.expired = error { throw error }
                if attempt == 2 { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
    }

    func send(_ message: RemoteMessage) async throws {
        guard !closed else { throw RemoteFailure.disconnected }
        guard pending.count < 256 else { throw RemoteFailure.invalid("The remote connection is not keeping up.") }
        try await withCheckedThrowingContinuation { continuation in
            pending.append((message, continuation))
            if !sending { sending = true; Task { await drain() } }
        }
    }

    private func drain() async {
        while !pending.isEmpty && !closed {
            let (message, continuation) = pending.removeFirst()
            do {
                for frame in try RemoteFraming.frames(for: message) {
                    let body = try invitation.seal(frame, sender: role)
                    var lastError: Error = RemoteFailure.disconnected
                    var delivered = false
                    for attempt in 0..<4 {
                        do {
                            _ = try await request("POST", path: mailbox, body: .object([
                                "id": .string(frame.id.uuidString), "body": .string(body)]))
                            delivered = true; break
                        } catch {
                            lastError = error
                            if case RemoteFailure.expired = error { break }
                            try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
                        }
                    }
                    if !delivered { throw lastError }
                }
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }
        sending = false
    }

    func receive(_ handle: @Sendable (RemoteMessage) async throws -> Void) async throws {
        var failures = 0
        while !closed {
            try Task.checkCancellation()
            do {
                let response = try await request("GET", path: mailbox,
                    query: [URLQueryItem(name: "after", value: String(cursor)), URLQueryItem(name: "consumer", value: consumer)])
                guard let messages = response["messages"].array, messages.count <= 256 else {
                    throw RemoteFailure.invalid("Invalid relay response.")
                }
                for value in messages {
                    guard let sequence = value["seq"].integer, sequence > cursor,
                          let body = value["body"].string else { throw RemoteFailure.invalid("Invalid message sequence.") }
                    let frame = try invitation.open(body, sender: role.peer)
                    if let message = try reassembler.accept(frame) {
                        try await handle(message)
                        reassembler.acknowledge(message.id)
                    }
                    cursor = sequence
                }
                failures = 0
            } catch is CancellationError { throw CancellationError() }
            catch {
                if closed { return }
                if case RemoteFailure.expired = error { throw error }
                failures += 1
                guard failures < 5 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(min(failures, 4)) * 1_000_000_000)
            }
        }
    }

    func close() {
        closed = true
        for (_, continuation) in pending { continuation.resume(throwing: RemoteFailure.disconnected) }
        pending.removeAll()
        reassembler = RemoteReassembler()
        session.invalidateAndCancel()
    }

    func revoke() async {
        _ = try? await request("DELETE", path: "v1/rooms/" + invitation.room.uuidString.lowercased())
        close()
    }

    private var mailbox: String { "v1/rooms/" + invitation.room.uuidString.lowercased() + "/" + role.rawValue }

    private func request(_ method: String, path: String, body: RemoteJSON? = nil, query: [URLQueryItem] = [], registrationKey: String = "") async throws -> RemoteJSON {
        guard !closed else { throw RemoteFailure.disconnected }
        var components = URLComponents(url: invitation.relay.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer " + invitation.token(for: role), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !registrationKey.isEmpty { request.setValue(registrationKey, forHTTPHeaderField: "X-Registration-Token") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteFailure.invalid("Invalid relay response.") }
        if method == "POST", path == "v1/rooms", [401, 403].contains(http.statusCode) {
            throw RemoteFailure.invalid("The relay access key was rejected. Check the home connection settings.")
        }
        guard ![401, 403, 404, 410].contains(http.statusCode) else { throw RemoteFailure.expired }
        guard (200..<300).contains(http.statusCode) else { throw RemoteFailure.relay(http.statusCode) }
        guard data.count <= RemoteMessage.maxBytes * 3 else { throw RemoteFailure.invalid("Relay response is too large.") }
        return data.isEmpty ? .null : try JSONDecoder().decode(RemoteJSON.self, from: data)
    }
}

private final class RemoteNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
