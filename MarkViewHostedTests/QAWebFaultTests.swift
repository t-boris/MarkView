import AppKit
import ImageIO
import WebKit
import Network
import XCTest
@testable import MarkView

// The shipping QA player, browser session and executor in real isolated WebKit views.
final class FaultServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "qa-fault-fixture")
    private let lock = NSLock()
    private var listener: NWListener?
    private var readyPort: UInt16 = 0
    private var received: [String] = []
    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return readyPort }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return received }
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [self] state in
            if case .ready = state { lock.lock(); readyPort = listener.port?.rawValue ?? 0; lock.unlock() }
        }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, Data())
        }
        listener.start(queue: queue)
    }
    func stop() { listener?.cancel() }
    private func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            var request = previous
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")[0]
                lock.lock(); received.append(line); lock.unlock()
                let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\nConnection: close\r\n\r\n{}"
                connection.send(content: Data(reply.utf8), contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil { connection.cancel() }
            else { receive(connection, request) }
        }
    }
}

final class QAWebFaultTests: XCTestCase {
    @MainActor func testFaultIsolationAndFileChooser() async throws {
        _ = NSApplication.shared
        let server = FaultServer()
        try server.start()
        defer { server.stop() }
        let deadline = Date().addingTimeInterval(10)
        while server.port == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(server.port != 0, "Loopback server did not start")
        let address = "http://127.0.0.1:\(server.port)"
        func check(_ value: Bool, _ name: String) { XCTAssertTrue(value, name) }
        func player(_ id: String) async throws -> QAWebActor {
            let actor = QAWebActor(request: QADriverRequest(actor: QAActor(id: id, name: id), app: QAApp(id: "fixture", name: "Fixture"), address: address, login: nil),
                                   credentials: QACredentials(username: nil, password: nil))
            actor.session.webView.loadHTMLString("<title>Request fault fixture</title><p>Ready</p>", baseURL: URL(string: address))
            for _ in 0..<100 {
                if actor.session.webView.title == "Request fault fixture" { return actor }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw NSError(domain: "qa-fault-fixture", code: 1)
        }
        func evaluate(_ actor: QAWebActor, _ script: String) async throws -> Any? {
            try await actor.session.webView.callAsyncJavaScript(script, arguments: ["base": address], in: nil, contentWorld: .page)
        }
        let first = try await player("first")
        let second = try await player("second")
        try await first.arm(QAFault(urlPattern: "/messages", mode: .status, status: 503, method: "post"))
        let values = try await evaluate(first, """
            const url = base + '/messages';
            const get = await fetch(url);
            const post = await fetch(url, {method: 'POST'});
            const put = await fetch(url, {method: 'PUT'});
            const requestPost = await fetch(new Request(url, {method: 'POST'}));
            const overrideGet = await fetch(new Request(url, {method: 'POST'}), {method: 'GET'});
            const unrelated = await fetch(base + '/other', {method: 'POST'});
            async function xhr(method) {
              return new Promise((resolve, reject) => {
                const x = new XMLHttpRequest(); x.open(method, url);
                x.onload = () => resolve(x.status); x.onerror = () => reject(new Error('XHR failed')); x.send();
              });
            }
            return [get.status, post.status, put.status, requestPost.status, overrideGet.status, unrelated.status, await xhr('GET'), await xhr('POST')];
            """) as? [Int] ?? []
        check(values == [200, 503, 200, 503, 200, 200, 200, 503], "POST fails while GET, Request overrides, other methods and unrelated paths work through fetch and XHR")
        check(!server.requests.contains { $0.hasPrefix("POST /messages ") }, "Intercepted message sends never reach the application server")
        check(server.requests.contains { $0.hasPrefix("GET /messages ") }, "Reading the same message endpoint still reaches the server")
        check(await first.faultHits() == 3, "Only the three matching sends are counted as fault hits")
        let otherStatus = try await evaluate(second, "return (await fetch(base + '/messages', {method: 'POST'})).status;") as? Int
        check(otherStatus == 200 && server.requests.contains { $0.hasPrefix("POST /messages ") }, "A second player's POST is unaffected")
        let legacy = try await player("legacy")
        try await legacy.arm(QAFault(urlPattern: "/messages", mode: .status, status: 503))
        let oldValues = try await evaluate(legacy, "return [(await fetch(base + '/messages')).status, (await fetch(base + '/messages', {method: 'POST'})).status];") as? [Int]
        check(oldValues == [503, 503], "Existing rules without a method still affect GET and POST")
        // A player answers a page's file chooser with its built-in picture: the production actor wires the chooser, the file is a real PNG.
        let prompts = QAPlayerPrompts()
        let chosen = prompts.chooseFiles(allowsMultiple: false, allowsDirectories: false)
        check(chosen?.count == 1 && chosen?.first?.lastPathComponent == QATestImage.fileName, "A player answers a file chooser with one file named like the built-in picture")
        check(prompts.ask(UserPrompt(title: "Delete?", buttons: ["OK", "Cancel"])) == nil, "and still answers no question to a person")
        if let url = chosen?.first, let data = try? Data(contentsOf: url), let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            check(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "The picture file is a PNG")
            check(properties[kCGImagePropertyPixelWidth] as? Int == QATestImage.width && properties[kCGImagePropertyPixelHeight] as? Int == QATestImage.height,
                  "The picture is \(QATestImage.width) by \(QATestImage.height) pixels")
        } else { check(false, "The chosen picture file can be read as an image") }
        check(prompts.chooseFiles(allowsMultiple: true, allowsDirectories: false)?.first == chosen?.first, "A second answer is the same file, written whole again")
        await first.close(); await second.close(); await legacy.close()
    }
}
