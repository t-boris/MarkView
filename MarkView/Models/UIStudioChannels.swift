import Foundation

// MARK: - Channel rules (REQ-015)

/// The writes of an entity a channel rule reacts to or makes.
enum StudioChannelWrite: String, Codable, Hashable, Sendable, CaseIterable {
    case create, update, delete

    var operation: StudioRule.Operation {
        switch self {
        case .create: return .create
        case .update: return .update
        case .delete: return .delete
        }
    }
}

/// A simulated real-time channel: a WebSocket, an EventSource stream or a Socket.IO connection of the page or of the
/// development server, answered from the same scenario state as the REST rules. Declarative, never code an agent wrote.
struct StudioChannel: Codable, Hashable, Identifiable, Sendable {
    /// How messages are framed on the connection.
    enum Wire: String, Codable, Sendable, CaseIterable {
        /// JSON or text messages as they are (and server-sent events).
        case raw
        /// Socket.IO v4 over Engine.IO v4, on a WebSocket or HTTP long-polling.
        case socketio
        /// Phoenix channels, as Supabase Realtime uses them (`phx_join`, heartbeats, `postgres_changes`, broadcast).
        case phoenix
        /// GraphQL over WebSocket: `graphql-transport-ws` (graphql-ws) and the older `graphql-ws` (subscriptions-transport-ws).
        case graphqlWS = "graphql-ws"
    }

    var id: String
    /// A path on the application's origin (`/socket`, `/socket.io`, `:name` and `*` allowed) or a full URL
    /// (`wss://abc.supabase.co/realtime/v1/websocket`); ws/wss and http/https name the same service.
    var path: String
    var wire = Wire.raw
    /// Sent when the connection opens (Socket.IO: when a namespace connects; Phoenix: when a topic is joined).
    var onConnect: [StudioChannelMessage] = []
    /// Answers to what the client sends: the first rule whose `match` fits.
    var onMessage: [StudioChannelReply] = []
    /// Pushed after a delay, once or repeatedly, while the connection is open.
    var events: [StudioChannelEvent] = []
    /// Pushed when an entity is written by any request (REST, GraphQL or a channel message).
    var links: [StudioChannelLink] = []
    var evidence: [StudioEvidence] = []
    var origin = StudioRule.Origin.agent

    enum CodingKeys: String, CodingKey {
        case id, path, wire = "protocol", onConnect, onMessage, events, links, evidence, origin
    }

    var isUsable: Bool { !id.isEmpty && !path.isEmpty }
}

/// One message a channel sends. `data` is JSON (sent as JSON text) or a string (sent as it is); `{{name}}` placeholders
/// take the values of the moment: `record`, `old`, `message`, `type`, `entity`, `params`, `query`, `now`, `uuid`, `seq`.
struct StudioChannelMessage: Codable, Hashable, Sendable {
    /// Socket.IO event name (`data` is its one argument, or the acknowledgement's), Phoenix event or SSE event type;
    /// plain WebSocket messages have none.
    var event: String? = nil
    /// Phoenix topic (`realtime:public:messages`) or Socket.IO namespace (`/chat`); nil: the connection's own.
    var topic: String? = nil
    var data = StudioJSON.null
    var delayMs: Int? = nil
}

/// An answer to a client message.
struct StudioChannelReply: Codable, Hashable, Sendable {
    /// Fields of the client's message by dotted path (`type`, `payload.event`) and their values; `"*"` is any value. Empty:
    /// every message. Socket.IO messages read as `{event, data, args, topic}`, Phoenix ones as `{topic, event, payload}`.
    var match: [String: StudioJSON] = [:]
    /// Sent back to the client (Socket.IO: the acknowledgement when it asked for one and the message has no event).
    var reply: [StudioChannelMessage] = []
    /// Sent to every other connection of the channel.
    var broadcast: [StudioChannelMessage] = []
    /// A message that writes the state: the entity and the write.
    var entity: String? = nil
    var operation: StudioChannelWrite? = nil
    /// Where the record is in the message (dotted path); default `data`, then `payload`, then the message itself.
    var recordPath: String? = nil
}

/// A message pushed on a timer while a connection is open.
struct StudioChannelEvent: Codable, Hashable, Sendable {
    var afterMs = 0
    /// Repeats every `everyMs` (at least 250) up to `count` times (at most 1,000).
    var everyMs: Int? = nil
    var count: Int? = nil
    var message = StudioChannelMessage()
}

/// A write of an entity pushed to the channel's connections.
struct StudioChannelLink: Codable, Hashable, Sendable {
    var entity: String
    var on: [StudioChannelWrite] = StudioChannelWrite.allCases
    /// The message pushed; nil on a Phoenix channel: Supabase's `postgres_changes` to the topics subscribed to the table.
    var message: StudioChannelMessage? = nil
    /// The table name in `postgres_changes` (default: the entity).
    var table: String? = nil
}

/// Lenient, because one damaged rule must not make environment.json unreadable: unknown values fall back to defaults,
/// damaged list elements are left out, and a channel without an id or a path is ignored where channels are used.
extension StudioChannel {
    init(from decoder: Decoder) throws {
        let read = StudioLenient<CodingKeys>(decoder)
        id = read.value(.id) ?? ""
        path = read.value(.path) ?? ""
        wire = read.value(.wire) ?? .raw
        onConnect = read.list(.onConnect)
        onMessage = read.list(.onMessage)
        events = read.list(.events)
        links = read.list(.links)
        evidence = read.list(.evidence)
        origin = read.value(.origin) ?? .agent
    }
}

extension StudioChannelMessage {
    private enum Keys: String, CodingKey { case event, topic, data, delayMs }

    init(from decoder: Decoder) throws {
        let read = StudioLenient<Keys>(decoder)
        guard read.isObject else { throw StudioLenientError.notAnObject }
        event = read.value(.event)
        topic = read.value(.topic)
        data = read.value(.data) ?? .null
        delayMs = read.value(.delayMs)
    }
}

extension StudioChannelReply {
    private enum Keys: String, CodingKey { case match, reply, broadcast, entity, operation, recordPath }

    init(from decoder: Decoder) throws {
        let read = StudioLenient<Keys>(decoder)
        guard read.isObject else { throw StudioLenientError.notAnObject }
        match = read.value(.match) ?? [:]
        reply = read.list(.reply)
        broadcast = read.list(.broadcast)
        entity = read.value(.entity)
        operation = read.value(.operation)
        recordPath = read.value(.recordPath)
    }
}

extension StudioChannelEvent {
    private enum Keys: String, CodingKey { case afterMs, everyMs, count, message }

    init(from decoder: Decoder) throws {
        let read = StudioLenient<Keys>(decoder)
        guard read.isObject else { throw StudioLenientError.notAnObject }
        afterMs = read.value(.afterMs) ?? 0
        everyMs = read.value(.everyMs)
        count = read.value(.count)
        message = read.value(.message) ?? StudioChannelMessage()
    }
}

extension StudioChannelLink {
    private enum Keys: String, CodingKey { case entity, on, message, table }

    init(from decoder: Decoder) throws {
        let read = StudioLenient<Keys>(decoder)
        guard read.isObject else { throw StudioLenientError.notAnObject }
        entity = read.value(.entity) ?? ""
        let given: [StudioChannelWrite] = read.list(.on)
        on = given.isEmpty ? StudioChannelWrite.allCases : given
        message = read.value(.message)
        table = read.value(.table)
    }
}

// MARK: - Templates and matching

enum StudioChannelTemplate {
    /// `template` with its `{{path}}` placeholders filled from `values`. A string that is one placeholder takes the value
    /// itself (an object stays an object); placeholders inside a longer string are written as text.
    static func fill(_ template: StudioJSON, _ values: [String: StudioJSON]) -> StudioJSON {
        switch template {
        case .string(let text):
            guard text.contains("{{") else { return template }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}"), trimmed.dropFirst(2).dropLast(2).contains("{{") == false {
                return lookup(String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces), values) ?? .null
            }
            guard let expression = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_.\-]+)\s*\}\}"#) else { return template }
            var result = text
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let whole = Range(match.range, in: result), let name = Range(match.range(at: 1), in: text) else { continue }
                result.replaceSubrange(whole, with: lookup(String(text[name]), values).map(plain) ?? "")
            }
            return .string(result)
        case .array(let items):
            return .array(items.map { fill($0, values) })
        case .object(let fields):
            return .object(fields.mapValues { fill($0, values) })
        default:
            return template
        }
    }

    /// The value at a dotted path: `record.title`, `message.payload.0`.
    static func lookup(_ path: String, _ values: [String: StudioJSON]) -> StudioJSON? {
        let parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first, let start = values[first] else { return nil }
        return value(at: parts.dropFirst(), in: start)
    }

    static func value<Parts: Sequence>(at parts: Parts, in json: StudioJSON) -> StudioJSON? where Parts.Element == String {
        var current = json
        for part in parts {
            if let array = current.arrayValue, let index = Int(part) {
                guard index >= 0, index < array.count else { return nil }
                current = array[index]
            } else if let next = current[part] {
                current = next
            } else {
                return nil
            }
        }
        return current
    }

    /// A value as text: a string as it is, anything else as JSON.
    static func plain(_ value: StudioJSON) -> String {
        if case .string(let text) = value { return text }
        return value.text
    }

    /// Whether `message` has every field of `match` (`"*"`: any value). A text message matches on `text`.
    static func matches(_ match: [String: StudioJSON], _ message: StudioJSON) -> Bool {
        match.allSatisfy { path, expected in
            let found: StudioJSON?
            if case .string = message, path == "text" { found = message } else { found = value(at: path.split(separator: ".").map(String.init), in: message) }
            guard let found else { return false }
            if expected == .string("*") { return true }
            return found == expected || (found.identityKey != nil && found.identityKey == expected.identityKey)
        }
    }
}

/// Where channels and GraphQL endpoints are, in the same terms as REST rules.
enum StudioChannelRoute {
    /// ws → http and wss → https, so a channel and a REST rule name a service the same way.
    static func httpURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased() else { return url }
        if scheme == "ws" { components.scheme = "http" } else if scheme == "wss" { components.scheme = "https" }
        return components.url ?? url
    }

    static func httpPattern(_ pattern: String) -> String {
        let lowered = pattern.lowercased()
        if lowered.hasPrefix("ws://") { return "http://" + pattern.dropFirst(5) }
        if lowered.hasPrefix("wss://") { return "https://" + pattern.dropFirst(6) }
        return pattern
    }

    /// `scheme://host[:port]` of an http(s) or ws(s) URL, as http(s).
    static func origin(of url: URL) -> String? {
        let url = httpURL(url)
        return url.scheme.flatMap { scheme in url.host.map { "\(scheme)://\($0)" + (url.port.map { ":\($0)" } ?? "") } }
    }

    /// The most specific usable channel at `url`, with its path parameters.
    static func channel(for url: URL, in channels: [StudioChannel], appOrigin: String?) -> (StudioChannel, [String: String])? {
        let origin = origin(of: url)
        let path = url.path.isEmpty ? "/" : url.path
        let candidates = channels.compactMap { channel -> (StudioChannel, [String: String])? in
            guard channel.isUsable else { return nil }
            let (ruleOrigin, pattern) = StudioRoute.split(httpPattern(channel.path))
            if let ruleOrigin { guard ruleOrigin == origin else { return nil } } else if appOrigin != nil, origin != appOrigin { return nil }
            return StudioRoute.match(pattern: pattern, path: path).map { (channel, $0) }
        }
        return candidates.max { StudioRoute.specificity($0.0.path) < StudioRoute.specificity($1.0.path) }
    }

    /// The contract of a channel nobody answers yet: `WS /socket`, `SSE https://api.example.com/events`,
    /// `ON http://electron.ipc/desk/settings/onDocumentApplied`.
    static func contract(_ transport: StudioChannelTransport, url: URL, appOrigin: String?) -> String {
        let method = transport == .eventSource ? "SSE" : transport == .ipc ? "ON" : "WS"
        return StudioRoute.contractKey(method: method, url: httpURL(url), appOrigin: appOrigin)
    }
}

// MARK: - Connections

enum StudioChannelTransport: String, Sendable {
    case webSocket = "websocket"
    case eventSource = "sse"
    /// Engine.IO's HTTP long-polling.
    case polling
    /// A callback the page passed to the Electron preload bridge (REQ-016): it gets every message's data.
    case ipc

    var label: String {
        switch self {
        case .webSocket: return "WebSocket"
        case .eventSource: return "EventSource"
        case .polling: return "Socket.IO polling"
        case .ipc: return "IPC callback"
        }
    }
}

/// A write of the state, as channels and subscriptions see it.
struct StudioEntityChange: Equatable, Sendable {
    var entity: String
    var kind: StudioChannelWrite
    /// The record after the write (create, update).
    var record: StudioJSON?
    /// The record before it (update, delete).
    var old: StudioJSON?

    /// The writes between two states, by record id: new ids are created, changed records updated, missing ids deleted.
    static func diff(before: [String: [StudioJSON]], after: [String: [StudioJSON]], spec: StudioEnvironmentSpec) -> [StudioEntityChange] {
        var changes: [StudioEntityChange] = []
        for name in Set(before.keys).union(after.keys).sorted() {
            let old = before[name] ?? [], new = after[name] ?? []
            guard old != new else { continue }
            let idField = spec.entity(name)?.idField ?? "id"
            let oldByID = Dictionary(old.compactMap { record in record[idField]?.identityKey.map { ($0, record) } }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            for record in new {
                guard let id = record[idField]?.identityKey, seen.insert(id).inserted else { continue }
                if let previous = oldByID[id] {
                    if previous != record { changes.append(StudioEntityChange(entity: name, kind: .update, record: record, old: previous)) }
                } else {
                    changes.append(StudioEntityChange(entity: name, kind: .create, record: record, old: nil))
                }
            }
            for record in old {
                guard let id = record[idField]?.identityKey, !seen.contains(id) else { continue }
                seen.insert(id)
                changes.append(StudioEntityChange(entity: name, kind: .delete, record: nil, old: record))
            }
        }
        return changes
    }
}

/// One open connection of a channel and what its protocol remembers.
struct StudioChannelConnection: Sendable {
    struct Join: Sendable {
        var joinRef: StudioJSON
        /// The client's `postgres_changes` bindings, each with the id the reply gave it.
        var bindings: [StudioJSON]
        var broadcastSelf: Bool
        var broadcastAck: Bool
    }

    struct Subscription: Sendable {
        var field: StudioGraphQLField
        var operation: StudioGraphQLOperation
        var fragments: [String: [StudioGraphQLSelection]]
        var variables: [String: StudioJSON]
    }

    let id: String
    let channelID: String
    let transport: StudioChannelTransport
    /// `page` or `server`.
    let source: String
    let url: URL
    let shown: String
    var parameters: [String: String]
    var subprotocol: String?
    // Socket.IO
    var sid = ""
    var namespaces: Set<String> = []
    var outbox: [String] = []
    // Phoenix
    var joins: [String: Join] = [:]
    var arrays = false
    // GraphQL over WebSocket
    var subscriptions: [String: Subscription] = [:]
    var legacyGraphQL = false
    var received = 0
}

/// The session's simulated channels (REQ-015): connections of the page (through the bridge) and of the development server
/// (through the gateway), answered by the channel rules over the scenario state. Each connection has a sink that carries
/// frames the session pushes on its own (timers, broadcasts, entity links, subscriptions); a client message is answered
/// with the frames `receive` returns. Every open, close and message is logged, redacted and bounded.
@MainActor
final class StudioChannelHub {
    typealias Sink = ([StudioChannelFrame]) -> Void

    nonisolated static let maxConnections = 64
    /// IPC callbacks waiting for a channel (REQ-016).
    nonisolated static let maxListeners = 200
    nonisolated static let maxMessage = 1_000_000
    nonisolated static let maxMessagesPerConnection = 20_000
    nonisolated static let minEveryMs = 250
    nonisolated static let maxEventCount = 1_000
    nonisolated static let pingInterval = 25_000
    nonisolated static let pingTimeout = 20_000

    struct Environment {
        var spec: () -> StudioEnvironmentSpec
        var state: () -> [String: [StudioJSON]]
        var appOrigin: () -> String?
        /// A write of the state through the simulation (`StudioSimulator.perform`).
        var perform: (StudioRule.Operation, String, String?, StudioJSON) -> StudioSimResponse
        /// A GraphQL query or mutation (`{query, variables, operationName}`) answered by the simulation at `url`: `{data, errors}`.
        var graphQL: (URL, StudioJSON) -> StudioJSON
        var redact: (StudioJSON) -> StudioJSON
        var log: (String, Bool) -> Void
        var now: () -> Date = Date.init
    }

    enum Opening: Equatable {
        case accepted(protocol: String?, frames: [StudioChannelFrame])
        /// No channel rule answers the URL yet.
        case unknown(contract: String)
        case refused(String)
    }

    var environment: Environment
    private(set) var connections: [String: StudioChannelConnection] = [:]
    private var sinks: [String: Sink] = [:]
    private var timers: [String: [Task<Void, Never>]] = [:]
    private var waiting: [String: (StudioSimResponse) -> Void] = [:]
    /// Connections waiting for a channel to answer their address, by id (`listen`).
    private var listeners: [String: Listener] = [:]
    private var sequence = 0

    private struct Listener {
        var url: URL
        var transport: StudioChannelTransport
        var source: String
        var shown: String
        var sink: Sink
    }

    init(environment: Environment) {
        self.environment = environment
    }

    var channels: [StudioChannel] { (environment.spec().channels ?? []).filter(\.isUsable) }

    func channel(for url: URL) -> (StudioChannel, [String: String])? {
        StudioChannelRoute.channel(for: url, in: channels, appOrigin: environment.appOrigin())
    }

    private func channel(_ connection: StudioChannelConnection) -> StudioChannel? {
        channels.first { $0.id == connection.channelID }
    }

    // MARK: Open, receive, close

    /// Opens connection `id` to `url` when a channel answers it.
    func open(id: String, url: URL, protocols: [String], transport: StudioChannelTransport, source: String, shown: String,
              sink: @escaping Sink) -> Opening {
        guard connections[id] == nil else { return .refused("The connection is already open.") }
        guard connections.count < Self.maxConnections else { return .refused("More than \(Self.maxConnections) simulated connections are open.") }
        guard let (channel, parameters) = channel(for: url) else {
            return .unknown(contract: StudioChannelRoute.contract(transport, url: url, appOrigin: environment.appOrigin()))
        }
        var connection = StudioChannelConnection(id: id, channelID: channel.id, transport: transport, source: source, url: url, shown: shown,
                                                 parameters: parameters)
        connection.sid = Self.randomID(20)
        switch channel.wire {
        case .graphqlWS:
            connection.subprotocol = protocols.first { $0 == "graphql-transport-ws" } ?? protocols.first { $0 == "graphql-ws" } ?? protocols.first
            connection.legacyGraphQL = connection.subprotocol == "graphql-ws"
        case .phoenix:
            connection.arrays = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "vsn" }?.value?.hasPrefix("2") == true
            connection.subprotocol = protocols.first
        default:
            connection.subprotocol = protocols.first
        }
        connections[id] = connection
        sinks[id] = sink
        environment.log("\(transport.label) \(shown) · \(source) · open · \(channel.wire.rawValue) channel \(channel.id)", false)
        var frames: [StudioChannelFrame] = []
        switch channel.wire {
        case .raw:
            frames = messages(channel.onConnect, to: id, values: [:])
        case .socketio:
            if transport != .polling { frames = [.text("0" + Self.engineOpen(connection.sid))] }
            startPinging(id)
        case .phoenix, .graphqlWS:
            break
        }
        schedule(channel.events, for: id)
        return .accepted(protocol: connection.subprotocol, frames: frames)
    }

    /// Opens connection `id` like `open`, or keeps it waiting while no channel answers its address. A callback of the
    /// Electron preload bridge (REQ-016) is the page's own function: it is never refused or prepared, and it gets what a
    /// channel registered later pushes (`openListeners`).
    func listen(id: String, url: URL, transport: StudioChannelTransport, source: String, shown: String, sink: @escaping Sink) -> Opening {
        guard listeners[id] == nil else { return .refused("The connection is already open.") }
        let opening = open(id: id, url: url, protocols: [], transport: transport, source: source, shown: shown, sink: sink)
        guard case .unknown = opening else { return opening }
        guard listeners.count < Self.maxListeners else { return .refused("More than \(Self.maxListeners) callbacks wait for a simulated channel.") }
        listeners[id] = Listener(url: url, transport: transport, source: source, shown: shown, sink: sink)
        environment.log("\(transport.label) \(shown) · \(source) · listening: no simulated channel pushes to it yet", false)
        return .accepted(protocol: nil, frames: [])
    }

    /// Opens the waiting connections a channel answers now (after rules were registered); what the channel sends when one
    /// opens goes through its sink.
    func openListeners() {
        for (id, listener) in listeners.sorted(by: { $0.key < $1.key }) where channel(for: listener.url) != nil {
            listeners[id] = nil
            let opening = open(id: id, url: listener.url, protocols: [], transport: listener.transport, source: listener.source,
                               shown: listener.shown, sink: listener.sink)
            if case .accepted(_, let frames) = opening, !frames.isEmpty { listener.sink(frames) }
        }
    }

    /// A text message of the client; returns the frames that answer it on the same connection.
    func receive(id: String, text: String) -> [StudioChannelFrame] {
        guard var connection = connections[id], let channel = channel(connection) else { return [] }
        connection.received += 1
        connections[id] = connection
        if text.utf8.count > Self.maxMessage { return closing(id, code: 1009, reason: "The message is larger than \(Self.maxMessage) bytes.") }
        if connection.received > Self.maxMessagesPerConnection { return closing(id, code: 1008, reason: "Too many messages on one connection.") }
        switch channel.wire {
        case .raw:
            logMessage(id, "→", StudioJSON(text: text) ?? .string(text))
            return answer(channel, id: id, message: StudioJSON(text: text) ?? .string(text), values: [:]).frames
        case .socketio:
            return engineIO(channel, id: id, packet: text)
        case .phoenix:
            return phoenix(channel, id: id, text: text)
        case .graphqlWS:
            return graphQL(channel, id: id, text: text)
        }
    }

    /// A binary message: kept as base64 under `binary` for raw channels; other protocols here are text only.
    func receive(id: String, binary: Data) -> [StudioChannelFrame] {
        guard let connection = connections[id], let channel = channel(connection) else { return [] }
        guard binary.count <= Self.maxMessage else { return closing(id, code: 1009, reason: "The message is larger than \(Self.maxMessage) bytes.") }
        guard channel.wire == .raw else {
            environment.log("\(connection.shown) · \(connection.source) · a binary message (\(binary.count) bytes) on a \(channel.wire.rawValue) channel is not simulated", true)
            return []
        }
        let message = StudioJSON.object(["binary": .string(binary.base64EncodedString()), "size": .number(Double(binary.count))])
        environment.log("\(connection.shown) · \(connection.source) · → binary message (\(binary.count) bytes)", false)
        return answer(channel, id: id, message: message, values: [:]).frames
    }

    /// The client closed the connection (or went away).
    func close(id: String, code: Int?) {
        if let listener = listeners.removeValue(forKey: id) {
            environment.log("\(listener.shown) · \(listener.source) · closed", false)
            return
        }
        guard let connection = connections.removeValue(forKey: id) else { return }
        sinks[id] = nil
        timers.removeValue(forKey: id)?.forEach { $0.cancel() }
        waiting.removeValue(forKey: id)?(Self.plain(200, "1"))
        environment.log("\(connection.shown) · \(connection.source) · closed\(code.map { " \($0)" } ?? "")", false)
    }

    /// The session closes connections: a new page (no frame is sent, the page is gone) or a Reset (a close frame, so the
    /// client connects again and gets the new baseline).
    func closeAll(source: String? = nil, code: Int? = nil, reason: String = "") {
        listeners = listeners.filter { source != nil && $0.value.source != source }
        for (id, connection) in connections where source == nil || connection.source == source {
            if let code { sinks[id]?([.close(code: code, reason: reason)]) }
            close(id: id, code: code)
        }
    }

    private func closing(_ id: String, code: Int, reason: String) -> [StudioChannelFrame] {
        let shown = connections[id]?.shown ?? id
        environment.log("\(shown) · closed by MarkView \(code): \(reason)", true)
        close(id: id, code: code)
        return [.close(code: code, reason: reason)]
    }

    // MARK: Messages

    private func baseValues(_ id: String, extra: [String: StudioJSON]) -> [String: StudioJSON] {
        sequence += 1
        var values: [String: StudioJSON] = [
            "now": .string(ISO8601DateFormatter().string(from: environment.now())), "uuid": .string(UUID().uuidString.lowercased()),
            "seq": .number(Double(sequence)),
        ]
        if let connection = connections[id] {
            values["connection"] = .string(connection.id)
            values["sid"] = .string(connection.sid)
            values["params"] = .object(connection.parameters.mapValues { .string($0) })
            let items = URLComponents(url: connection.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            values["query"] = .object(Dictionary(items.map { ($0.name, StudioJSON.string($0.value ?? "")) }, uniquingKeysWith: { first, _ in first }))
        }
        return values.merging(extra) { _, new in new }
    }

    /// The frames of `messages` for connection `id`; delayed ones are pushed later through its sink.
    private func messages(_ messages: [StudioChannelMessage], to id: String, values extra: [String: StudioJSON],
                          ack: (String, String)? = nil, replyRef: (StudioJSON, StudioJSON)? = nil) -> [StudioChannelFrame] {
        var now: [StudioChannelFrame] = []
        var ackUsed = false
        for message in messages {
            let values = baseValues(id, extra: extra)
            var filled = message
            filled.data = StudioChannelTemplate.fill(message.data, values)
            filled.topic = message.topic.map { StudioChannelTemplate.plain(StudioChannelTemplate.fill(.string($0), values)) }
            var frames: [StudioChannelFrame]
            if let ack, !ackUsed, message.event == nil {
                ackUsed = true
                frames = [.text("43" + Self.namespacePrefix(ack.0) + ack.1 + StudioJSON.array(filled.data.isNull ? [] : [filled.data]).text)]
            } else if let replyRef, message.event == nil, channelWire(id) == .phoenix {
                frames = [phoenixFrame(id, joinRef: replyRef.0, ref: replyRef.1, topic: filled.topic ?? extra["topic"]?.stringValue ?? "phoenix",
                                       event: "phx_reply", payload: .object(["status": .string("ok"), "response": filled.data]))]
            } else {
                frames = encode(filled, for: id, defaultTopic: extra["topic"]?.stringValue)
            }
            if let delay = message.delayMs, delay > 0 {
                later(id, frames, delayMs: delay)
            } else {
                now += frames
            }
        }
        for frame in now { logFrame(id, frame) }
        return now
    }

    private func channelWire(_ id: String) -> StudioChannel.Wire? { connections[id].flatMap(channel)?.wire }

    /// A filled message in the connection's protocol.
    private func encode(_ message: StudioChannelMessage, for id: String, defaultTopic: String?) -> [StudioChannelFrame] {
        guard let connection = connections[id], let wire = channel(connection)?.wire else { return [] }
        switch wire {
        case .raw, .graphqlWS:
            // A raw WebSocket's `binary` event carries base64 bytes, sent as a binary message.
            if wire == .raw, connection.transport == .webSocket, message.event == "binary",
               let data = message.data.stringValue.flatMap({ Data(base64Encoded: $0) }) {
                return [.binary(data)]
            }
            let text = StudioChannelTemplate.plain(message.data)
            return [connection.transport == .eventSource ? .event(name: message.event, data: text, id: nil) : .text(text)]
        case .socketio:
            let namespace = message.topic ?? defaultTopic ?? "/"
            // Nothing reaches a namespace before the client connects it.
            guard connection.namespaces.contains(namespace) else { return [] }
            let arguments = message.data.isNull ? [] : [message.data]
            return [.text("42" + Self.namespacePrefix(namespace) + StudioJSON.array([.string(message.event ?? "message")] + arguments).text)]
        case .phoenix:
            let topics = message.topic.map { [$0] } ?? defaultTopic.map { [$0] } ?? Array(connection.joins.keys).sorted()
            return topics.map { topic in
                phoenixFrame(id, joinRef: connection.joins[topic]?.joinRef ?? .null, ref: .null, topic: topic, event: message.event ?? "broadcast",
                             payload: message.data)
            }
        }
    }

    /// The first `onMessage` rule that fits `message`: its write, its broadcast and the frames of its reply.
    private func answer(_ channel: StudioChannel, id: String, message: StudioJSON, values extra: [String: StudioJSON],
                        ack: (String, String)? = nil, replyRef: (StudioJSON, StudioJSON)? = nil) -> (frames: [StudioChannelFrame], matched: Bool) {
        guard let rule = channel.onMessage.first(where: { StudioChannelTemplate.matches($0.match, message) }) else {
            let shown = connections[id]?.shown ?? id
            environment.log("\(shown) · no channel rule answers this message; it was received and not answered", false)
            return ([], false)
        }
        var values = extra
        values["message"] = message
        if let entity = rule.entity, let operation = rule.operation {
            let record = rule.recordPath.flatMap { StudioChannelTemplate.value(at: $0.split(separator: ".").map(String.init), in: message) }
                ?? message["data"] ?? message["payload"] ?? message
            let idField = environment.spec().entity(entity)?.idField ?? "id"
            let response = environment.perform(operation.operation, entity, record[idField]?.identityKey, record)
            let body = response.body.flatMap { StudioJSON(text: $0) } ?? .null
            if (200..<300).contains(response.status) {
                values["record"] = operation == .delete ? record : body
            } else {
                values["error"] = body
                environment.log("\(connections[id]?.shown ?? id) · the message's \(operation.rawValue) of \(entity) failed (\(response.status)): \(StudioChannelTemplate.plain(environment.redact(body)).prefix(300))", true)
            }
        }
        if !rule.broadcast.isEmpty {
            for other in connections.values where other.channelID == channel.id && other.id != id {
                let frames = messages(rule.broadcast, to: other.id, values: values)
                if !frames.isEmpty { sinks[other.id]?(frames) }
            }
        }
        return (messages(rule.reply, to: id, values: values, ack: ack, replyRef: replyRef), true)
    }

    private func push(_ id: String, _ frames: [StudioChannelFrame]) {
        guard !frames.isEmpty, connections[id] != nil else { return }
        sinks[id]?(frames)
    }

    private func later(_ id: String, _ frames: [StudioChannelFrame], delayMs: Int) {
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(delayMs, 600_000)) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            frames.forEach { self.logFrame(id, $0) }
            self.push(id, frames)
        }
        timers[id, default: []].append(task)
    }

    private func schedule(_ events: [StudioChannelEvent], for id: String) {
        for event in events {
            let limit = event.everyMs == nil ? 1 : min(max(event.count ?? Self.maxEventCount, 1), Self.maxEventCount)
            let every = max(Self.minEveryMs, event.everyMs ?? 0)
            let task = Task { @MainActor [weak self] in
                var wait = max(0, min(event.afterMs, 600_000))
                for fired in 0..<limit {
                    try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
                    guard !Task.isCancelled, let self, self.connections[id] != nil else { return }
                    let frames = self.messages([event.message], to: id, values: ["count": .number(Double(fired + 1))])
                    self.push(id, frames)
                    wait = every
                }
            }
            timers[id, default: []].append(task)
        }
    }

    // MARK: Logging

    private func logMessage(_ id: String, _ direction: String, _ message: StudioJSON) {
        guard let connection = connections[id] else { return }
        let text = StudioChannelTemplate.plain(environment.redact(message))
        environment.log("\(connection.shown) · \(connection.source) · \(direction) \(text.count > 300 ? String(text.prefix(300)) + "…" : text)", false)
    }

    private func logFrame(_ id: String, _ frame: StudioChannelFrame) {
        switch frame {
        case .text(let text):
            if text == "2" || text == "3" || text.contains("\"heartbeat\"") { return }
            logMessage(id, "←", StudioJSON(text: text) ?? .string(text))
        case .event(_, let data, _):
            logMessage(id, "←", StudioJSON(text: data) ?? .string(data))
        case .binary(let data):
            if let connection = connections[id] { environment.log("\(connection.shown) · \(connection.source) · ← binary (\(data.count) bytes)", false) }
        case .close:
            break
        }
    }

    // MARK: Entity links and subscriptions

    /// Writes of the state, from any request: the channels' links and the GraphQL subscriptions push them.
    func entitiesChanged(_ changes: [StudioEntityChange]) {
        guard !changes.isEmpty, !connections.isEmpty else { return }
        for change in changes {
            let values: [String: StudioJSON] = [
                "record": change.record ?? .null, "old": change.old ?? .null, "entity": .string(change.entity),
                "event": .string(change.kind.rawValue), "type": .string(Self.sqlType(change.kind)),
            ]
            for id in connections.keys.sorted() {
                guard let connection = connections[id], let channel = channel(connection) else { continue }
                var templated = false
                for link in channel.links where link.entity == change.entity && link.on.contains(change.kind) {
                    if let message = link.message {
                        templated = true
                        push(id, messages([message], to: id, values: values))
                    } else if channel.wire == .phoenix {
                        templated = true
                        push(id, postgresChanges(id, change, table: link.table ?? change.entity))
                    }
                }
                if channel.wire == .phoenix, !templated, !channel.links.contains(where: { $0.entity == change.entity }) {
                    push(id, postgresChanges(id, change, table: change.entity))
                }
                if channel.wire == .graphqlWS { push(id, subscriptionFrames(id, change)) }
            }
        }
    }

    nonisolated static func sqlType(_ kind: StudioChannelWrite) -> String {
        switch kind {
        case .create: return "INSERT"
        case .update: return "UPDATE"
        case .delete: return "DELETE"
        }
    }

    // MARK: Socket.IO (Engine.IO v4)

    nonisolated static func engineOpen(_ sid: String) -> String {
        StudioJSON.object([
            "sid": .string(sid), "upgrades": .array([]), "pingInterval": .number(Double(pingInterval)),
            "pingTimeout": .number(Double(pingTimeout)), "maxPayload": .number(Double(maxMessage)),
        ]).text
    }

    nonisolated static func namespacePrefix(_ namespace: String) -> String { namespace == "/" || namespace.isEmpty ? "" : namespace + "," }

    private func startPinging(_ id: String) {
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval) * 1_000_000)
                guard !Task.isCancelled, let self, self.connections[id] != nil else { return }
                self.push(id, [.text("2")])
            }
        }
        timers[id, default: []].append(task)
    }

    /// One Engine.IO packet: ping, pong, close, or a Socket.IO packet (connect, disconnect, event with or without an ack).
    private func engineIO(_ channel: StudioChannel, id: String, packet: String) -> [StudioChannelFrame] {
        guard let type = packet.first else { return [] }
        switch type {
        case "2": return [.text("3" + packet.dropFirst())]
        case "1":
            close(id: id, code: 1000)
            return []
        case "4": break
        default: return []
        }
        var rest = Substring(packet.dropFirst())
        guard let kind = rest.first else { return [] }
        rest = rest.dropFirst()
        if let dash = rest.firstIndex(of: "-"), rest[..<dash].allSatisfy(\.isNumber), !rest[..<dash].isEmpty { rest = rest[rest.index(after: dash)...] }
        var namespace = "/"
        if rest.hasPrefix("/") {
            let end = rest.firstIndex(of: ",") ?? rest.endIndex
            namespace = String(rest[..<end])
            rest = end < rest.endIndex ? rest[rest.index(after: end)...] : ""
        }
        let ackDigits = rest.prefix { $0.isNumber }
        let ackID = ackDigits.isEmpty ? nil : String(ackDigits)
        rest = rest.dropFirst(ackDigits.count)
        let payload = rest.isEmpty ? StudioJSON.null : (StudioJSON(text: String(rest)) ?? .null)
        switch kind {
        case "0":
            connections[id]?.namespaces.insert(namespace)
            let sid = Self.randomID(20)
            var frames: [StudioChannelFrame] = [.text("40" + Self.namespacePrefix(namespace) + StudioJSON.object(["sid": .string(sid)]).text)]
            logMessage(id, "→", .object(["connect": .string(namespace)]))
            let greeting = channel.onConnect.filter { ($0.topic ?? "/") == namespace }
            frames += messages(greeting, to: id, values: ["topic": .string(namespace), "auth": payload])
            return frames
        case "1":
            connections[id]?.namespaces.remove(namespace)
            return []
        case "2", "5":
            let arguments = payload.arrayValue ?? []
            let message = StudioJSON.object([
                "event": arguments.first ?? .null, "data": arguments.count > 1 ? arguments[1] : .null,
                "args": .array(Array(arguments.dropFirst())), "topic": .string(namespace),
            ])
            logMessage(id, "→", message)
            var frames = answer(channel, id: id, message: message, values: ["topic": .string(namespace)], ack: ackID.map { (namespace, $0) }).frames
            // An emit with a callback always gets its acknowledgement, empty when no rule gives one.
            if let ackID, !frames.contains(where: { if case .text(let text) = $0 { return text.hasPrefix("43") }; return false }) {
                frames.append(.text("43" + Self.namespacePrefix(namespace) + ackID + "[]"))
            }
            return frames
        default:
            return []
        }
    }

    /// Engine.IO's HTTP long-polling transport (Socket.IO's default first transport): the handshake, a POST of the client's
    /// packets, and a GET that waits for the server's packets (a ping comes every `pingInterval`). Returns false when
    /// `http` is not a polling request of a Socket.IO channel.
    func poll(_ http: StudioHTTPRequest, source: String, shown: String, reply: @escaping (StudioSimResponse) -> Void) -> Bool {
        let query = http.query
        guard query["EIO"] == "4", query["transport"] == "polling", let (channel, _) = channel(for: http.url), channel.wire == .socketio else {
            return false
        }
        guard let sid = query["sid"] else {
            guard http.method == "GET" else {
                reply(.json(400, .object(["code": .number(2), "message": .string("Bad handshake method")])))
                return true
            }
            sequence += 1
            let id = "eio-\(sequence)-" + Self.randomID(6)
            switch open(id: id, url: http.url, protocols: [], transport: .polling, source: source, shown: shown,
                        sink: { [weak self] frames in self?.enqueue(id, frames) }) {
            case .accepted:
                reply(Self.plain(200, "0" + Self.engineOpen(connections[id]?.sid ?? "")))
            case .refused(let reason), .unknown(let reason):
                reply(.json(503, .object(["code": .number(4), "message": .string(reason)])))
            }
            return true
        }
        guard let id = connections.first(where: { $0.value.sid == sid && $0.value.transport == .polling })?.key else {
            reply(.json(400, .object(["code": .number(1), "message": .string("Session ID unknown")])))
            return true
        }
        if http.method == "POST" {
            for packet in (http.body ?? "").split(separator: "\u{1e}") {
                guard connections[id] != nil else { break }
                enqueue(id, receive(id: id, text: String(packet)))
            }
            reply(Self.plain(200, "ok"))
            return true
        }
        if let outbox = connections[id]?.outbox, !outbox.isEmpty {
            connections[id]?.outbox = []
            reply(Self.plain(200, outbox.joined(separator: "\u{1e}")))
        } else {
            waiting.removeValue(forKey: id)?(Self.plain(200, "6"))
            waiting[id] = reply
        }
        return true
    }

    private func enqueue(_ id: String, _ frames: [StudioChannelFrame]) {
        guard connections[id] != nil else { return }
        for frame in frames {
            switch frame {
            case .text(let text): connections[id]?.outbox.append(text)
            case .close: connections[id]?.outbox.append("1")
            default: break
            }
        }
        guard let outbox = connections[id]?.outbox, !outbox.isEmpty, let waiter = waiting.removeValue(forKey: id) else { return }
        connections[id]?.outbox = []
        waiter(Self.plain(200, outbox.joined(separator: "\u{1e}")))
    }

    nonisolated static func plain(_ status: Int, _ text: String) -> StudioSimResponse {
        StudioSimResponse(status: status, headers: ["content-type": "text/plain; charset=UTF-8"], body: text)
    }

    // MARK: Phoenix (Supabase Realtime)

    private func phoenixFrame(_ id: String, joinRef: StudioJSON, ref: StudioJSON, topic: String, event: String, payload: StudioJSON) -> StudioChannelFrame {
        if connections[id]?.arrays == true {
            return .text(StudioJSON.array([joinRef, ref, .string(topic), .string(event), payload]).text)
        }
        var object: [String: StudioJSON] = ["topic": .string(topic), "event": .string(event), "payload": payload, "ref": ref]
        if !joinRef.isNull { object["join_ref"] = joinRef }
        return .text(StudioJSON.object(object).text)
    }

    private func phoenix(_ channel: StudioChannel, id: String, text: String) -> [StudioChannelFrame] {
        guard let parsed = StudioJSON(text: text) else { return [] }
        var joinRef = StudioJSON.null, ref = StudioJSON.null, topic = "", event = "", payload = StudioJSON.null
        if let array = parsed.arrayValue, array.count == 5 {
            connections[id]?.arrays = true
            (joinRef, ref, topic, event, payload) = (array[0], array[1], array[2].stringValue ?? "", array[3].stringValue ?? "", array[4])
        } else {
            (joinRef, ref, topic, event, payload) = (parsed["join_ref"] ?? .null, parsed["ref"] ?? .null, parsed["topic"]?.stringValue ?? "",
                                                     parsed["event"]?.stringValue ?? "", parsed["payload"] ?? .null)
        }
        func reply(_ response: StudioJSON, status: String = "ok") -> StudioChannelFrame {
            phoenixFrame(id, joinRef: joinRef, ref: ref, topic: topic, event: "phx_reply",
                         payload: .object(["status": .string(status), "response": response]))
        }
        if topic == "phoenix", event == "heartbeat" { return [reply(.object([:]))] }
        let message = StudioJSON.object(["topic": .string(topic), "event": .string(event), "payload": payload, "ref": ref])
        if event != "access_token" { logMessage(id, "→", message) }
        switch event {
        case "phx_join":
            let config = payload["config"]
            var bindings: [StudioJSON] = []
            for binding in config?["postgres_changes"]?.arrayValue ?? [] {
                guard var object = binding.objectValue else { continue }
                sequence += 1
                object["id"] = .number(Double(10_000_000 + sequence))
                bindings.append(.object(object))
            }
            let join = StudioChannelConnection.Join(joinRef: joinRef.isNull ? ref : joinRef, bindings: bindings,
                                                    broadcastSelf: config?["broadcast"]?["self"]?.boolValue == true,
                                                    broadcastAck: config?["broadcast"]?["ack"]?.boolValue == true)
            connections[id]?.joins[topic] = join
            var frames = [reply(bindings.isEmpty ? .object([:]) : .object(["postgres_changes": .array(bindings)]))]
            if config?["presence"] != nil {
                frames.append(phoenixFrame(id, joinRef: join.joinRef, ref: .null, topic: topic, event: "presence_state", payload: .object([:])))
            }
            if !bindings.isEmpty {
                frames.append(phoenixFrame(id, joinRef: join.joinRef, ref: .null, topic: topic, event: "system", payload: .object([
                    "channel": .string(topic.hasPrefix("realtime:") ? String(topic.dropFirst("realtime:".count)) : topic),
                    "extension": .string("postgres_changes"), "message": .string("Subscribed to PostgreSQL"), "status": .string("ok"),
                ])))
            }
            frames.forEach { logFrame(id, $0) }
            let greeting = channel.onConnect.filter { message in message.topic.map { Self.topic(topic, matches: $0) } ?? true }
                .map { message -> StudioChannelMessage in var copy = message; copy.topic = topic; return copy }
            return frames + messages(greeting, to: id, values: ["topic": .string(topic)])
        case "phx_leave":
            connections[id]?.joins[topic] = nil
            return [reply(.object([:])), phoenixFrame(id, joinRef: joinRef, ref: ref, topic: topic, event: "phx_close", payload: .object([:]))]
        case "access_token":
            return []
        case "broadcast":
            for other in connections.values where other.channelID == channel.id && other.joins[topic] != nil && other.id != id {
                push(other.id, [phoenixFrame(other.id, joinRef: other.joins[topic]?.joinRef ?? .null, ref: .null, topic: topic, event: "broadcast",
                                             payload: payload)])
            }
            var frames: [StudioChannelFrame] = []
            if connections[id]?.joins[topic]?.broadcastSelf == true {
                frames.append(phoenixFrame(id, joinRef: connections[id]?.joins[topic]?.joinRef ?? .null, ref: .null, topic: topic,
                                           event: "broadcast", payload: payload))
            }
            if connections[id]?.joins[topic]?.broadcastAck == true { frames.append(reply(.object([:]))) }
            let rule = channel.onMessage.first { StudioChannelTemplate.matches($0.match, message) }
            if rule != nil { frames += answer(channel, id: id, message: message, values: ["topic": .string(topic)]).frames }
            return frames
        case "presence":
            let key = connections[id]?.sid ?? id
            let metas = StudioJSON.array([(payload["payload"] ?? .object([:])).merging(["phx_ref": .string(Self.randomID(8))])])
            let diff = StudioJSON.object(["joins": .object(payload["event"]?.stringValue == "untrack" ? [:] : [key: .object(["metas": metas])]),
                                          "leaves": .object(payload["event"]?.stringValue == "untrack" ? [key: .object(["metas": metas])] : [:])])
            for other in connections.values where other.channelID == channel.id && other.joins[topic] != nil && other.id != id {
                push(other.id, [phoenixFrame(other.id, joinRef: other.joins[topic]?.joinRef ?? .null, ref: .null, topic: topic,
                                             event: "presence_diff", payload: diff)])
            }
            return [reply(.object([:])), phoenixFrame(id, joinRef: joinRef, ref: .null, topic: topic, event: "presence_diff", payload: diff)]
        default:
            let (frames, matched) = answer(channel, id: id, message: message, values: ["topic": .string(topic)], replyRef: (joinRef, ref))
            // A push the client waits on (`push(...).receive("ok")`) gets an empty ok when no rule answers it.
            if !matched, !ref.isNull { return [reply(.object([:]))] }
            return frames
        }
    }

    /// `realtime:*` and exact topics.
    nonisolated static func topic(_ topic: String, matches pattern: String) -> Bool {
        pattern.hasSuffix("*") ? topic.hasPrefix(String(pattern.dropLast())) : topic == pattern
    }

    /// Supabase's `postgres_changes` for each topic of the connection that subscribed to `table` and to this kind of write.
    private func postgresChanges(_ id: String, _ change: StudioEntityChange, table: String) -> [StudioChannelFrame] {
        guard let connection = connections[id] else { return [] }
        let type = Self.sqlType(change.kind)
        var frames: [StudioChannelFrame] = []
        for topic in connection.joins.keys.sorted() {
            guard let join = connection.joins[topic] else { continue }
            let matching = join.bindings.filter { binding in
                let event = binding["event"]?.stringValue ?? "*"
                let wantedTable = binding["table"]?.stringValue ?? "*"
                guard event == "*" || event.uppercased() == type, wantedTable == "*" || wantedTable == table else { return false }
                return Self.filter(binding["filter"]?.stringValue, passes: change.record ?? change.old ?? .null)
            }
            guard !matching.isEmpty else { continue }
            let schema = matching.first?["schema"]?.stringValue ?? "public"
            var data: [String: StudioJSON] = [
                "schema": .string(schema == "*" ? "public" : schema), "table": .string(table), "type": .string(type), "columns": .array([]),
                "commit_timestamp": .string(ISO8601DateFormatter().string(from: environment.now())), "errors": .null,
            ]
            if let record = change.record { data["record"] = record }
            if let old = change.old { data["old_record"] = old }
            frames.append(phoenixFrame(id, joinRef: join.joinRef, ref: .null, topic: topic, event: "postgres_changes",
                                       payload: .object(["ids": .array(matching.compactMap { $0["id"] }), "data": .object(data)])))
        }
        frames.forEach { logFrame(id, $0) }
        return frames
    }

    /// A Supabase filter: `column=eq.value`, `neq`, `in.(a,b)`; others pass.
    nonisolated static func filter(_ filter: String?, passes record: StudioJSON) -> Bool {
        guard let filter, let equals = filter.firstIndex(of: "=") else { return true }
        let column = String(filter[..<equals])
        let rest = filter[filter.index(after: equals)...]
        guard let dot = rest.firstIndex(of: ".") else { return true }
        let op = String(rest[..<dot]), value = String(rest[rest.index(after: dot)...])
        let actual = record[column]?.identityKey
        switch op {
        case "eq": return actual == value
        case "neq": return actual != value
        case "in": return value.trimmingCharacters(in: CharacterSet(charactersIn: "()")).split(separator: ",").map(String.init).contains(actual ?? "\u{0}")
        default: return true
        }
    }

    // MARK: GraphQL over WebSocket

    private func graphQL(_ channel: StudioChannel, id: String, text: String) -> [StudioChannelFrame] {
        guard let message = StudioJSON(text: text), let type = message["type"]?.stringValue,
              let connection = connections[id] else { return [] }
        let legacy = connection.legacyGraphQL
        let operationID = message["id"].flatMap(\.identityKey) ?? ""
        func frame(_ object: [String: StudioJSON]) -> StudioChannelFrame { .text(StudioJSON.object(object).text) }
        if type != "ping", type != "pong", type != "ka" { logMessage(id, "→", message) }
        switch type {
        case "connection_init":
            return legacy ? [frame(["type": .string("connection_ack")]), frame(["type": .string("ka")])] : [frame(["type": .string("connection_ack")])]
        case "ping":
            return [frame(["type": .string("pong")])]
        case "pong", "ka":
            return []
        case "connection_terminate":
            close(id: id, code: 1000)
            return [.close(code: 1000, reason: "")]
        case "complete", "stop":
            connections[id]?.subscriptions[operationID] = nil
            return legacy ? [frame(["type": .string("complete"), "id": .string(operationID)])] : []
        case "subscribe", "start":
            let payload = message["payload"] ?? .null
            let next = legacy ? "data" : "next"
            func errorFrame(_ text: String) -> StudioChannelFrame {
                let errors = StudioJSON.array([StudioGraphQLExecutor.error(text)])
                return legacy ? frame(["type": .string("error"), "id": .string(operationID), "payload": .object(["errors": errors])])
                    : frame(["type": .string("error"), "id": .string(operationID), "payload": errors])
            }
            let parsed = StudioGraphQLRequest.parse(payload["query"]?.stringValue ?? "", variables: payload["variables"],
                                                    operationName: payload["operationName"]?.stringValue)
            guard case .success(let request) = parsed else {
                if case .failure(let failure) = parsed { return [errorFrame(failure.message)] }
                return []
            }
            if request.operation.kind == .subscription {
                let url = StudioChannelRoute.httpURL(connection.url)
                let fields = request.rootFields.filter { !$0.name.hasPrefix("__") }
                var frames: [StudioChannelFrame] = []
                for field in fields {
                    let operations = (environment.spec().graphQL ?? []).filter { $0.isUsable && $0.kind == .subscription && $0.field == field.name }
                    let operation = operations.first { operation in
                        let (ruleOrigin, path) = StudioRoute.split(StudioChannelRoute.httpPattern(operation.path))
                        if let ruleOrigin, ruleOrigin != StudioChannelRoute.origin(of: url) { return false }
                        return StudioRoute.match(pattern: path, path: url.path.isEmpty ? "/" : url.path) != nil
                    } ?? operations.first
                    guard let operation else {
                        environment.log("\(connection.shown) · \(connection.source) · no simulation rule answers the subscription \(field.name)", true)
                        frames.append(errorFrame("MarkView UI Studio has no simulation rule for the subscription \(field.name)"))
                        continue
                    }
                    connections[id]?.subscriptions[operationID] = StudioChannelConnection.Subscription(
                        field: field, operation: operation, fragments: request.document.fragments, variables: request.resolvedVariables)
                }
                return frames
            }
            let result = environment.graphQL(StudioChannelRoute.httpURL(connection.url), payload)
            var frames = [frame(["type": .string(next), "id": .string(operationID), "payload": result])]
            frames.append(frame(["type": .string("complete"), "id": .string(operationID)]))
            frames.forEach { logFrame(id, $0) }
            return frames
        default:
            return answer(channel, id: id, message: message, values: [:]).frames
        }
    }

    private func subscriptionFrames(_ id: String, _ change: StudioEntityChange) -> [StudioChannelFrame] {
        guard let connection = connections[id] else { return [] }
        var frames: [StudioChannelFrame] = []
        let spec = environment.spec()
        for (operationID, subscription) in connection.subscriptions.sorted(by: { $0.key < $1.key }) {
            let operation = subscription.operation
            guard operation.entity == change.entity, (operation.on ?? StudioChannelWrite.allCases).contains(change.kind) else { continue }
            let state = environment.state()
            let value: StudioJSON = operation.action == .list ? .array(state[change.entity] ?? []) : (change.record ?? change.old ?? .null)
            let context = StudioGraphQLExecutor.Context(spec: spec, state: state, fragments: subscription.fragments, variables: subscription.variables)
            let type = operation.typeName ?? StudioGraphQLExecutor.typeName(entity: change.entity)
            let projected = StudioGraphQLExecutor.project(value, subscription.field.selections, type: type, entity: change.entity, context: context)
            let payload = StudioJSON.object(["data": .object([subscription.field.responseKey: projected])])
            frames.append(.text(StudioJSON.object(["type": .string(connection.legacyGraphQL ? "data" : "next"), "id": .string(operationID),
                                                   "payload": payload]).text))
        }
        frames.forEach { logFrame(id, $0) }
        return frames
    }

    // MARK: Helpers

    nonisolated static func randomID(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}

private extension StudioJSON {
    func merging(_ fields: [String: StudioJSON]) -> StudioJSON {
        guard let object = objectValue else { return .object(fields) }
        return .object(object.merging(fields) { _, new in new })
    }
}

// MARK: - Validation

/// Schema checks of proposed channels and GraphQL operations (SIM-06), against the environment they will join.
enum StudioChannelValidator {
    static let maxChannels = 20
    static let maxOperations = 60
    static let maxMessages = 50

    static func problems(channels: [StudioChannel], operations: [StudioGraphQLOperation], spec: StudioEnvironmentSpec,
                         registered: StudioEnvironmentSpec) -> [String] {
        var problems: [String] = []
        if channels.count > maxChannels { problems.append("Too many channels (\(channels.count) > \(maxChannels))") }
        if operations.count > maxOperations { problems.append("Too many GraphQL operations (\(operations.count) > \(maxOperations))") }
        func plainPath(_ path: String) -> Bool {
            let (_, route) = StudioRoute.split(StudioChannelRoute.httpPattern(path))
            return route.hasPrefix("/") && !route.contains("..") && !route.contains(" ")
        }
        func entityProblem(_ owner: String, _ entity: String?) -> String? {
            guard let entity else { return "\(owner): needs an entity" }
            return spec.entity(entity) == nil ? "\(owner): entity \(entity) is not defined" : nil
        }
        var channelIDs = Set((registered.channels ?? []).map(\.id))
        var channelPaths = Set((registered.channels ?? []).map { StudioChannelRoute.httpPattern($0.path) })
        for channel in channels {
            if channel.id.isEmpty || !channelIDs.insert(channel.id).inserted { problems.append("Channel id \"\(channel.id)\" is empty or already used") }
            if !plainPath(channel.path) { problems.append("\(channel.id): the path \(channel.path) must start with / or be a full ws(s) or http(s) URL") }
            if !channelPaths.insert(StudioChannelRoute.httpPattern(channel.path)).inserted { problems.append("\(channel.id): \(channel.path) already has a channel") }
            let count = channel.onConnect.count + channel.events.count + channel.links.count
                + channel.onMessage.reduce(0) { $0 + 1 + $1.reply.count + $1.broadcast.count }
            if count > maxMessages { problems.append("\(channel.id): too many messages and rules (\(count) > \(maxMessages))") }
            for reply in channel.onMessage where reply.operation != nil {
                if let problem = entityProblem("\(channel.id) onMessage", reply.entity) { problems.append(problem) }
            }
            for link in channel.links {
                if let problem = entityProblem("\(channel.id) link", link.entity) { problems.append(problem) }
                if link.message == nil, channel.wire != .phoenix { problems.append("\(channel.id): a link of \(link.entity) needs a message") }
            }
            for event in channel.events {
                if let every = event.everyMs, every < StudioChannelHub.minEveryMs {
                    problems.append("\(channel.id): an event repeats every \(every) ms (at least \(StudioChannelHub.minEveryMs))")
                }
                if event.afterMs < 0 { problems.append("\(channel.id): an event's afterMs is negative") }
            }
        }
        var operationIDs = Set((registered.graphQL ?? []).map(\.id))
        var fields = Set((registered.graphQL ?? []).map { "\($0.path) \($0.kind.rawValue) \($0.field)" })
        for operation in operations {
            if operation.id.isEmpty || !operationIDs.insert(operation.id).inserted {
                problems.append("GraphQL operation id \"\(operation.id)\" is empty or already used")
            }
            if operation.field.range(of: #"^[_A-Za-z][_0-9A-Za-z]*$"#, options: .regularExpression) == nil {
                problems.append("\(operation.id): field \"\(operation.field)\" is not a GraphQL name")
            }
            if !plainPath(operation.path) { problems.append("\(operation.id): the path \(operation.path) must start with / or be a full URL") }
            if !fields.insert("\(operation.path) \(operation.kind.rawValue) \(operation.field)").inserted {
                problems.append("\(operation.id): \(operation.kind.rawValue) \(operation.field) at \(operation.path) already has an operation")
            }
            if operation.action == .respond {
                if operation.response == nil { problems.append("\(operation.id): a respond operation needs a response") }
            } else if let problem = entityProblem(operation.id, operation.entity) {
                problems.append(problem)
            }
            if operation.kind == .subscription, operation.action != .list, operation.action != .get, operation.action != .respond {
                problems.append("\(operation.id): a subscription answers with get (the written record) or list")
            }
            for include in operation.include ?? [] where spec.entity(include.entity) == nil {
                problems.append("\(operation.id): included entity \(include.entity) is not defined")
            }
        }
        return problems
    }
}
