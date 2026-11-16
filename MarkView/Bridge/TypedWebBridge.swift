import Foundation
import os
import WebKit
#if canImport(MarkViewCore)
import MarkViewCore
#endif

// MARK: - The contract

/// The one declaration of what a page may post to the app (AR-28): `Editor/js/bridge-contract.json`.
///
/// Both sides read the same file. Swift (`TypedWebBridge`) validates every message against it before a handler sees it, and
/// hands the file's text to the page (`userScript`), where `mvBridge.send` validates before it posts. A message whose channel,
/// type or fields do not match is refused and logged by type and field name, never by value.
struct BridgeContract: Sendable {
    enum LoadError: Error, CustomStringConvertible {
        case unreadable(String)
        case malformed(String)
        var description: String {
            switch self {
            case .unreadable(let detail): return "bridge contract unreadable: \(detail)"
            case .malformed(let detail): return "bridge contract malformed: \(detail)"
            }
        }
    }

    enum Kind: String, Sendable {
        case string, int, number, boolean, object, array, any
    }

    /// One payload, field or array element. A reference class: a spec for `object` and `array` holds further specs.
    final class Spec: Sendable {
        let kind: Kind
        let optional: Bool
        let nonEmpty: Bool
        let min: Double?
        let max: Double?
        let maxItems: Int?
        let allowed: Set<String>?
        let isUUID: Bool
        let fields: [String: Spec]
        let items: Spec?

        init(kind: Kind, optional: Bool = false, nonEmpty: Bool = false, min: Double? = nil, max: Double? = nil, maxItems: Int? = nil,
             allowed: Set<String>? = nil, isUUID: Bool = false, fields: [String: Spec] = [:], items: Spec? = nil) {
            self.kind = kind
            self.optional = optional
            self.nonEmpty = nonEmpty
            self.min = min
            self.max = max
            self.maxItems = maxItems
            self.allowed = allowed
            self.isUUID = isUUID
            self.fields = fields
            self.items = items
        }
    }

    struct Message: Sendable {
        /// An object spec (`fields`) or an array spec (`items`).
        let payload: Spec
        let mainFrameOnly: Bool
    }

    /// Every message type of one channel (one `WKScriptMessageHandler` name), by type name.
    let channels: [String: [String: Message]]
    /// The file's text, handed to the page unchanged.
    let text: String

    static let empty = BridgeContract(channels: [:], text: "{\"contract\":1,\"channels\":{}}")

    /// The contract file in the app bundle (overridable for tests that run outside the app bundle).
    private static let bundledURLStorage = OSAllocatedUnfairLock(
        initialState: Bundle.main.url(forResource: "bridge-contract", withExtension: "json", subdirectory: "Editor/js")
    )
    static var bundledURL: URL? {
        get { bundledURLStorage.withLock { $0 } }
        set { bundledURLStorage.withLock { $0 = newValue } }
    }

    /// The app's own copy of the contract. A copy that cannot be read is an empty contract: every page message is refused and logged.
    static let bundled: BridgeContract = {
        guard let url = bundledURL else {
            AppLog.bridge.error("bridge-contract.json is not in the app bundle; every page message will be refused")
            return .empty
        }
        do { return try BridgeContract(contentsOf: url) } catch {
            AppLog.bridge.error("\(String(describing: error)); every page message will be refused")
            return .empty
        }
    }()

    init(channels: [String: [String: Message]], text: String) {
        self.channels = channels
        self.text = text
    }

    init(contentsOf url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw LoadError.unreadable(url.lastPathComponent) }
        try self.init(data: data)
    }

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawChannels = root["channels"] as? [String: Any] else { throw LoadError.malformed("no channels") }
        let definitions = root["definitions"] as? [String: Any] ?? [:]
        var channels: [String: [String: Message]] = [:]
        for (channelName, rawChannel) in rawChannels {
            guard let rawMessages = (rawChannel as? [String: Any])?["messages"] as? [String: Any] else {
                throw LoadError.malformed("channel \(channelName) has no messages")
            }
            var messages: [String: Message] = [:]
            for (type, rawMessage) in rawMessages {
                guard let entry = rawMessage as? [String: Any] else { throw LoadError.malformed("\(channelName)/\(type)") }
                let payload: Spec
                if let fields = entry["fields"] as? [String: Any] {
                    payload = Spec(kind: .object, fields: try Self.parseFields(fields, definitions: definitions, at: "\(channelName)/\(type)"))
                } else if let items = entry["items"] {
                    payload = Spec(kind: .array, items: try Self.parseSpec(items, definitions: definitions, depth: 0, at: "\(channelName)/\(type)"))
                } else {
                    throw LoadError.malformed("\(channelName)/\(type) has neither fields nor items")
                }
                messages[type] = Message(payload: payload, mainFrameOnly: entry["mainFrameOnly"] as? Bool ?? false)
            }
            channels[channelName] = messages
        }
        self.init(channels: channels, text: text)
    }

    private static func parseFields(_ raw: [String: Any], definitions: [String: Any], at: String) throws -> [String: Spec] {
        var fields: [String: Spec] = [:]
        for (name, value) in raw { fields[name] = try parseSpec(value, definitions: definitions, depth: 0, at: "\(at).\(name)") }
        return fields
    }

    /// A spec is a type name (a primitive or a definition), optionally ending in `?`, or an object with `type` and its options.
    private static func parseSpec(_ raw: Any, definitions: [String: Any], depth: Int, at: String) throws -> Spec {
        guard depth < 8 else { throw LoadError.malformed("\(at): definitions nest too deep") }
        var optional = false
        var options: [String: Any] = [:]
        var typeName: String
        if let name = raw as? String {
            typeName = name
        } else if let object = raw as? [String: Any], let name = object["type"] as? String {
            typeName = name
            options = object
            optional = object["optional"] as? Bool ?? false
        } else {
            throw LoadError.malformed("\(at): not a type")
        }
        if typeName.hasSuffix("?") {
            optional = true
            typeName.removeLast()
        }
        if Kind(rawValue: typeName) == nil {
            // A definition: its own options apply, the use site can only make it optional.
            guard let definition = definitions[typeName] else { throw LoadError.malformed("\(at): unknown type \(typeName)") }
            let resolved = try parseSpec(definition, definitions: definitions, depth: depth + 1, at: at)
            return Spec(kind: resolved.kind, optional: optional || resolved.optional, nonEmpty: resolved.nonEmpty, min: resolved.min,
                        max: resolved.max, maxItems: resolved.maxItems, allowed: resolved.allowed, isUUID: resolved.isUUID,
                        fields: resolved.fields, items: resolved.items)
        }
        let kind = Kind(rawValue: typeName)!
        var fields: [String: Spec] = [:]
        if let rawFields = options["fields"] as? [String: Any] {
            guard kind == .object else { throw LoadError.malformed("\(at): fields on a \(typeName)") }
            fields = try parseFields(rawFields, definitions: definitions, at: at)
        }
        var items: Spec?
        if let rawItems = options["items"] {
            guard kind == .array else { throw LoadError.malformed("\(at): items on a \(typeName)") }
            items = try parseSpec(rawItems, definitions: definitions, depth: depth + 1, at: at + "[]")
        }
        return Spec(kind: kind, optional: optional, nonEmpty: options["nonEmpty"] as? Bool ?? false,
                    min: (options["min"] as? NSNumber)?.doubleValue, max: (options["max"] as? NSNumber)?.doubleValue,
                    maxItems: (options["maxItems"] as? NSNumber)?.intValue,
                    allowed: (options["enum"] as? [String]).map(Set.init), isUUID: options["format"] as? String == "uuid",
                    fields: fields, items: items)
    }

    /// The message types of a channel.
    func messageTypes(in channel: String) -> Set<String> {
        Set(channels[channel].map { Array($0.keys) } ?? [])
    }

    /// The script that gives a page the contract before any of its own scripts run (`mvBridge.send` reads `window.mvBridgeContract`).
    @MainActor var userScript: WKUserScript {
        WKUserScript(source: "window.mvBridgeContract = \(text);", injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // MARK: Validation

    /// What is wrong with `value` against `spec`, or nil. Names the field and the rule, never the value.
    func problem(with value: Any?, against spec: Spec, at path: String) -> String? {
        if value == nil || value is NSNull {
            return spec.optional ? nil : "\(path) is missing"
        }
        let value = value!
        switch spec.kind {
        case .any:
            return nil
        case .string:
            guard let string = value as? String, !(value is NSNumber) else { return "\(path) is not a string" }
            if spec.nonEmpty && string.isEmpty { return "\(path) is empty" }
            if let allowed = spec.allowed, !allowed.contains(string) { return "\(path) is not a declared value" }
            if spec.isUUID && UUID(uuidString: string) == nil { return "\(path) is not a UUID" }
            return nil
        case .int, .number:
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return "\(path) is not a \(spec.kind == .int ? "whole number" : "number")"
            }
            let double = number.doubleValue
            guard double.isFinite else { return "\(path) is not finite" }
            if spec.kind == .int && (double.rounded() != double || abs(double) > 9_007_199_254_740_992) { return "\(path) is not a whole number" }
            if let min = spec.min, double < min { return "\(path) is below its minimum" }
            if let max = spec.max, double > max { return "\(path) is above its maximum" }
            return nil
        case .boolean:
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return "\(path) is not a boolean" }
            return nil
        case .object:
            guard let object = value as? [String: Any] else { return "\(path) is not an object" }
            for (name, field) in spec.fields.sorted(by: { $0.key < $1.key }) {
                if let problem = problem(with: object[name], against: field, at: "\(path).\(name)") { return problem }
            }
            return nil
        case .array:
            guard let array = value as? [Any] else { return "\(path) is not an array" }
            if let maxItems = spec.maxItems, array.count > maxItems { return "\(path) has too many items" }
            if let items = spec.items {
                for (index, element) in array.enumerated() {
                    if let problem = problem(with: element, against: items, at: "\(path)[\(index)]") { return problem }
                }
            }
            return nil
        }
    }
}

// MARK: - The typed handler

/// What a handler receives: the payload decoded into its own type, the tab the page named, and the payload as it arrived
/// (for the sub-protocols whose fields the handler's owner reads by action).
struct BridgeMessage<Payload> {
    let payload: Payload
    /// The `doc` the page attached: the id of the tab whose document it showed, or empty.
    let doc: String
    let raw: Any

    var rawDictionary: [String: Any] { raw as? [String: Any] ?? [:] }
}

/// A payload type of one contract message. `messageType` is the message's name in the contract.
protocol BridgePayload: Decodable {
    static var messageType: String { get }
}

enum BridgeOutcome: Equatable {
    case handled
    case rejected(String)
}

/// Receives every message of one `WKScriptMessageHandler` channel: checks it against the contract, decodes the payload into the
/// registered type and calls the one handler registered for it. A message that is not in the contract, is malformed, comes from a
/// frame it may not come from, or has no handler is logged by type name only and dropped.
///
/// WebKit delivers script messages on the main thread; handlers run on the main actor.
final class TypedWebBridge: NSObject, WKScriptMessageHandler {
    let channel: String
    let contract: BridgeContract
    /// Where a refusal is reported (one line, no payload content).
    var reject: (String) -> Void = { AppLog.bridge.error("\($0)") }

    private var handlers: [String: @MainActor (_ payload: Any, _ doc: String) -> Bool] = [:]

    init(channel: String, contract: BridgeContract = .bundled) {
        self.channel = channel
        self.contract = contract
        super.init()
    }

    /// The message types that have a handler.
    var registeredTypes: Set<String> { Set(handlers.keys) }

    /// A type that is not in the contract, or registered twice, is a programming error (reported in a debug build). A handler for a
    /// type the contract does not declare is kept in `registeredTypes` and never called, so the comparison with the contract shows it.
    func on<P: BridgePayload>(_ payload: P.Type, handle: @escaping @MainActor (BridgeMessage<P>) -> Void) {
        let type = P.messageType
        if contract.channels[channel]?[type] == nil {
            assertionFailure("\(channel)/\(type) is not in the bridge contract")
            reject("handler for \(channel)/\(Self.label(type)) is not in the contract")
        }
        guard handlers[type] == nil else {
            assertionFailure("\(channel)/\(type) has two handlers")
            return
        }
        handlers[type] = { [weak self] raw, doc in
            guard let self else { return false }
            guard JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let decoded = try? JSONDecoder().decode(P.self, from: data) else {
                self.reject("\(self.channel)/\(Self.label(type)): payload does not decode into its type")
                return false
            }
            handle(BridgeMessage(payload: decoded, doc: doc, raw: raw))
            return true
        }
    }

    /// Check one message and hand it to its handler. `isMainFrame`: the message came from the page's top frame.
    @discardableResult
    func receive(body: Any, isMainFrame: Bool) -> BridgeOutcome {
        guard let envelope = body as? [String: Any], let type = envelope["type"] as? String else {
            return refuse("\(channel): message without a type")
        }
        guard let message = contract.channels[channel]?[type] else {
            return refuse("\(channel)/\(Self.label(type)): not in the contract")
        }
        if message.mainFrameOnly && !isMainFrame {
            return refuse("\(channel)/\(type): refused, not from the top frame")
        }
        var payload: Any? = envelope["payload"]
        if payload == nil || payload is NSNull, message.payload.kind == .object { payload = [String: Any]() }
        if let problem = contract.problem(with: payload, against: message.payload, at: "payload") {
            return refuse("\(channel)/\(type): \(problem)")
        }
        guard let handler = handlers[type] else {
            return refuse("\(channel)/\(type): no handler")
        }
        let doc = envelope["doc"] as? String ?? ""
        let delivered = MainActor.assumeIsolated { handler(payload as Any, doc) }
        return delivered ? .handled : .rejected("\(channel)/\(type): not delivered")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(body: message.body, isMainFrame: message.frameInfo.isMainFrame)
    }

    private func refuse(_ reason: String) -> BridgeOutcome {
        reject(reason)
        return .rejected(reason)
    }

    /// A type name from a page is untrusted text: control characters would let a page forge log lines (CWE-117).
    private static func label(_ name: String) -> String {
        String(name.map { $0.isNewline || $0 == "\0" || $0.asciiValue.map({ $0 < 0x20 }) == true ? "_" : $0 }.prefix(64))
    }
}
