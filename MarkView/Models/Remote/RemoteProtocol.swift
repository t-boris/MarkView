import Foundation
import CryptoKit

/// The wire format is independent of AppKit, PTYs, providers and the relay implementation.
/// The relay authenticates endpoints but never receives the workspace encryption key.
enum RemoteJSON: Codable, Equatable, Sendable {
    case object([String: RemoteJSON]), array([RemoteJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: RemoteJSON].self) { self = .object(v) }
        else { self = .array(try value.decode([RemoteJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> RemoteJSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var integer: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded() == v,
              v > Double(Int.min), v < Double(Int.max) else { return nil }
        return Int(v)
    }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var array: [RemoteJSON]? { if case .array(let v) = self { return v }; return nil }
    var object: [String: RemoteJSON]? { if case .object(let v) = self { return v }; return nil }
    static func int(_ n: Int) -> RemoteJSON { .number(Double(n)) }
    static func textResult(_ text: String, error: Bool = false) -> RemoteJSON {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(error)])
    }
    func requiredString(_ key: String, limit: Int = 1_048_576) throws -> String {
        guard let v = self[key].string, v.utf8.count <= limit, !v.contains("\0") else {
            throw RemoteFailure.invalid("Invalid or missing \(key).")
        }
        return v
    }
}

enum RemoteFailure: LocalizedError {
    case invalid(String), disconnected, relay(Int), expired, sessionChanged
    var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        case .disconnected: return "The remote connection is closed."
        case .relay(let status): return "The relay returned HTTP \(status)."
        case .sessionChanged: return "The peer started a new remote session."
        case .expired: return "This connection has expired or was revoked. Create a new connection on the home computer."
        }
    }
}

enum RemoteRole: String, Codable, Sendable {
    case home, work
    var peer: RemoteRole { self == .home ? .work : .home }
}

struct RemoteInvitation: Codable, Sendable {
    static let prefix = "markview-remote-v1."
    let relay: URL
    let room: UUID
    let persistent: Bool?
    var isPersistent: Bool { persistent == true }
    private let secret: Data

    init(relay: URL, persistent: Bool = false) throws {
        try Self.validateRelay(relay)
        self.relay = relay
        self.persistent = persistent ? true : nil
        self.room = UUID()
        self.secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    init(code: String) throws {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix(Self.prefix), code.utf8.count < 8192,
              let data = Data(remoteBase64: String(code.dropFirst(Self.prefix.count))) else {
            throw RemoteFailure.invalid("Paste the connection code from the home computer.")
        }
        self = try JSONDecoder().decode(Self.self, from: data)
        try Self.validateRelay(relay)
        guard secret.count == 32 else { throw RemoteFailure.invalid("Invalid connection key.") }
    }

    var code: String { get throws { Self.prefix + (try JSONEncoder().encode(self)).remoteBase64 } }
    func token(for role: RemoteRole) -> String {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(room.uuidString.lowercased().utf8), info: Data(("auth:" + role.rawValue).utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0).remoteBase64 }
    }
    private func authenticatedData(sender: RemoteRole) -> Data {
        Data(("MarkView/remote/v1/" + room.uuidString.lowercased() + "/" + sender.rawValue).utf8)
    }
    func seal(_ message: RemoteMessage, sender: RemoteRole) throws -> String {
        let data = try JSONEncoder().encode(message)
        guard data.count <= RemoteMessage.maxBytes else { throw RemoteFailure.invalid("Remote message is too large.") }
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: secret), authenticating: authenticatedData(sender: sender))
        return box.combined!.base64EncodedString()
    }
    func open(_ body: String, sender: RemoteRole) throws -> RemoteMessage {
        guard body.utf8.count <= RemoteMessage.maxBytes * 2, let data = Data(base64Encoded: body) else {
            throw RemoteFailure.invalid("Invalid encrypted message.")
        }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: secret), authenticating: authenticatedData(sender: sender))
        return try JSONDecoder().decode(RemoteMessage.self, from: plain)
    }
    static func validateRelay(_ url: URL) throws {
        let loopback = ["localhost", "127.0.0.1", "[::1]"].contains(url.host?.lowercased() ?? "")
        guard url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && loopback) else {
            throw RemoteFailure.invalid("Use an HTTPS relay URL. HTTP is allowed only on localhost for testing.")
        }
    }
}

struct RemoteMessage: Codable, Sendable {
    static let maxBytes = 4 * 1024 * 1024
    let id: UUID
    let kind: String
    var payload: RemoteJSON
    init(_ kind: String, _ payload: RemoteJSON = .null, id: UUID = UUID()) {
        self.id = id; self.kind = kind; self.payload = payload
    }
}

extension Data {
    var remoteBase64: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(remoteBase64: String) {
        let s = remoteBase64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4))
    }
}
