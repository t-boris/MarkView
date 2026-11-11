import Foundation

/// Per-player, per-service state. Captures and cookies live only for one branch; tokens never enter the scenario or logs.
final class QAAPIClient: NSObject, URLSessionDataDelegate {
    static let responseLimit = 2 * 1024 * 1024
    private let origin: URL
    private let credentials: QACredentials
    private var variables: [String: String] = [:]
    private var jsonVariables: [String: String] = [:]
    private var secrets: Set<String> = []
    private var last: (status: Int, data: Data, milliseconds: Int)?
    private var session: URLSession!
    private var pending: CheckedContinuation<(Data, URLResponse), Error>?
    private var response: URLResponse?
    private var received = Data()
    private let queue = OperationQueue()

    init(address: String, credentials: QACredentials = QACredentials()) throws {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw QAAPIError.invalid("The service needs an HTTP(S) base URL without embedded credentials.") }
        origin = url
        self.credentials = credentials
        if let password = credentials.password, !password.isEmpty { secrets.insert(password) }
        super.init()
        queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func close() { session.invalidateAndCancel() }

    /// Requests stay inside the service selected in Setup. Redirects are returned as responses without following them.
    func resolved(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.scheme?.lowercased() == origin.scheme?.lowercased(), url.host?.lowercased() == origin.host?.lowercased(),
              (url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)) == (origin.port ?? (origin.scheme?.lowercased() == "https" ? 443 : 80)),
              url.user == nil, url.password == nil else { throw QAAPIError.invalid("Requests must stay on the configured service origin and use no embedded credentials.") }
        return url
    }

    private func expand(_ input: String) throws -> String {
        var value = input
        if let username = credentials.username, let encoded = QAAPIRequest.json(username) { value = value.replacingOccurrences(of: "{{username.json}}", with: encoded) }
        if let password = credentials.password, let encoded = QAAPIRequest.json(password) { value = value.replacingOccurrences(of: "{{password.json}}", with: encoded) }
        value = credentials.fill(value)
        for (key, replacement) in jsonVariables { value = value.replacingOccurrences(of: "{{\(key).json}}", with: replacement) }
        for (key, replacement) in variables { value = value.replacingOccurrences(of: "{{\(key)}}", with: replacement) }
        guard value.range(of: "\\{\\{[^{}]+\\}\\}", options: .regularExpression) == nil else { throw QAAPIError.invalid("A request uses a missing capture or credential. Capture it in an earlier step or choose a saved login.") }
        return value
    }

    private func scrub(_ input: String) -> String {
        var text = input
        for secret in secrets.sorted(by: { $0.count > $1.count }) where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "[secret]")
        }
        return text
    }

    func execute(_ step: QAAPIRequest) async throws -> QAAPIResult {
        guard step.problems.isEmpty else { throw QAAPIError.invalid(step.problems.joined(separator: " ")) }
        try Task.checkCancellation()
        var label = "Previous response"
        if !step.path.isEmpty {
            // A failed send must never leave an older response available for the next check.
            last = nil
            let url = try resolved(try expand(step.path))
            var request = URLRequest(url: url, timeoutInterval: TimeInterval(step.timeoutSeconds))
            request.httpMethod = step.method
            for header in step.headers {
                let value = try expand(header.value)
                guard QAAPIRequest.validHeaderValue(value) else { throw QAAPIError.invalid("An expanded header contains an invalid control character.") }
                request.setValue(value, forHTTPHeaderField: header.name)
                if ["authorization", "proxy-authorization", "cookie", "x-api-key"].contains(header.name.lowercased()) { secrets.insert(value) }
            }
            if !step.body.isEmpty {
                request.httpBody = Data(try expand(step.body).utf8)
                if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            }
            let started = Date()
            let (data, response) = try await send(request)
            guard let http = response as? HTTPURLResponse else { throw QAAPIError.transport }
            last = (http.statusCode, data, Int(Date().timeIntervalSince(started) * 1000))
            // The scenario's template is safe to keep; resolved query values can contain credentials.
            label = "\(step.method) \(step.path)"
        }
        guard let last else { throw QAAPIError.invalid("There is no response to check. Add a request before this step for this player and service.") }
        let json = try? JSONSerialization.jsonObject(with: last.data, options: [.fragmentsAllowed])
        // Collect secrets before rendering any response, even when another assertion fails.
        var captured: [String: String] = [:]
        var capturedJSON: [String: String] = [:]
        for capture in step.captures {
            if let json, let value = QAAPIRequest.value(at: capture.pointer, in: json) {
                let text = (value as? String) ?? QAAPIRequest.json(value) ?? ""
                captured[capture.name] = text
                capturedJSON[capture.name] = QAAPIRequest.json(value)
                if capture.secret { secrets.insert(text) }
            }
        }
        // Common authentication fields are always private, even if the generated capture omitted secret=true.
        func protect(_ value: Any) {
            if let map = value as? [String: Any] {
                for (key, child) in map {
                    if ["token", "accesstoken", "refreshtoken", "idtoken", "password", "secret", "apikey"].contains(key.lowercased().filter { $0.isLetter }), let string = child as? String { secrets.insert(string) }
                    protect(child)
                }
            } else if let array = value as? [Any] { array.forEach(protect) }
        }
        if let json { protect(json) }
        var failures: [String] = []
        if !step.statuses.contains(last.status) { failures.append("Expected HTTP \(step.statuses.map(String.init).joined(separator: "/")); received \(last.status).") }
        for assertion in step.assertions {
            guard let json, let actual = QAAPIRequest.value(at: assertion.pointer, in: json),
                  let expected = try? JSONSerialization.jsonObject(with: Data(assertion.equals.utf8), options: [.fragmentsAllowed]),
                  QAAPIRequest.json(actual) == QAAPIRequest.json(expected) else {
                failures.append("JSON assertion at \(assertion.pointer.isEmpty ? "(root)" : assertion.pointer) did not match \(assertion.equals).")
                continue
            }
        }
        for capture in step.captures where captured[capture.name] == nil { failures.append("Missing capture \(capture.name) at \(capture.pointer).") }
        if failures.isEmpty {
            variables.merge(captured) { _, new in new }
            jsonVariables.merge(capturedJSON) { _, new in new }
        }
        // Scrub decoded strings before re-encoding, so JSON escaping cannot reveal captured or saved secrets.
        func safe(_ value: Any) -> Any {
            if let map = value as? [String: Any] { return map.mapValues(safe) }
            if let array = value as? [Any] { return array.map(safe) }
            if let string = value as? String { return scrub(string) }
            return value
        }
        let body = json.flatMap { QAAPIRequest.json(safe($0)) } ?? scrub(String(decoding: last.data, as: UTF8.self))
        let excerpt = String(body.prefix(16000)) + (body.count > 16000 ? "\n[Response excerpt; assertions used the full response]" : "")
        let evidence = "\(label) → HTTP \(last.status) · \(last.milliseconds) ms\n" + (failures.isEmpty ? "Checks passed" : failures.joined(separator: "\n")) + "\n" + excerpt
        return QAAPIResult(passed: failures.isEmpty, evidence: scrub(evidence))
    }

    /// Stop can race with creation of the request. Do not cancel a suspended task until its continuation is installed:
    /// URLSession can deliver completion immediately on cancellation, before a later resume.
    private final class Transfer {
        private let lock = NSLock()
        private let task: URLSessionDataTask
        private var ready = false
        private var cancelled = false
        init(_ task: URLSessionDataTask) { self.task = task }
        func cancel() {
            lock.lock(); cancelled = true; let mayCancel = ready; lock.unlock()
            if mayCancel { task.cancel() }
        }
        func start() {
            lock.lock(); ready = true; let wasCancelled = cancelled; lock.unlock()
            if wasCancelled { task.cancel() }
            task.resume()
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let transfer = Transfer(session.dataTask(with: request))
        do {
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    queue.addOperation {
                        self.pending = continuation
                        self.response = nil
                        self.received = Data()
                        transfer.start()
                    }
                }
            }, onCancel: { transfer.cancel() })
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        completionHandler(response.expectedContentLength > Int64(Self.responseLimit) ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if received.count + data.count > Self.responseLimit { dataTask.cancel() } else { received.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = pending; pending = nil
        if error != nil {
            continuation?.resume(throwing: QAAPIError.transport)
        } else if let response { continuation?.resume(returning: (received, response)) }
        else { continuation?.resume(throwing: QAAPIError.transport) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A redirect is a response under test. Never replay a mutating request or forward credentials to another address.
        completionHandler(nil)
    }
}
