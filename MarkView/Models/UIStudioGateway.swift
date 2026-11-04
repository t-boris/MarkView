import Foundation
import Network

// The loopback gateway of UI Studio (REQ-007, DEC-006). A development server started by UI Studio gets each backend URL
// variable (for example `MARKETPLACE_CORE_URL`) pointed at a listener of this gateway on 127.0.0.1, one port per
// variable. Requests the server makes there are handed to the session's simulator through `StudioGateway.Handler`, the
// same way the page's own requests are. The gateway speaks a minimal HTTP/1.1: one request per connection, answered with
// `connection: close`.
//
// Security: the listeners bind the IPv4 loopback address only; a request must name the listener in its `Host` header
// (DNS rebinding) and must not come from a browser (`sec-fetch-site` or `origin` present). Nothing here logs request
// bodies or header values: they carry the project's (test) secrets.

/// A request the development server sent to a simulated service through the gateway.
struct StudioGatewayRequest: Sendable, Equatable {
    let variable: String          // which variable's listener received it
    let method: String            // uppercased
    let target: String            // origin-form request target: path + optional query, starts with "/"
    let headers: [String: String] // lowercased names; repeated headers joined with ", "
    let body: Data?               // nil when there is no body
}

struct StudioGatewayResponse: Sendable, Equatable {
    var status: Int
    var headers: [String: String]
    var body: Data?
    var delayMs: Int = 0          // wait before answering, capped at 120_000
    var hang: Bool = false        // never answer; hold the connection until releaseHeld() or close()
}

// MARK: - Parser

/// A pure HTTP/1.x request parser and response serializer. `parse` is called again with the whole buffer each time more
/// bytes arrive; it keeps no state between calls.
enum StudioHTTPParser {
    struct Limits: Equatable, Sendable {
        var target = 8 * 1024
        var headerCount = 100
        var headBytes = 64 * 1024
        var body = 5 * 1024 * 1024
        static let standard = Limits()
    }

    struct Message: Equatable, Sendable {
        var method: String
        var target: String
        var headers: [String: String]
        var body: Data?
    }

    enum Result: Equatable, Sendable {
        case incomplete                       // need more bytes
        case expectContinue                   // head complete, body pending, client sent `Expect: 100-continue`
        case complete(Message, consumed: Int) // bytes of `data` used by this message
        case failure(status: Int, reason: String)
    }

    /// Parses one request from the start of `data`. Line endings are CRLF or bare LF; empty lines before the request line
    /// are skipped (and count towards the head size). A zero-length body is reported as no body (`nil`).
    static func parse(_ data: Data, limits: Limits = .standard) -> Result {
        data.withUnsafeBytes { raw -> Result in
            let buffer = Bytes(raw)
            switch parseHead(buffer, limits: limits) {
            case .incomplete: return .incomplete
            case .failure(let status, let reason): return .failure(status: status, reason: reason)
            case .head(let head): return parseBody(buffer, head: head, limits: limits)
            }
        }
    }

    /// The request head (body `nil`) once it is complete and valid, even while its body is still arriving. The gateway
    /// uses it to refuse a request before reading its body.
    static func head(_ data: Data, limits: Limits = .standard) -> Message? {
        data.withUnsafeBytes { raw -> Message? in
            guard case .head(let head) = parseHead(Bytes(raw), limits: limits) else { return nil }
            return Message(method: head.method, target: head.target, headers: head.headers, body: nil)
        }
    }

    /// HTTP/1.1 bytes for a response: drops framing and hop-by-hop headers given by the caller (content-length,
    /// transfer-encoding, connection, keep-alive, upgrade, proxy-*, te, trailer), then sets content-length,
    /// `connection: close` and `x-markview-simulation: 1`; a reason phrase from the status.
    ///
    /// A status outside 200...599 is sent as 500 (a final response cannot be informational). 204 and 304 carry no body
    /// and no content-length. Headers with an invalid name or a value containing CR, LF or other control characters are
    /// dropped, so a simulated value can never inject a header; names that differ only in case are sent once.
    static func serialize(_ response: StudioGatewayResponse) -> Data {
        serialize(response, includeBody: true)
    }

    /// `includeBody: false` answers a HEAD request: the same head (with the body's content-length) and no body.
    static func serialize(_ response: StudioGatewayResponse, includeBody: Bool) -> Data {
        let status = (200...599).contains(response.status) ? response.status : 500
        let bodyAllowed = status != 204 && status != 304
        let body = bodyAllowed ? (response.body ?? Data()) : Data()
        var head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        var sent = Set<String>()
        let ordered = response.headers.sorted { ($0.key.lowercased(), $0.key) < ($1.key.lowercased(), $1.key) }
        for (name, rawValue) in ordered {
            let lower = name.lowercased()
            guard !droppedResponseHeaders.contains(lower), !lower.hasPrefix("proxy-"), isToken(name),
                  let value = fieldValue(rawValue), sent.insert(lower).inserted else { continue }
            head += "\(name): \(value)\r\n"
        }
        if bodyAllowed { head += "content-length: \(body.count)\r\n" }
        head += "connection: close\r\nx-markview-simulation: 1\r\n\r\n"
        var data = Data(head.utf8)
        if includeBody { data.append(body) }
        return data
    }

    static func reasonPhrase(_ status: Int) -> String {
        if let phrase = reasonPhrases[status] { return phrase }
        switch status {
        case 200..<300: return "Success"
        case 300..<400: return "Redirection"
        case 400..<500: return "Client Error"
        default: return "Server Error"
        }
    }

    // MARK: Implementation

    private static let droppedResponseHeaders: Set<String> = [
        "content-length", "transfer-encoding", "connection", "keep-alive", "upgrade", "te", "trailer", "x-markview-simulation",
    ]

    private static let reasonPhrases: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information", 204: "No Content",
        205: "Reset Content", 206: "Partial Content", 207: "Multi-Status", 208: "Already Reported", 226: "IM Used",
        300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
        305: "Use Proxy", 307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 406: "Not Acceptable", 407: "Proxy Authentication Required", 408: "Request Timeout",
        409: "Conflict", 410: "Gone", 411: "Length Required", 412: "Precondition Failed", 413: "Content Too Large",
        414: "URI Too Long", 415: "Unsupported Media Type", 416: "Range Not Satisfiable", 417: "Expectation Failed",
        418: "I'm a teapot", 421: "Misdirected Request", 422: "Unprocessable Content", 423: "Locked",
        424: "Failed Dependency", 425: "Too Early", 426: "Upgrade Required", 428: "Precondition Required",
        429: "Too Many Requests", 431: "Request Header Fields Too Large", 451: "Unavailable For Legal Reasons",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable",
        504: "Gateway Timeout", 505: "HTTP Version Not Supported", 506: "Variant Also Negotiates",
        507: "Insufficient Storage", 508: "Loop Detected", 510: "Not Extended", 511: "Network Authentication Required",
    ]

    private static let lf: UInt8 = 0x0A, cr: UInt8 = 0x0D, sp: UInt8 = 0x20, tab: UInt8 = 0x09, colon: UInt8 = 0x3A
    private static let maxMethod = 32
    private static let maxChunkLine = 4096

    /// The buffer of one `parse` call, read through a raw pointer (no copy of a large body).
    private struct Bytes {
        let raw: UnsafeRawBufferPointer
        init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }
        var count: Int { raw.count }
        subscript(_ index: Int) -> UInt8 { raw[index] }

        /// The next line from `start`: its content without the terminator (LF or CRLF) and where the next line begins.
        func line(from start: Int) -> (content: Range<Int>, next: Int)? {
            guard start < count, let base = raw.baseAddress,
                  let found = memchr(base + start, Int32(StudioHTTPParser.lf), count - start) else { return nil }
            let newline = base.distance(to: UnsafeRawPointer(found))
            let end = newline > start && raw[newline - 1] == StudioHTTPParser.cr ? newline - 1 : newline
            return (start..<end, newline + 1)
        }

        /// UTF-8 when the bytes are valid UTF-8, otherwise ISO Latin 1 (every byte maps to a character).
        func string(_ range: Range<Int>) -> String {
            let slice = UnsafeRawBufferPointer(rebasing: raw[range])
            return String(bytes: slice, encoding: .utf8) ?? String(bytes: slice, encoding: .isoLatin1) ?? ""
        }

        func firstIndex(of byte: UInt8, in range: Range<Int>) -> Int? {
            var index = range.lowerBound
            while index < range.upperBound { if raw[index] == byte { return index }; index += 1 }
            return nil
        }
    }

    private enum Framing { case none, length(Int), chunked }

    private struct Head {
        var method: String
        var target: String
        var headers: [String: String]
        var end: Int            // offset of the first body byte
        var framing: Framing
        var expectsContinue: Bool
    }

    private enum HeadResult {
        case incomplete
        case head(Head)
        case failure(Int, String)
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E: return true
        default: return false
        }
    }

    private static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy(isTokenByte)
    }

    /// A response header value without surrounding whitespace, or nil when it holds a control character.
    private static func fieldValue(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard trimmed.utf8.allSatisfy({ $0 == tab || ($0 >= 0x20 && $0 != 0x7F) }) else { return nil }
        return trimmed
    }

    private static func parseHead(_ buffer: Bytes, limits: Limits) -> HeadResult {
        var position = 0
        while position < buffer.count {
            if buffer[position] == lf { position += 1 } else if buffer[position] == cr, position + 1 < buffer.count,
                                                                  buffer[position + 1] == lf { position += 2 } else { break }
        }
        if position > limits.headBytes { return .failure(431, "Request header fields too large.") }

        // Request line: METHOD SP target SP HTTP/1.x
        guard let requestLine = buffer.line(from: position) else {
            return partialRequestLine(buffer, from: position, limits: limits)
        }
        let line = requestLine.content
        guard let firstSpace = buffer.firstIndex(of: sp, in: line),
              let secondSpace = buffer.firstIndex(of: sp, in: (firstSpace + 1)..<line.upperBound) else {
            return .failure(400, "Malformed request line.")
        }
        let methodRange = line.lowerBound..<firstSpace
        let targetRange = (firstSpace + 1)..<secondSpace
        let versionRange = (secondSpace + 1)..<line.upperBound
        guard !methodRange.isEmpty, methodRange.count <= maxMethod, methodRange.allSatisfy({ isTokenByte(buffer[$0]) }) else {
            return .failure(400, "Malformed request line.")
        }
        guard !targetRange.isEmpty else { return .failure(400, "Malformed request line.") }
        if targetRange.count > limits.target { return .failure(414, "Request target too long.") }
        guard targetRange.allSatisfy({ (0x21...0x7E).contains(buffer[$0]) }) else { return .failure(400, "Malformed request target.") }
        guard buffer[targetRange.lowerBound] == UInt8(ascii: "/") else {
            return .failure(400, "Only origin-form request targets are accepted.")
        }
        let version = buffer.string(versionRange)
        let versionBytes = Array(version.utf8)
        guard versionBytes.count == 8, version.hasPrefix("HTTP/"), versionBytes[6] == UInt8(ascii: "."),
              (0x30...0x39).contains(versionBytes[5]), (0x30...0x39).contains(versionBytes[7]) else {
            return .failure(400, "Malformed request line.")
        }
        guard versionBytes[5] == UInt8(ascii: "1") else { return .failure(505, "HTTP version not supported.") }
        let minor = Int(versionBytes[7] - 0x30)
        if requestLine.next > limits.headBytes { return .failure(431, "Request header fields too large.") }
        let method = buffer.string(methodRange).uppercased()
        let target = buffer.string(targetRange)

        // Header fields until the empty line.
        var headers: [String: String] = [:]
        var fieldCount = 0
        position = requestLine.next
        while true {
            guard let field = buffer.line(from: position) else {
                if buffer.count > limits.headBytes { return .failure(431, "Request header fields too large.") }
                return .incomplete
            }
            if field.next > limits.headBytes { return .failure(431, "Request header fields too large.") }
            position = field.next
            let content = field.content
            if content.isEmpty { break }
            fieldCount += 1
            if fieldCount > limits.headerCount { return .failure(431, "Too many request header fields.") }
            if buffer[content.lowerBound] == sp || buffer[content.lowerBound] == tab {
                return .failure(400, "Folded header lines are not accepted.")
            }
            guard let separator = buffer.firstIndex(of: colon, in: content) else { return .failure(400, "Malformed header line.") }
            let nameRange = content.lowerBound..<separator
            guard !nameRange.isEmpty, nameRange.allSatisfy({ isTokenByte(buffer[$0]) }) else {
                return .failure(400, "Malformed header name.")
            }
            var valueStart = separator + 1, valueEnd = content.upperBound
            while valueStart < valueEnd, buffer[valueStart] == sp || buffer[valueStart] == tab { valueStart += 1 }
            while valueEnd > valueStart, buffer[valueEnd - 1] == sp || buffer[valueEnd - 1] == tab { valueEnd -= 1 }
            let valueRange = valueStart..<valueEnd
            guard valueRange.allSatisfy({ let byte = buffer[$0]; return byte == tab || (byte >= 0x20 && byte != 0x7F) }) else {
                return .failure(400, "Malformed header value.")
            }
            let name = buffer.string(nameRange).lowercased()
            let value = buffer.string(valueRange)
            if let existing = headers[name] { headers[name] = existing + ", " + value } else { headers[name] = value }
        }

        // Body framing.
        let framing: Framing
        let transferEncoding = headers["transfer-encoding"], contentLength = headers["content-length"]
        if transferEncoding != nil && contentLength != nil {
            return .failure(400, "Both Content-Length and Transfer-Encoding are present.")
        }
        if let transferEncoding {
            let codings = transferEncoding.lowercased().split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }.filter { !$0.isEmpty }
            guard !codings.isEmpty else { return .failure(400, "Malformed Transfer-Encoding.") }
            guard codings.allSatisfy({ $0 == "chunked" }) else { return .failure(501, "Transfer coding not supported.") }
            guard codings.count == 1 else { return .failure(400, "Malformed Transfer-Encoding.") }
            framing = .chunked
        } else if let contentLength {
            let values = contentLength.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            guard values.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }) else {
                return .failure(400, "Malformed Content-Length.")
            }
            let normalized = values.map { value -> Substring in
                let digits = value.drop { $0 == "0" }
                return digits.isEmpty ? "0" : digits
            }
            guard Set(normalized).count == 1, let digits = normalized.first else { return .failure(400, "Conflicting Content-Length values.") }
            guard digits.count <= 18, let length = Int(digits), length <= limits.body else {
                return .failure(413, "Request body too large.")
            }
            framing = .length(length)
        } else {
            framing = .none
        }
        let expectsContinue = minor >= 1
            && headers["expect"]?.trimmingCharacters(in: .whitespaces).lowercased() == "100-continue"
        return .head(Head(method: method, target: target, headers: headers, end: position, framing: framing,
                          expectsContinue: expectsContinue))
    }

    /// Limits of a request line that has not ended yet: refuse what can no longer become valid instead of waiting.
    private static func partialRequestLine(_ buffer: Bytes, from start: Int, limits: Limits) -> HeadResult {
        let available = start..<buffer.count
        if let firstSpace = buffer.firstIndex(of: sp, in: available) {
            guard firstSpace > start, (start..<firstSpace).allSatisfy({ isTokenByte(buffer[$0]) }) else {
                return .failure(400, "Malformed request line.")
            }
            let targetEnd = buffer.firstIndex(of: sp, in: (firstSpace + 1)..<buffer.count) ?? buffer.count
            if targetEnd - (firstSpace + 1) > limits.target { return .failure(414, "Request target too long.") }
        } else {
            // Still the method: it must be a short token (this also refuses a TLS handshake at once).
            guard available.count <= maxMethod, available.allSatisfy({ isTokenByte(buffer[$0]) || buffer[$0] == cr }) else {
                return .failure(400, "Malformed request line.")
            }
        }
        if buffer.count > limits.headBytes { return .failure(431, "Request header fields too large.") }
        return .incomplete
    }

    private static func parseBody(_ buffer: Bytes, head: Head, limits: Limits) -> Result {
        let pending: Result = head.expectsContinue ? .expectContinue : .incomplete
        func message(_ body: Data?) -> Message {
            Message(method: head.method, target: head.target, headers: head.headers, body: body)
        }
        switch head.framing {
        case .none:
            return .complete(message(nil), consumed: head.end)
        case .length(let length):
            if length == 0 { return .complete(message(nil), consumed: head.end) }
            guard buffer.count - head.end >= length else { return pending }
            let range = head.end..<(head.end + length)
            return .complete(message(Data(UnsafeRawBufferPointer(rebasing: buffer.raw[range]))), consumed: range.upperBound)
        case .chunked:
            return decodeChunks(buffer, from: head.end, limits: limits, pending: pending, message: message)
        }
    }

    /// Validates the chunks first (jumping over their data, so a body that arrives in pieces is not copied again on every
    /// call) and builds the body only once the last chunk and the trailer section are complete.
    private static func decodeChunks(_ buffer: Bytes, from start: Int, limits: Limits, pending: Result,
                                     message: (Data?) -> Message) -> Result {
        var position = start
        var chunks: [Range<Int>] = []
        var total = 0
        while true {
            guard let sizeLine = buffer.line(from: position) else {
                return buffer.count - position > maxChunkLine ? .failure(status: 400, reason: "Malformed chunk size.") : pending
            }
            let content = sizeLine.content
            guard content.count <= maxChunkLine else { return .failure(status: 400, reason: "Malformed chunk size.") }
            var index = content.lowerBound
            var size = 0
            while index < content.upperBound, let digit = hexValue(buffer[index]) {
                guard index - content.lowerBound < 15 else { return .failure(status: 413, reason: "Request body too large.") }
                size = size * 16 + digit
                index += 1
            }
            guard index > content.lowerBound else { return .failure(status: 400, reason: "Malformed chunk size.") }
            while index < content.upperBound, buffer[index] == sp || buffer[index] == tab { index += 1 }
            guard index == content.upperBound || buffer[index] == UInt8(ascii: ";") else { return .failure(status: 400, reason: "Malformed chunk size.") }
            position = sizeLine.next

            if size == 0 {
                // Trailer section: ignored, but bounded like the head.
                let trailerStart = position
                var trailerCount = 0
                while true {
                    guard let trailer = buffer.line(from: position) else {
                        return buffer.count - trailerStart > limits.headBytes ? .failure(status: 431, reason: "Request trailer fields too large.") : pending
                    }
                    if trailer.next - trailerStart > limits.headBytes { return .failure(status: 431, reason: "Request trailer fields too large.") }
                    position = trailer.next
                    if trailer.content.isEmpty { break }
                    trailerCount += 1
                    if trailerCount > limits.headerCount { return .failure(status: 431, reason: "Too many request trailer fields.") }
                }
                break
            }

            guard total + size <= limits.body else { return .failure(status: 413, reason: "Request body too large.") }
            let dataEnd = position + size
            guard buffer.count > dataEnd else { return pending }
            if buffer[dataEnd] == lf {
                chunks.append(position..<dataEnd)
                position = dataEnd + 1
            } else if buffer[dataEnd] == cr {
                guard buffer.count > dataEnd + 1 else { return pending }
                guard buffer[dataEnd + 1] == lf else { return .failure(status: 400, reason: "Malformed chunk.") }
                chunks.append(position..<dataEnd)
                position = dataEnd + 2
            } else {
                return .failure(status: 400, reason: "Malformed chunk.")
            }
            total += size
        }
        guard total > 0 else { return .complete(message(nil), consumed: position) }
        var body = Data(capacity: total)
        for chunk in chunks { body.append(contentsOf: UnsafeRawBufferPointer(rebasing: buffer.raw[chunk])) }
        return .complete(message(body), consumed: position)
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)
        case 0x41...0x46: return Int(byte - 0x41 + 10)
        case 0x61...0x66: return Int(byte - 0x61 + 10)
        default: return nil
        }
    }
}

// MARK: - Gateway

enum StudioGatewayError: LocalizedError, Equatable {
    case alreadyOpen
    case closed
    case timeout
    case listener(String)

    var errorDescription: String? {
        switch self {
        case .alreadyOpen: return "The UI Studio gateway is already open; close it before opening it again."
        case .closed: return "The UI Studio gateway was closed while it was opening."
        case .timeout: return "The UI Studio gateway could not listen on 127.0.0.1 in time."
        case .listener(let detail): return "The UI Studio gateway could not listen on 127.0.0.1 (\(detail))."
        }
    }
}

/// Loopback HTTP listeners, one per backend URL variable, whose requests are answered by `Handler`.
///
/// Threading: all mutable state lives on one private serial queue. Listener and connection events, the handler call and
/// the delivery of replies run there. The handler is called on that queue, so it must return quickly and must not wait
/// synchronously for the main thread; it may answer later, from any thread. Its reply closure takes effect once — later
/// calls are ignored. `ports`, `releaseHeld()` and `close()` run synchronously on the queue (inline when called from it).
///
/// Lifecycle: `open` once, `close()` when done; after `close()` the gateway may be opened again with a new set of
/// variables (new ports). Opening while open throws `StudioGatewayError.alreadyOpen`.
///
/// Each connection carries one request: read until the parser completes (answering `Expect: 100-continue` once), refuse
/// what the guards refuse, call the handler, wait `delayMs`, write the response and close. A client that closes its side
/// before the answer is dropped and its late reply ignored. The whole request must arrive within `requestTimeout`
/// (408 otherwise); at most `maxConnections` connections are open at once (extra ones are closed at once).
final class StudioGateway: @unchecked Sendable {
    typealias Handler = @Sendable (StudioGatewayRequest, @escaping @Sendable (StudioGatewayResponse) -> Void) -> Void

    static let maxConnections = 64
    static let maxDelayMs = 120_000

    private let handler: Handler
    private let requestTimeout: TimeInterval
    private let limits = StudioHTTPParser.Limits.standard
    private var maxBuffered: Int { limits.headBytes + 2 * limits.body }
    private let queue = DispatchQueue(label: "com.markview.ui-studio.gateway")
    private let queueKey = DispatchSpecificKey<UInt8>()

    // State, on `queue` only.
    private var listeners: [String: NWListener] = [:]
    private var openPorts: [String: UInt16] = [:]
    private var opening: Opening?
    private var links: [UInt64: Link] = [:]
    private var lastLinkID: UInt64 = 0
    private var generation = 0

    /// `requestTimeout`: how long a client has to send its whole request (head and body).
    init(handler: @escaping Handler, requestTimeout: TimeInterval = 30) {
        self.handler = handler
        self.requestTimeout = requestTimeout
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        listeners.values.forEach { $0.cancel() }
        links.values.forEach { $0.timer?.cancel(); $0.connection.cancel() }
    }

    /// One listener per variable on 127.0.0.1 only (IPv4 loopback), on a free port; returns variable → port once all are ready.
    func open(_ variables: [String]) async throws -> [String: UInt16] {
        var seen = Set<String>()
        let names = variables.filter { seen.insert($0).inserted }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { self.begin(names, continuation) }
        }
    }

    /// Ports currently open, by variable.
    var ports: [String: UInt16] { onQueue { openPorts } }

    /// Reset: answers every held (hang) connection with 503 and closes it.
    func releaseHeld() {
        onQueue {
            for link in links.values where link.phase == .held {
                answer(link, with: Self.plain(503, "The simulated service was reset."))
            }
        }
    }

    /// Stops all listeners and connections. Idempotent. Held and waiting requests are closed without an answer.
    func close() {
        onQueue {
            generation += 1
            if let pending = opening {
                opening = nil
                pending.timeout?.cancel()
                pending.continuation.resume(throwing: StudioGatewayError.closed)
            }
            shutDown()
        }
    }

    // MARK: Listeners

    private final class Opening {
        let generation: Int
        var pending: Set<String>
        let continuation: CheckedContinuation<[String: UInt16], Error>
        var timeout: DispatchWorkItem?

        init(generation: Int, pending: Set<String>, continuation: CheckedContinuation<[String: UInt16], Error>) {
            self.generation = generation
            self.pending = pending
            self.continuation = continuation
        }
    }

    private func onQueue<T>(_ work: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) != nil ? work() : queue.sync(execute: work)
    }

    private func begin(_ names: [String], _ continuation: CheckedContinuation<[String: UInt16], Error>) {
        guard opening == nil, listeners.isEmpty else {
            continuation.resume(throwing: StudioGatewayError.alreadyOpen)
            return
        }
        guard !names.isEmpty else {
            continuation.resume(returning: [:])
            return
        }
        generation += 1
        let current = generation
        let pending = Opening(generation: current, pending: Set(names), continuation: continuation)
        opening = pending
        for name in names {
            let listener: NWListener
            do {
                listener = try NWListener(using: Self.loopbackParameters())
            } catch {
                fail(pending, StudioGatewayError.listener(error.localizedDescription))
                return
            }
            listeners[name] = listener
            listener.stateUpdateHandler = { [weak self] state in self?.listener(name, current, changed: state) }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, variable: name, generation: current) }
            listener.start(queue: queue)
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.opening, pending.generation == current else { return }
            self.fail(pending, StudioGatewayError.timeout)
        }
        pending.timeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    /// TCP over IPv4, bound to 127.0.0.1 on a port the system picks, accepting local connections only.
    private static func loopbackParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false
        parameters.includePeerToPeer = false
        return parameters
    }

    private func listener(_ name: String, _ listenerGeneration: Int, changed state: NWListener.State) {
        guard listenerGeneration == generation else { return }
        switch state {
        case .ready:
            guard let port = listeners[name]?.port?.rawValue, port != 0 else {
                if let pending = opening { fail(pending, StudioGatewayError.listener("no port was assigned")) }
                return
            }
            openPorts[name] = port
            if let pending = opening {
                pending.pending.remove(name)
                if pending.pending.isEmpty {
                    opening = nil
                    pending.timeout?.cancel()
                    pending.continuation.resume(returning: openPorts)
                }
            }
        case .failed(let error), .waiting(let error):
            if let pending = opening {
                fail(pending, StudioGatewayError.listener(error.localizedDescription))
            } else if case .failed = state {
                listeners.removeValue(forKey: name)?.cancel()
                openPorts.removeValue(forKey: name)
            }
        case .setup, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func fail(_ pending: Opening, _ error: StudioGatewayError) {
        guard opening === pending else { return }
        opening = nil
        pending.timeout?.cancel()
        generation += 1
        shutDown()
        pending.continuation.resume(throwing: error)
    }

    private func shutDown() {
        listeners.values.forEach { $0.cancel() }
        listeners = [:]
        openPorts = [:]
        let open = links.values
        links = [:]
        open.forEach { $0.timer?.cancel(); $0.connection.cancel() }
    }

    // MARK: Connections

    private enum Phase { case reading, waiting, delaying, held, writing }

    private final class Link {
        let id: UInt64
        let connection: NWConnection
        let variable: String
        let port: UInt16
        var buffer = Data()
        var phase = Phase.reading
        var guardsChecked = false
        var continued = false
        var isHead = false
        var timer: DispatchWorkItem?

        init(id: UInt64, connection: NWConnection, variable: String, port: UInt16) {
            self.id = id
            self.connection = connection
            self.variable = variable
            self.port = port
        }
    }

    private func accept(_ connection: NWConnection, variable: String, generation connectionGeneration: Int) {
        guard connectionGeneration == generation, let port = openPorts[variable] ?? listeners[variable]?.port?.rawValue,
              links.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        lastLinkID += 1
        let id = lastLinkID
        let link = Link(id: id, connection: connection, variable: variable, port: port)
        links[id] = link
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(id)
            case .waiting: self?.drop(id)
            default: break
            }
        }
        let timer = DispatchWorkItem { [weak self] in self?.timedOut(id) }
        link.timer = timer
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timer)
        connection.start(queue: queue)
        receive(link)
    }

    private func receive(_ link: Link) {
        let id = link.id
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            self?.received(id, data, ended: isComplete || error != nil)
        }
    }

    private func received(_ id: UInt64, _ data: Data?, ended: Bool) {
        guard let link = links[id] else { return }
        guard link.phase == .reading else {
            // After the request: extra bytes are ignored; a client that leaves is dropped and its answer never sent.
            if ended { drop(id) } else if link.phase != .writing { receive(link) }
            return
        }
        if let data { link.buffer.append(data) }
        let result = StudioHTTPParser.parse(link.buffer, limits: limits)
        switch result {
        case .failure(let status, let reason):
            answer(link, with: Self.plain(status, reason))
        case .complete(let message, _):
            link.timer?.cancel()
            link.isHead = message.method == "HEAD"
            if let refusal = refusal(message.headers, port: link.port) {
                answer(link, with: refusal)
                return
            }
            link.phase = .waiting
            // A client that ended its side together with the request (half-close) still gets the answer.
            if !ended { receive(link) }
            dispatch(message, for: link)
        case .incomplete, .expectContinue:
            if !link.guardsChecked, let head = StudioHTTPParser.head(link.buffer, limits: limits) {
                link.guardsChecked = true
                link.isHead = head.method == "HEAD"
                if let refusal = refusal(head.headers, port: link.port) {
                    answer(link, with: refusal)
                    return
                }
            }
            // The parser bounds the decoded body; this bounds the framing around it (many tiny chunks).
            if link.buffer.count > maxBuffered {
                answer(link, with: Self.plain(413, "Request body too large."))
                return
            }
            if ended {
                drop(id)
                return
            }
            if result == .expectContinue, !link.continued {
                link.continued = true
                link.connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
            }
            receive(link)
        }
    }

    /// The guards in front of the handler: requests from a browser, and requests that do not name this listener.
    private func refusal(_ headers: [String: String], port: UInt16) -> StudioGatewayResponse? {
        if headers["sec-fetch-site"] != nil || headers["origin"] != nil {
            return Self.plain(403, "A browser may not reach a simulated service.")
        }
        let host = headers["host"]?.lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return Self.plain(421, "This simulated service answers only 127.0.0.1:\(port).")
        }
        return nil
    }

    private func dispatch(_ message: StudioHTTPParser.Message, for link: Link) {
        let request = StudioGatewayRequest(variable: link.variable, method: message.method, target: message.target,
                                           headers: message.headers, body: message.body)
        let id = link.id
        let reply: @Sendable (StudioGatewayResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.queue.async { self.deliver(response, to: id) }
        }
        handler(request, reply)
    }

    private func deliver(_ response: StudioGatewayResponse, to id: UInt64) {
        guard let link = links[id], link.phase == .waiting else { return }
        if response.hang {
            link.phase = .held
            return
        }
        let data = StudioHTTPParser.serialize(response, includeBody: !link.isHead)
        let delay = min(max(response.delayMs, 0), Self.maxDelayMs)
        guard delay > 0 else {
            write(data, to: link)
            return
        }
        link.phase = .delaying
        queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self, let link = self.links[id], link.phase == .delaying else { return }
            self.write(data, to: link)
        }
    }

    /// Answers without the handler: refusals, timeouts and Reset (HEAD gets no body).
    private func answer(_ link: Link, with response: StudioGatewayResponse) {
        write(StudioHTTPParser.serialize(response, includeBody: !link.isHead), to: link)
    }

    /// Writes the whole answer, ends the stream and closes the connection once the bytes are handed to the system.
    private func write(_ data: Data, to link: Link) {
        link.phase = .writing
        link.timer?.cancel()
        let id = link.id
        link.connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.drop(id)
        })
    }

    private func timedOut(_ id: UInt64) {
        guard let link = links[id], link.phase == .reading else { return }
        answer(link, with: Self.plain(408, "The request did not arrive in time."))
    }

    private func drop(_ id: UInt64) {
        guard let link = links.removeValue(forKey: id) else { return }
        link.timer?.cancel()
        link.connection.cancel()
    }

    private static func plain(_ status: Int, _ text: String) -> StudioGatewayResponse {
        StudioGatewayResponse(status: status, headers: ["content-type": "text/plain; charset=utf-8"], body: Data((text + "\n").utf8))
    }
}
