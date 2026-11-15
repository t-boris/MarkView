import CryptoKit
import Foundation

/// A long-lived connection the gateway hands to the session instead of answering one request (REQ-015): a WebSocket
/// after its Upgrade handshake, or a `text/event-stream` response held open.
enum StudioGatewayStreamKind: Equatable, Sendable {
    case webSocket(protocols: [String])
    case eventSource
}

/// What happens on a stream, in order, for the session's channel handler.
enum StudioGatewayStreamEvent: Sendable {
    /// A client asks to open a stream; the session answers with `acceptStream` or `refuseStream`.
    case open(UInt64, StudioGatewayStreamKind, StudioGatewayRequest)
    case text(UInt64, String)
    case binary(UInt64, Data)
    /// The client closed the stream or went away (`code` from its close frame).
    case closed(UInt64, Int?)
}

/// What a simulated channel sends on one connection: through the gateway, or to the page through the bridge.
enum StudioChannelFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
    /// A server-sent event.
    case event(name: String?, data: String, id: String?)
    case close(code: Int, reason: String)

    /// The frame as the page runtime reads it.
    var bridgeValue: [String: Any] {
        switch self {
        case .text(let text): return ["type": "text", "data": text]
        case .binary(let data): return ["type": "binary", "data": data.base64EncodedString()]
        case .event(let name, let data, let id): return ["type": "event", "event": name ?? "message", "data": data, "id": id ?? ""]
        case .close(let code, let reason): return ["type": "close", "code": code, "reason": reason]
        }
    }
}

/// The state of one stream on the gateway's queue.
final class StudioGatewayStream {
    let kind: StudioGatewayStreamKind
    let key: String
    var decoder = StudioWebSocketCodec.Decoder()
    var accepted = false
    var closing = false

    init(kind: StudioGatewayStreamKind, key: String) {
        self.kind = kind
        self.key = key
    }
}

/// RFC 6455 for the server side: the handshake, frames (masked client frames, text, binary, ping/pong, close,
/// fragmentation) and size limits; and the framing of server-sent events.
enum StudioWebSocketCodec {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    /// The largest payload of one frame and of one (reassembled) message.
    static let maxMessage = 1_048_576

    enum Opcode: UInt8 {
        case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10
    }

    /// `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key`.
    static func acceptKey(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key.trimmingCharacters(in: .whitespaces) + guid).utf8))).base64EncodedString()
    }

    /// The stream a request asks for; nil for a plain request. A WebSocket needs GET, `Upgrade: websocket`, `Connection:
    /// Upgrade` and a key; a server-sent event stream is a GET that accepts `text/event-stream`.
    static func kind(method: String, headers: [String: String]) -> StudioGatewayStreamKind? {
        guard method == "GET" else { return nil }
        let upgrade = headers["upgrade"]?.lowercased() ?? ""
        let connection = headers["connection"]?.lowercased() ?? ""
        if upgrade.contains("websocket"), connection.contains("upgrade"), headers["sec-websocket-key"] != nil {
            let protocols = (headers["sec-websocket-protocol"] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .webSocket(protocols: protocols)
        }
        if headers["accept"]?.lowercased().contains("text/event-stream") == true { return .eventSource }
        return nil
    }

    static func handshake(key: String, protocol chosen: String?) -> Data {
        var head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey(key))\r\n"
        if let chosen, !chosen.isEmpty { head += "Sec-WebSocket-Protocol: \(chosen)\r\n" }
        head += "X-MarkView-Simulation: 1\r\n\r\n"
        return Data(head.utf8)
    }

    static func eventStreamHead() -> Data {
        Data(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n"
              + "X-MarkView-Simulation: 1\r\n\r\n").utf8)
    }

    /// One server-sent event: `event:`, one `data:` line per line of `data`, `id:`, and the blank line that ends it.
    static func event(name: String?, data: String, id: String?) -> Data {
        var text = ""
        if let name, !name.isEmpty, name != "message" { text += "event: \(name.replacingOccurrences(of: "\n", with: " "))\n" }
        for line in data.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            text += "data: \(line)\n"
        }
        if let id, !id.isEmpty { text += "id: \(id.replacingOccurrences(of: "\n", with: " "))\n" }
        return Data((text + "\n").utf8)
    }

    /// One frame. Server frames are not masked; `masked` is for clients (and tests).
    static func frame(_ opcode: Opcode, _ payload: Data, masked: Bool = false, fin: Bool = true) -> Data {
        var bytes: [UInt8] = [(fin ? 0x80 : 0) | opcode.rawValue]
        let mask: UInt8 = masked ? 0x80 : 0
        let count = payload.count
        if count < 126 {
            bytes.append(mask | UInt8(count))
        } else if count <= 0xFFFF {
            bytes += [mask | 126, UInt8(count >> 8), UInt8(count & 0xFF)]
        } else {
            bytes.append(mask | 127)
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF)) }
        }
        if masked {
            let key = (0..<4).map { _ in UInt8.random(in: 0...255) }
            bytes += key
            bytes += payload.enumerated().map { $0.element ^ key[$0.offset % 4] }
        } else {
            bytes += payload
        }
        return Data(bytes)
    }

    static func closeFrame(code: Int, reason: String) -> Data {
        var payload = Data([UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)])
        payload.append(Data(reason.utf8.prefix(123)))
        return frame(.close, payload)
    }

    /// Reads a client's frames as they arrive in pieces.
    struct Decoder {
        enum Output: Equatable {
            case text(String)
            case binary(Data)
            case ping(Data)
            case pong(Data)
            case close(Int?, String)
        }

        /// A violation; the connection is closed with `code`.
        struct Failure: Error, Equatable {
            var code: Int
            var reason: String
        }

        /// Clients must mask every frame (RFC 6455 §5.1).
        var requireMask = true
        private var buffer: [UInt8] = []
        private var fragments: [UInt8]?
        private var fragmentOpcode = Opcode.text

        mutating func feed(_ data: Data) throws -> [Output] {
            buffer += data
            var outputs: [Output] = []
            while buffer.count >= 2 {
                let first = buffer[0], second = buffer[1]
                guard first & 0x70 == 0 else { throw Failure(code: 1002, reason: "Reserved bits are set") }
                guard let opcode = Opcode(rawValue: first & 0x0F) else { throw Failure(code: 1002, reason: "Unknown opcode") }
                let fin = first & 0x80 != 0
                let masked = second & 0x80 != 0
                if requireMask, !masked { throw Failure(code: 1002, reason: "Client frames must be masked") }
                var offset = 2
                var length = UInt64(second & 0x7F)
                if length == 126 {
                    guard buffer.count >= 4 else { break }
                    length = UInt64(buffer[2]) << 8 | UInt64(buffer[3])
                    offset = 4
                } else if length == 127 {
                    guard buffer.count >= 10 else { break }
                    length = (2..<10).reduce(UInt64(0)) { $0 << 8 | UInt64(buffer[$1]) }
                    offset = 10
                }
                guard length <= UInt64(StudioWebSocketCodec.maxMessage) else { throw Failure(code: 1009, reason: "The frame is too large") }
                let isControl = opcode.rawValue >= 8
                if isControl, !fin || length > 125 { throw Failure(code: 1002, reason: "A control frame is fragmented or too long") }
                let maskLength = masked ? 4 : 0
                let total = offset + maskLength + Int(length)
                guard buffer.count >= total else { break }
                var payload = Array(buffer[(offset + maskLength)..<total])
                if masked {
                    let key = Array(buffer[offset..<(offset + 4)])
                    for index in payload.indices { payload[index] ^= key[index % 4] }
                }
                buffer.removeFirst(total)
                switch opcode {
                case .ping: outputs.append(.ping(Data(payload)))
                case .pong: outputs.append(.pong(Data(payload)))
                case .close:
                    let code = payload.count >= 2 ? Int(payload[0]) << 8 | Int(payload[1]) : nil
                    let reason = payload.count > 2 ? String(decoding: payload[2...], as: UTF8.self) : ""
                    outputs.append(.close(code, reason))
                    return outputs
                case .continuation:
                    guard var pending = fragments else { throw Failure(code: 1002, reason: "A continuation without a message") }
                    pending += payload
                    guard pending.count <= StudioWebSocketCodec.maxMessage else { throw Failure(code: 1009, reason: "The message is too large") }
                    if fin {
                        fragments = nil
                        outputs.append(try Self.message(fragmentOpcode, pending))
                    } else {
                        fragments = pending
                    }
                case .text, .binary:
                    guard fragments == nil else { throw Failure(code: 1002, reason: "A new message inside a fragmented one") }
                    if fin {
                        outputs.append(try Self.message(opcode, payload))
                    } else {
                        fragments = payload
                        fragmentOpcode = opcode
                    }
                }
            }
            return outputs
        }

        private static func message(_ opcode: Opcode, _ payload: [UInt8]) throws -> Output {
            guard opcode == .text else { return .binary(Data(payload)) }
            guard let text = String(bytes: payload, encoding: .utf8) else { throw Failure(code: 1007, reason: "The text is not UTF-8") }
            return .text(text)
        }
    }
}
