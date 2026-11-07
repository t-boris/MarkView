import Foundation

/// Messages the page runtime (`markview-ui-studio.js`) sends to the session, checked at the boundary (REQ-006, §7): the
/// frame, the origin, the session, its generation and the payload's schema. A message that fails a check is dropped and
/// counted; it never reaches the simulation or the history.
enum StudioBridge {
    static let handlerName = "markviewStudio"
    static let maxURL = 8_192
    static let maxBody = 5_000_000
    static let maxHeaders = 100
    static let maxHeaderValue = 8_192
    static let maxDetail = 20_000

    struct Origin: Equatable {
        var scheme: String
        var host: String
        var port: Int

        init(scheme: String, host: String, port: Int) {
            self.scheme = scheme.lowercased()
            self.host = host.lowercased()
            self.port = port
        }

        init?(url: URL) {
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host else { return nil }
            self.init(scheme: scheme, host: host, port: url.port ?? (scheme == "https" ? 443 : 80))
        }

        var text: String {
            let standard = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
            return "\(scheme)://\(host)" + (standard ? "" : ":\(port)")
        }

        /// `localhost` and `127.0.0.1` are the same development server.
        func sameServer(_ other: Origin) -> Bool {
            let loopback: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
            let hostsMatch = host == other.host || (loopback.contains(host) && loopback.contains(other.host))
            return scheme == other.scheme && port == other.port && hostsMatch
        }
    }

    /// What the session expects of every message.
    struct Expectation {
        var session: String
        var generation: Int
        var origin: Origin
    }

    enum Message: Equatable {
        case request(Request)
        case event(Event)
        /// A WebSocket or EventSource of the page talking to a simulated channel (REQ-015), or a callback of the Electron
        /// preload bridge listening to one (REQ-016).
        case channel(Channel)
    }

    /// A step of a page connection to a simulated channel: open it, send a message on it, close it.
    struct Channel: Equatable {
        enum Action: String { case open, send, close }
        /// `ipc`: a callback the page passed to the Electron preload bridge (REQ-016), at an `http://electron.ipc` address.
        enum Transport: String { case webSocket = "websocket", eventSource = "eventsource", ipc }

        var action: Action
        /// The page's id for the connection.
        var id: String
        /// `open`: the ws(s) or http(s) URL and the subprotocols asked for.
        var url: URL?
        var protocols: [String] = []
        var transport = Transport.webSocket
        /// `send`: a text message, or a binary one (sent as base64).
        var text: String?
        var binary: Data?
        /// `close`: the code and reason the page gave.
        var code: Int?
        var reason: String?
    }

    struct Request: Equatable {
        var requestId: String
        var method: String
        var url: URL
        var headers: [String: String]
        var body: String?
        /// `fetch`, `xhr`, or `ipc` for a call of the Electron preload bridge (REQ-016).
        var transport: String
    }

    struct Event: Equatable {
        enum Kind: String, CaseIterable {
            /// An uncaught error or rejection.
            case runtimeError
            /// An Error the application passed to console.error or reportError, with its message and stack (BUG-079). WebKit
            /// hides both from the error event ("Script error.") when the code runs through eval with a `webpack://` source
            /// URL, so this is often the only readable account of a crash. Logged; it does not degrade the session itself.
            case logged
            /// The dev server's build error overlay (Vite, webpack, Next) appeared on the page; an empty
            /// detail says it is gone again (the build works).
            case buildError
            /// A dependency the simulation does not serve was used (sendBeacon).
            case unsupported
            /// The Electron preload bridge was called in a way the simulation cannot answer (REQ-016): `sendSync` needs its
            /// answer at once, so it gets undefined.
            case electron
            /// A resource of another origin did not load (blocked by the application connection policy).
            case blocked
            /// The route changed (pushState, popstate, hash).
            case route
            /// The page finished loading and its requests settled.
            case idle
            /// A step recorded while recording restoration steps.
            case recorded
            /// The page used a browser feature the scenario answers (REQ-008): `geolocation: place "Chicago"`,
            /// `clipboard: write (12 chars)`. Clipboard contents are never part of it.
            case browser
            /// The connection policy blocked the script of a third-party SDK the runtime has a stand-in for (Stripe.js, reCAPTCHA,
            /// Google Maps, analytics), and the stand-in took its place (BUG-103): `stripe: Stripe.js — payments are simulated…`.
            /// The text before the colon is the stand-in's id.
            case standIn
        }
        var kind: Kind
        var detail: String
        var url: String?
    }

    enum Rejection: Error, Equatable, CustomStringConvertible {
        case notMainFrame
        case wrongOrigin(String)
        case malformed(String)
        case wrongSession
        case stale(Int)

        var description: String {
            switch self {
            case .notMainFrame: return "a message from a frame other than the page"
            case .wrongOrigin(let origin): return "a message from \(origin), not the application's origin"
            case .malformed(let reason): return "a malformed message (\(reason))"
            case .wrongSession: return "a message of another session"
            case .stale(let generation): return "a message of an earlier generation (\(generation))"
            }
        }
    }

    /// Checks one message; `origin` is the sending frame's security origin.
    static func validate(_ body: Any, isMainFrame: Bool, origin: Origin?, expecting expected: Expectation) -> Result<Message, Rejection> {
        guard isMainFrame else { return .failure(.notMainFrame) }
        guard let origin, origin.sameServer(expected.origin) else { return .failure(.wrongOrigin(origin?.text ?? "an unknown origin")) }
        guard let object = body as? [String: Any] else { return .failure(.malformed("not an object")) }
        guard let session = object["session"] as? String, session == expected.session else { return .failure(.wrongSession) }
        guard let generation = (object["generation"] as? NSNumber)?.intValue else { return .failure(.malformed("no generation")) }
        guard generation == expected.generation else { return .failure(.stale(generation)) }
        switch object["kind"] as? String {
        case "request": return parseRequest(object).map(Message.request)
        case "event": return parseEvent(object).map(Message.event)
        case "channel": return parseChannel(object).map(Message.channel)
        default: return .failure(.malformed("unknown kind"))
        }
    }

    private static func parseRequest(_ object: [String: Any]) -> Result<Request, Rejection> {
        guard let id = object["requestId"] as? String, id.count <= 100,
              id.range(of: #"^[A-Za-z0-9_\-:.]+$"#, options: .regularExpression) != nil else { return .failure(.malformed("request id")) }
        guard let method = (object["method"] as? String)?.uppercased(),
              ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else { return .failure(.malformed("method")) }
        guard let text = object["url"] as? String, text.utf8.count <= maxURL, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return .failure(.malformed("url")) }
        var headers: [String: String] = [:]
        if let raw = object["headers"] {
            guard let dictionary = raw as? [String: Any], dictionary.count <= maxHeaders else { return .failure(.malformed("headers")) }
            for (name, value) in dictionary {
                guard let value = value as? String, value.utf8.count <= maxHeaderValue, name.utf8.count <= 256 else { return .failure(.malformed("header \(name)")) }
                headers[name.lowercased()] = value
            }
        }
        var body: String?
        if let raw = object["body"], !(raw is NSNull) {
            guard let text = raw as? String, text.utf8.count <= maxBody else { return .failure(.malformed("body")) }
            body = text
        }
        let transport = object["transport"] as? String ?? "fetch"
        guard ["fetch", "xhr", "ipc"].contains(transport) else { return .failure(.malformed("transport")) }
        // A call of the preload bridge has only its logical address, and that address is only the bridge's.
        guard transport != "ipc" || StudioIPC.isIPC(url) else { return .failure(.malformed("ipc url")) }
        return .success(Request(requestId: id, method: method, url: url, headers: headers, body: body, transport: transport))
    }

    private static func parseChannel(_ object: [String: Any]) -> Result<Channel, Rejection> {
        guard let id = object["id"] as? String, id.count <= 100,
              id.range(of: #"^[A-Za-z0-9_\-:.]+$"#, options: .regularExpression) != nil else { return .failure(.malformed("channel id")) }
        guard let action = (object["action"] as? String).flatMap(Channel.Action.init) else { return .failure(.malformed("channel action")) }
        var channel = Channel(action: action, id: id)
        switch action {
        case .open:
            guard let text = object["url"] as? String, text.utf8.count <= maxURL, let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(), ["ws", "wss", "http", "https"].contains(scheme), url.host != nil else {
                return .failure(.malformed("channel url"))
            }
            channel.url = url
            guard let transport = (object["transport"] as? String).flatMap(Channel.Transport.init) else { return .failure(.malformed("channel transport")) }
            guard transport != .ipc || StudioIPC.isIPC(url) else { return .failure(.malformed("ipc url")) }
            channel.transport = transport
            if let raw = object["protocols"], !(raw is NSNull) {
                guard let list = raw as? [String], list.count <= 20,
                      list.allSatisfy({ $0.range(of: #"^[!#$%&'*+\-.^_`|~0-9A-Za-z]{1,128}$"#, options: .regularExpression) != nil }) else {
                    return .failure(.malformed("channel protocols"))
                }
                channel.protocols = list
            }
        case .send:
            if let text = object["text"] as? String {
                guard text.utf8.count <= maxBody else { return .failure(.malformed("channel message")) }
                channel.text = text
            } else if let encoded = object["binary"] as? String, encoded.utf8.count <= maxBody / 3 * 4 + 4, let data = Data(base64Encoded: encoded) {
                channel.binary = data
            } else {
                return .failure(.malformed("channel message"))
            }
        case .close:
            if let code = (object["code"] as? NSNumber)?.intValue {
                // What a page may pass to WebSocket.close (the browser refuses the others).
                guard code == 1000 || (3000...4999).contains(code) else { return .failure(.malformed("channel close code")) }
                channel.code = code
            }
            if let reason = object["reason"] as? String {
                guard reason.utf8.count <= 123 else { return .failure(.malformed("channel close reason")) }
                channel.reason = reason
            }
        }
        return .success(channel)
    }

    private static func parseEvent(_ object: [String: Any]) -> Result<Event, Rejection> {
        guard let type = object["type"] as? String, let kind = Event.Kind(rawValue: type) else { return .failure(.malformed("event type")) }
        let detail = object["detail"] as? String ?? ""
        guard detail.utf8.count <= maxDetail else { return .failure(.malformed("event detail")) }
        let url = object["url"] as? String
        if let url, url.utf8.count > maxURL { return .failure(.malformed("event url")) }
        if kind == .browser, browserFeature(of: detail) == nil { return .failure(.malformed("browser feature")) }
        if kind == .standIn, standIn(of: detail) == nil { return .failure(.malformed("stand-in")) }
        return .success(Event(kind: kind, detail: detail, url: url))
    }

    /// The browser features the page runtime answers from the scenario (REQ-008).
    static let browserFeatures: Set<String> = ["geolocation", "permissions", "clipboard", "media", "notifications"]

    /// The feature a `browser` event's detail names (`clipboard: write (12 chars)` → clipboard), or nil when it names none.
    static func browserFeature(of detail: String) -> String? {
        guard let colon = detail.firstIndex(of: ":"), detail.index(after: colon) < detail.endIndex else { return nil }
        let feature = String(detail[..<colon])
        return browserFeatures.contains(feature) ? feature : nil
    }

    /// The SDKs the page runtime has a stand-in for (BUG-103); one per `sdkRegister` call in the runtime.
    static let standInIDs: Set<String> = ["stripe", "recaptcha", "google-maps", "google-tag", "google-analytics", "segment", "mixpanel", "posthog", "plausible"]

    /// The stand-in a `standIn` event's detail names (`stripe: Stripe.js — …` → stripe) and what it says it stands for, or nil
    /// when it names none of the registered ones.
    static func standIn(of detail: String) -> (id: String, what: String)? {
        guard let colon = detail.firstIndex(of: ":") else { return nil }
        let id = String(detail[..<colon])
        guard standInIDs.contains(id) else { return nil }
        return (id, String(detail[detail.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    /// The answer the page runtime turns into a Response / an XMLHttpRequest result.
    static func reply(_ response: StudioSimResponse) -> [String: Any] {
        ["action": "respond", "status": response.status, "headers": response.headers, "body": response.body ?? NSNull(),
         "delayMs": response.delayMs, "hang": response.hang]
    }

    /// Let the request go to its address (a local resource or an explicitly allowed one).
    static let passThrough: [String: Any] = ["action": "pass"]

    /// A pass-through whose request gets `headers` added (or replaced) on its way to the server.
    static func passThrough(adding headers: [String: String]) -> [String: Any] {
        ["action": "pass", "headers": headers]
    }
}

/// Page events as the Environment panel lists them: every repeat of the same kind and text, consecutive or not, is one
/// row with a count, so a warning the page logs on every render (a React hydration diff) does not push everything else
/// out of the list.
enum StudioEventGrouping {
    struct Group: Identifiable, Equatable {
        var kind: StudioBridge.Event.Kind
        var detail: String
        /// How many times the page reported it.
        var count: Int

        /// Kind and text: stable while new repeats arrive, so an expanded row stays expanded.
        var id: String { kind.rawValue + "\u{1F}" + detail }
    }

    /// Groups events given oldest first; the group seen most recently comes first.
    static func group(_ events: [(kind: StudioBridge.Event.Kind, detail: String)]) -> [Group] {
        var groups: [Group] = []
        var position: [String: Int] = [:]
        for event in events.reversed() {
            let key = event.kind.rawValue + "\u{1F}" + event.detail
            if let existing = position[key] {
                groups[existing].count += 1
            } else {
                position[key] = groups.count
                groups.append(Group(kind: event.kind, detail: event.detail, count: 1))
            }
        }
        return groups
    }
}

// MARK: - Electron preload bridge (REQ-016)

/// An Electron renderer runs in UI Studio as a web page, without its preload or main process. The globals its preload
/// exposes (`contextBridge.exposeInMainWorld`) are simulated by the page runtime like any other API: a call
/// `window.<global>.<a>.<b>(...args)` is the request `<verb> http://electron.ipc/<global>/<a>/<b>[/<argument>…]`, and a
/// callback argument listens to the simulated channel at that address. The address is logical: nothing is sent to it, the
/// session never passes it through, and only the simulation answers it.
enum StudioIPC {
    static let origin = "http://electron.ipc"
    static let host = "electron.ipc"
    /// Every argument of a call as JSON, redacted and at most 4 KB, for the preparation.
    static let argumentsHeader = "x-markview-ipc-args"
    /// The bridge's service in the application's map (REQ-014).
    static let service = "electron-ipc"
    /// Calls whose first argument is an IPC channel (`ipcRenderer.invoke('settings:get-document')`): their verb follows the
    /// channel.
    static let channelCalls: Set<String> = ["invoke", "send", "sendSync", "sendTo", "sendToHost"]

    private static let verbs: [String: String] = {
        var verbs: [String: String] = [:]
        for (verb, words) in [("GET", "get list load fetch read find query is has can"), ("DELETE", "delete remove clear"),
                              ("PATCH", "update patch"), ("PUT", "save set put reset import")] {
            for word in words.split(separator: " ") { verbs[String(word)] = verb }
        }
        return verbs
    }()

    static func isIPC(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && url.host?.lowercased() == host && url.port == nil
    }

    /// Whether a rule's or a channel's path is on the bridge.
    static func isIPC(path: String) -> Bool { path.lowercased().hasPrefix(origin + "/") }

    /// The verb of a bridge method or an IPC channel, by the first word of its last part (after `:`, `/` or `.`): get,
    /// list, load, fetch, read, find, query, is, has, can → GET; delete, remove, clear → DELETE; update, patch → PATCH; save,
    /// set, put, reset, import → PUT; any other → POST. The page runtime (`ipcVerb` in markview-ui-studio.js) uses the
    /// same rule.
    static func verb(of name: String) -> String {
        let action = name.split(omittingEmptySubsequences: false, whereSeparator: { ":/.".contains($0) }).last.map(String.init) ?? name
        guard let regex = try? NSRegularExpression(pattern: #"^[^A-Za-z0-9]*([A-Za-z][a-z0-9]*)"#),
              let match = regex.firstMatch(in: action, range: NSRange(action.startIndex..., in: action)),
              let range = Range(match.range(at: 1), in: action) else { return "POST" }
        return verbs[action[range].lowercased()] ?? "POST"
    }

    /// The verb a call of the endpoint at `path` (after the bridge's address, `:name` for its arguments) is made with: the
    /// verb of its method, the last fixed segment, or of the channel after `invoke`, `send` or `sendSync`. nil for a path
    /// with no method.
    static func verb(ofPath path: String) -> String? {
        let fixed = StudioRoute.segments(path).filter { !$0.hasPrefix(":") }
        guard let last = fixed.last else { return nil }
        if fixed.count >= 2, channelCalls.contains(fixed[fixed.count - 2]) {
            return verb(of: last.removingPercentEncoding ?? last)
        }
        return verb(of: last)
    }

    /// The simulated methods of the bridge: rules and channels (callbacks) at its address.
    static func methodCount(_ spec: StudioEnvironmentSpec) -> Int {
        spec.rules.filter { isIPC(path: $0.path) }.count + (spec.channels ?? []).filter { isIPC(path: $0.path) }.count
    }

    /// The Environment panel's line for an Electron renderer: `simulated (12 methods) · window.strikedesk`.
    static func summary(_ spec: StudioEnvironmentSpec, globals: [String]) -> String {
        let count = methodCount(spec)
        return "simulated (\(count) method\(count == 1 ? "" : "s"))"
            + (globals.isEmpty ? "" : " · " + globals.map { "window.\($0)" }.joined(separator: ", "))
    }
}
