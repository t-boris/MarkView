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
    }

    struct Request: Equatable {
        var requestId: String
        var method: String
        var url: URL
        var headers: [String: String]
        var body: String?
        var transport: String
    }

    struct Event: Equatable {
        enum Kind: String, CaseIterable {
            /// An uncaught error or rejection, or console.error.
            case runtimeError
            /// The dev server's build error overlay (Vite, webpack, Next) appeared on the page; an empty
            /// detail says it is gone again (the build works).
            case buildError
            /// A dependency the first release does not simulate was used (WebSocket, EventSource, sendBeacon).
            case unsupported
            /// A no-op Electron stand-in was called (preload, IPC).
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
        guard ["fetch", "xhr"].contains(transport) else { return .failure(.malformed("transport")) }
        return .success(Request(requestId: id, method: method, url: url, headers: headers, body: body, transport: transport))
    }

    private static func parseEvent(_ object: [String: Any]) -> Result<Event, Rejection> {
        guard let type = object["type"] as? String, let kind = Event.Kind(rawValue: type) else { return .failure(.malformed("event type")) }
        let detail = object["detail"] as? String ?? ""
        guard detail.utf8.count <= maxDetail else { return .failure(.malformed("event detail")) }
        let url = object["url"] as? String
        if let url, url.utf8.count > maxURL { return .failure(.malformed("event url")) }
        if kind == .browser, browserFeature(of: detail) == nil { return .failure(.malformed("browser feature")) }
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
