import Foundation

// The records of UI Studio (feature "MarkView UI Studio"): the environment a session simulates, the scenarios it restores,
// the operations it applies to the project's sources and the captures it compares. Reusable configuration (environment and
// scenarios) is written to `.markview/studio/` and may be committed; session state, history and captures stay in `.dde/studio/`.

/// Where a session is (REQ-001): `ready` means the target scenario loaded and its required dependencies are provided;
/// `degraded` means the interface is partly available (unknown or unsupported requests, a stale preview, a stand-in in use).
enum StudioSessionState: String, Codable, CaseIterable, Sendable {
    case analyzing, preparing, starting, ready, degraded, failed, stopped

    var title: String {
        switch self {
        case .analyzing: return "Analyzing"
        case .preparing: return "Preparing"
        case .starting: return "Starting"
        case .ready: return "Ready"
        case .degraded: return "Degraded"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

/// What a contract was inferred from (ENV-02, ENV-03): a TypeScript type alone is never a guarantee of the real format.
struct StudioEvidence: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case contract, type, test, example, observation, assumption }
    var kind: Kind
    var detail: String
}

/// One dependency of the application and how the session provides it.
struct StudioDependency: Codable, Hashable, Identifiable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// Answered by registered simulation rules.
        case simulated
        /// Reaches a local resource or an address the user allowed explicitly.
        case allowed
        /// Outside the first release (GraphQL, WebSocket, Electron preload/IPC, server rendering…).
        case unsupported
        /// Seen but not yet answered: preparation failed, timed out or was cancelled.
        case unresolved
    }
    /// The contract key, e.g. `GET /api/projects/:id`, or a name such as `electron:window.api.load`.
    var id: String
    var mode: Mode
    var note: String
    var evidence: [StudioEvidence] = []
}

/// A field of a simulated entity, checked when rules and records are validated (SIM-06).
struct StudioField: Codable, Hashable, Sendable {
    var name: String
    /// string, integer, number, boolean, object, array.
    var type: String
    var required: Bool = false
    var enumValues: [String]? = nil
    /// The entity this field points at (a foreign key such as `projectId`).
    var references: String? = nil
}

/// A collection of the shared state: lists, details and writes of one kind of record read the same records (SIM-02).
struct StudioEntity: Codable, Hashable, Sendable {
    var name: String
    var idField: String = "id"
    var fields: [StudioField] = []
}

/// Related records attached to a detail answer: `tasks` of a project are the `tasks` whose `projectId` is the project's id.
struct StudioInclude: Codable, Hashable, Sendable {
    var field: String
    var entity: String
    var foreignKey: String
}

/// A fixed answer of a `respond` rule or of an override.
struct StudioFixedResponse: Codable, Hashable, Sendable {
    var status: Int
    var body: StudioJSON?
    var headers: [String: String]? = nil
}

/// A registered simulation rule: a declarative operation on the state (§6.2), never code written by an agent.
struct StudioRule: Codable, Hashable, Identifiable, Sendable {
    enum Operation: String, Codable, CaseIterable, Sendable {
        case list, get, create, update, delete, respond
        /// The test user of the scenario's role (ENV-05): `/api/me`, `/auth/session`.
        case session
        /// One stored JSON document the application reads and saves as a whole, such as settings, preferences or a profile.
        /// GET reads it, PUT and POST replace it, PATCH merges into it (JSON merge patch), DELETE resets it to the seed.
        /// `documentAction` overrides what the method means. The key is the path parameter `idParam` (default `id`), or
        /// `default` without one.
        case document
    }
    /// What a `document` rule does when its method alone does not say it: `resetDocument(keys)` is a PUT that resets.
    enum DocumentAction: String, Codable, CaseIterable, Sendable { case read, replace, merge, reset }
    enum Origin: String, Codable, Sendable { case project, agent, user }

    var id: String
    var method: String
    /// `/api/projects/:id`; a full URL (`https://api.example.com/v1/items`) for another origin; `*` matches the rest.
    var path: String
    var operation: Operation
    var entity: String? = nil
    /// The path parameter holding the record id (default `id`).
    var idParam: String? = nil
    /// A list wrapped in an object: `{ "items": [...] }`.
    var envelope: String? = nil
    /// Query parameters a list filters on by equality (`?status=open`).
    var filters: [String]? = nil
    var include: [StudioInclude]? = nil
    var response: StudioFixedResponse? = nil
    /// The success status when it is not the operation's usual one.
    var status: Int? = nil
    /// A `document` rule's action when it is not the method's usual one.
    var documentAction: DocumentAction? = nil
    var evidence: [StudioEvidence] = []
    var origin: Origin = .agent
    var version: Int = 1
}

/// Everything a session simulates for the project, reusable across sessions (EnvironmentSpec, §10.1).
struct StudioEnvironmentSpec: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var entities: [StudioEntity] = []
    var rules: [StudioRule] = []
    /// The records every scenario starts from unless it brings its own.
    var seed: [String: [StudioJSON]] = [:]
    /// Requests the application may make for real: patterns such as `https://fonts.googleapis.com/*` or `/locales/*`.
    var allowedRequests: [String] = []
    /// Field names whose values never reach the model, the logs or exported evidence (§11).
    var confidentialFields: [String] = StudioRedactor.defaultConfidentialFields
    var dependencies: [StudioDependency] = []
    var updated: Date? = nil
    /// Cookies and localStorage entries set again after every restore (REQ-008). Optional, so that environments saved
    /// before it still load.
    var keptBrowserData: StudioKeptBrowserData? = nil
    /// Service addresses of the development server and whether each is simulated or real (REQ-007). Optional, so files
    /// written before it still decode.
    var serverConnections: [StudioServerConnection]? = nil
    /// Secret variables the person keeps real when MarkView starts the server; the others get test values (REQ-007).
    var keptSecrets: [String]? = nil
    /// Routes whose server requests were prepared ahead of the page (BUG-074), so that happens once per project, not once
    /// per session. Optional, so files written before it still decode.
    var preparedRoutes: [String]? = nil
    /// The application's map (REQ-014): its services, endpoint groups and how far their preparation got, so a completed map
    /// is not redone and an interrupted one resumes. Optional, so files written before it still decode; a damaged map reads
    /// as none (UIStudioEnvironmentMap.swift).
    var map: StudioEnvironmentMap? = nil
    /// The application role of the built-in scenarios' test user (REQ-014), when the application does not know the default
    /// `member`: the ordinary role the map found in the code. Optional, so files written before it still decode.
    var testUserRole: String? = nil
    /// Simulated WebSocket, server-sent event and Socket.IO channels (REQ-015). Optional, so older files still decode;
    /// a damaged channel is read leniently and ignored.
    var channels: [StudioChannel]? = nil
    /// Simulated GraphQL operations (REQ-015). Optional, like `channels`.
    var graphQL: [StudioGraphQLOperation]? = nil

    func entity(_ name: String) -> StudioEntity? { entities.first { $0.name == name } }
}

/// An answer a scenario puts in place of a rule's normal one: an error, an empty list, a delay (loading) (SIM-11).
struct StudioOverride: Codable, Hashable, Sendable {
    /// The rule it changes, by id; or `method` and `path` of a rule.
    var ruleId: String? = nil
    var method: String? = nil
    var path: String? = nil
    var status: Int? = nil
    var body: StudioJSON? = nil
    var delayMs: Int? = nil
    /// A list answers `[]` (and a detail answers 404).
    var empty: Bool? = nil
    /// The request never finishes while the scenario is shown (the loading state).
    var hang: Bool? = nil
}

/// A restoration step (SCN-02): the UI state is rebuilt by explicit actions, not from a memory snapshot.
struct StudioStep: Codable, Hashable, Sendable {
    enum Action: String, Codable, Sendable { case click, type, wait, navigate, press }
    var action: Action
    var selector: String? = nil
    var text: String? = nil
    var ms: Int? = nil
}

struct StudioViewport: Codable, Hashable, Sendable {
    var width: Int
    var height: Int

    static let presets: [(name: String, viewport: StudioViewport)] = [
        ("Desktop", StudioViewport(width: 1280, height: 800)),
        ("Desktop HD", StudioViewport(width: 1440, height: 900)),
        ("Desktop Full HD", StudioViewport(width: 1920, height: 1080)),
        ("Desktop QHD", StudioViewport(width: 2560, height: 1440)),
        ("Laptop", StudioViewport(width: 1024, height: 700)),
        ("Tablet", StudioViewport(width: 768, height: 1024)),
        ("Phone", StudioViewport(width: 390, height: 844)),
    ]
}

/// The test user of a scenario (test credentials only, never a real account).
struct StudioRole: Codable, Hashable, Sendable {
    var name: String
    var user: StudioJSON
    var token: String = "markview-test-token"

    static let tester = StudioRole(name: "tester", user: .object([
        "id": .string("user-1"), "name": .string("Test User"), "email": .string("tester@example.test"), "role": .string("member"),
    ]))
}

/// A saved situation of the interface (SCN-01): route, baseline data, role, response rules, viewport, theme, locale, seed,
/// test time and restoration steps. The baseline never changes because a session changed its data (CAP-01).
struct StudioScenario: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case populated, empty, loading, error, detail, editing, custom }
    enum Theme: String, Codable, Sendable { case light, dark }

    var id: String
    var revision = 1
    var name: String
    var kind: Kind = .custom
    var route = "/"
    /// Baseline records by entity; nil = the environment's seed.
    var data: [String: [StudioJSON]]? = nil
    var role: StudioRole = .tester
    var overrides: [StudioOverride] = []
    var viewport = StudioViewport(width: 1280, height: 800)
    var theme: Theme = .light
    var locale = "en-US"
    var timeZone: String? = nil
    var seed: UInt32 = 1
    /// Mid-month at noon UTC: the same date and year in every time zone, so a server and a page in different zones agree (DEC-006).
    var testTime = Date(timeIntervalSince1970: 1_768_478_400) // 2026-01-15T12:00:00Z
    var steps: [StudioStep] = []
    /// A page the scenario's restoration must reach; absent in scenarios saved before this check.
    var expectedPath: String? = nil
    /// A visible destination element to verify after restoration, when known.
    var expectedSelector: String? = nil
    /// The contracts this scenario was saved against (`StudioScenarioCompatibility.fingerprint`).
    var contractFingerprint = ""
    var updated = Date()
    /// What the page gets for location, clipboard, camera and microphone, and notifications (REQ-008). Optional, so that
    /// scenarios saved before it still load; nil is the default profile.
    var browser: StudioBrowserProfile? = nil
    /// What the scenario is for: the request a context change made it from (REQ-013). Optional, so that scenarios saved
    /// before it still load.
    var description: String? = nil

    var browserProfile: StudioBrowserProfile { browser ?? StudioBrowserProfile() }
}

/// The browser features a scenario answers in place of the Mac (REQ-008). The page runtime gives the page the scenario's
/// place, a clipboard of its own, a test stream and notifications that are listed in Studio; the Mac's location,
/// clipboard, camera, microphone and notification center are never used.
struct StudioBrowserProfile: Codable, Hashable, Sendable {
    struct Place: Hashable, Sendable {
        var latitude: Double
        var longitude: Double
        /// Meters.
        var accuracy: Double = 25
        var label = ""

        var isValid: Bool {
            latitude.isFinite && longitude.isFinite && accuracy.isFinite
                && (-90...90).contains(latitude) && (-180...180).contains(longitude) && accuracy > 0
        }

        static let presets = [
            Place(latitude: 41.8781, longitude: -87.6298, label: "Chicago"),
            Place(latitude: 40.7128, longitude: -74.0060, label: "New York"),
            Place(latitude: 51.5074, longitude: -0.1278, label: "London"),
            Place(latitude: 52.5200, longitude: 13.4050, label: "Berlin"),
            Place(latitude: 35.6762, longitude: 139.6503, label: "Tokyo"),
        ]
    }

    enum Location: Hashable, Sendable {
        /// The person declined (PERMISSION_DENIED).
        case denied
        /// Allowed, but no position can be found (POSITION_UNAVAILABLE).
        case unavailable
        case place(Place)
    }

    /// Camera and microphone.
    enum Media: String, Codable, CaseIterable, Sendable {
        case denied
        /// A blank video track and a silent audio track; no device is opened.
        case testStream
    }

    enum NotificationPermission: String, Codable, CaseIterable, Sendable {
        /// Not asked yet: a request is answered `default`, as when the prompt is dismissed.
        case `default`
        case granted, denied
    }

    var location: Location = .denied
    /// What the page's clipboard holds when the page loads; the page's own writes replace it until the next load.
    var clipboardText = ""
    var media: Media = .denied
    var notifications: NotificationPermission = .default

    static let maxClipboard = 20_000

    private enum CodingKeys: String, CodingKey { case location, clipboardText, media, notifications }

    /// The settings as the page runtime reads them (`config.browser`). Numbers are always finite, so the runtime
    /// configuration always serializes; a place that is not valid is unavailable.
    var runtimeConfig: [String: Any] {
        var position: [String: Any] = ["kind": "denied"]
        switch location {
        case .denied: break
        case .place(let place) where place.isValid:
            position = ["kind": "place", "latitude": place.latitude, "longitude": place.longitude, "accuracy": place.accuracy,
                      "label": String(place.label.prefix(200))]
        case .unavailable, .place: position = ["kind": "unavailable"]
        }
        return ["location": position, "clipboardText": String(clipboardText.prefix(Self.maxClipboard)), "media": media.rawValue,
                "notifications": notifications.rawValue]
    }
}

extension StudioBrowserProfile {
    /// Lenient: a missing or unknown setting keeps its default, so a scenario file edited by hand still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        location = (try? container.decodeIfPresent(Location.self, forKey: .location)) ?? .denied
        clipboardText = (try? container.decodeIfPresent(String.self, forKey: .clipboardText)) ?? ""
        media = (try? container.decodeIfPresent(Media.self, forKey: .media)) ?? .denied
        notifications = (try? container.decodeIfPresent(NotificationPermission.self, forKey: .notifications)) ?? .default
    }
}

/// Written as `{"kind": "place", "latitude": …, "longitude": …, "accuracy": …, "label": …}`, `{"kind": "denied"}` or
/// `{"kind": "unavailable"}`.
extension StudioBrowserProfile.Location: Codable {
    private enum Keys: String, CodingKey { case kind, latitude, longitude, accuracy, label }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "unavailable": self = .unavailable
        case "place":
            self = .place(StudioBrowserProfile.Place(latitude: try container.decode(Double.self, forKey: .latitude),
                                                     longitude: try container.decode(Double.self, forKey: .longitude),
                                                     accuracy: (try? container.decodeIfPresent(Double.self, forKey: .accuracy)) ?? 25,
                                                     label: (try? container.decodeIfPresent(String.self, forKey: .label)) ?? ""))
        default: self = .denied
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .denied: try container.encode("denied", forKey: .kind)
        case .unavailable: try container.encode("unavailable", forKey: .kind)
        case .place(let place):
            try container.encode("place", forKey: .kind)
            try container.encode(place.latitude, forKey: .latitude)
            try container.encode(place.longitude, forKey: .longitude)
            try container.encode(place.accuracy, forKey: .accuracy)
            try container.encode(place.label, forKey: .label)
        }
    }
}

/// A cookie kept across restores (REQ-008); it passed the confidentiality check before it was kept.
struct StudioKeptCookie: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path = "/"
    /// nil: a session cookie.
    var expires: Date? = nil
    var secure = false
    var httpOnly = false
    /// `lax`, `strict`, or nil (none or not set).
    var sameSite: String? = nil

    var id: String { domain + "\n" + path + "\n" + name }

    private enum CodingKeys: String, CodingKey { case name, value, domain, path, expires, secure, httpOnly, sameSite }

    static let loopback: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// Whether the cookie is sent to `host`: its domain is the host or a parent domain of it; loopback names are one server.
    func belongs(to host: String) -> Bool {
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = host.lowercased()
        if domain.isEmpty { return false }
        if domain == host || (Self.loopback.contains(domain) && Self.loopback.contains(host)) { return true }
        return host.hasSuffix("." + domain)
    }
}

extension StudioKeptCookie {
    /// Lenient: only the name, value and domain are required.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
        domain = try container.decode(String.self, forKey: .domain)
        path = (try? container.decodeIfPresent(String.self, forKey: .path)) ?? "/"
        expires = try? container.decodeIfPresent(Date.self, forKey: .expires)
        secure = (try? container.decodeIfPresent(Bool.self, forKey: .secure)) ?? false
        httpOnly = (try? container.decodeIfPresent(Bool.self, forKey: .httpOnly)) ?? false
        sameSite = try? container.decodeIfPresent(String.self, forKey: .sameSite)
    }

    init(_ cookie: HTTPCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path.isEmpty ? "/" : cookie.path,
                  expires: cookie.expiresDate, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly,
                  sameSite: cookie.sameSitePolicy.map { $0.rawValue.lowercased() })
    }

    /// The cookie to set for an application served from `host`, or nil when it has expired. A cookie kept on one loopback
    /// name (`localhost`) is set on the one the development server uses now (`127.0.0.1`).
    func httpCookie(appHost host: String, now: Date = Date()) -> HTTPCookie? {
        if let expires, expires <= now { return nil }
        let bare = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let target = Self.loopback.contains(bare) && Self.loopback.contains(host.lowercased()) ? host : domain
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: target, .path: path.isEmpty ? "/" : path]
        if let expires { properties[.expires] = expires }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch sameSite {
        case "lax": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case "strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        default: break
        }
        return HTTPCookie(properties: properties)
    }
}

/// A localStorage entry kept across restores (REQ-008).
struct StudioKeptStorageEntry: Codable, Hashable, Sendable {
    var key: String
    var value: String
}

/// The page's cookies and localStorage the person chose to keep (REQ-008): a restore empties the browser storage, so
/// without them the application asks again (cookie consent, onboarding). They live in `environment.json`, which may be
/// committed, so only entries that do not look confidential are kept.
struct StudioKeptBrowserData: Codable, Hashable, Sendable {
    var cookies: [StudioKeptCookie] = []
    var localStorage: [StudioKeptStorageEntry] = []
    /// The application origin the entries were kept from.
    var origin: String? = nil
    var kept: Date? = nil

    var isEmpty: Bool { cookies.isEmpty && localStorage.isEmpty }

    static let maxCookies = 100
    static let maxEntries = 200
    static let maxName = 256
    static let maxValue = 8_192

    private enum CodingKeys: String, CodingKey { case cookies, localStorage, origin, kept }

    /// The kept localStorage as the page runtime reads it (`config.keptStorage`).
    var runtimeStorage: [[String: String]] { localStorage.map { ["key": $0.key, "value": $0.value] } }

    struct Outcome: Equatable {
        var kept: StudioKeptBrowserData
        /// What was left out and why, by name; never a value.
        var skipped: [String]
    }

    /// What may be kept of a page's cookies and localStorage: cookies sent to the application's host only, and no entry
    /// whose name or value looks confidential (`StudioRedactor.confidentialEntryProblem`) — those are named in `skipped`.
    static func collect(cookies: [StudioKeptCookie], storage: [StudioKeptStorageEntry], appHost: String, origin: String?,
                        redactor: StudioRedactor, now: Date = Date()) -> Outcome {
        var kept = StudioKeptBrowserData(origin: origin, kept: now)
        var skipped: [String] = []
        func shown(_ name: String) -> String { name.count > 80 ? String(name.prefix(80)) + "…" : name }
        for cookie in cookies.sorted(by: { $0.id < $1.id }) where cookie.belongs(to: appHost) {
            if let expires = cookie.expires, expires <= now { continue }
            if let problem = redactor.confidentialEntryProblem(name: cookie.name, value: cookie.value) {
                skipped.append("cookie \(shown(cookie.name)) (\(problem))")
            } else if kept.cookies.count >= maxCookies {
                skipped.append("cookie \(shown(cookie.name)) (more than \(maxCookies) cookies)")
            } else {
                kept.cookies.append(cookie)
            }
        }
        var seen = Set<String>()
        for entry in storage.sorted(by: { $0.key < $1.key }) where seen.insert(entry.key).inserted {
            if let problem = redactor.confidentialEntryProblem(name: entry.key, value: entry.value) {
                skipped.append("localStorage \(shown(entry.key)) (\(problem))")
            } else if kept.localStorage.count >= maxEntries {
                skipped.append("localStorage \(shown(entry.key)) (more than \(maxEntries) entries)")
            } else {
                kept.localStorage.append(entry)
            }
        }
        return Outcome(kept: kept, skipped: skipped)
    }

    /// The page's localStorage as the runtime's `storage()` reports it, checked at the boundary: string keys and values
    /// only, at most 500 entries. Sizes are judged by `collect`.
    static func storageEntries(_ raw: Any?) -> [StudioKeptStorageEntry] {
        guard let list = raw as? [Any] else { return [] }
        return list.prefix(500).compactMap { item in
            guard let object = item as? [String: Any], let key = object["key"] as? String, let value = object["value"] as? String else { return nil }
            return StudioKeptStorageEntry(key: key, value: value)
        }
    }
}

extension StudioKeptBrowserData {
    /// Lenient: an entry that does not decode is dropped instead of failing the whole environment.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cookies = ((try? container.decodeIfPresent([Lossy<StudioKeptCookie>].self, forKey: .cookies)) ?? []).compactMap(\.value)
        localStorage = ((try? container.decodeIfPresent([Lossy<StudioKeptStorageEntry>].self, forKey: .localStorage)) ?? []).compactMap(\.value)
        origin = try? container.decodeIfPresent(String.self, forKey: .origin)
        kept = try? container.decodeIfPresent(Date.self, forKey: .kept)
    }

    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
}

/// The identity of the code a preview or capture was built from: the commit, the uncommitted changes and the unsaved
/// editor buffers (§10.1: a commit SHA alone is not enough).
struct StudioRevision: Codable, Hashable, Sendable {
    var id: String
    var head: String?
    var changedFiles: Int
    var editorBuffers: Int

    var label: String {
        var text = String(id.prefix(10))
        if let head { text += " (\(head.prefix(7))" + (changedFiles > 0 ? " + \(changedFiles) changed" : "") + ")" }
        else if changedFiles > 0 { text += " (\(changedFiles) files)" }
        if editorBuffers > 0 { text += " + \(editorBuffers) unsaved" }
        return text
    }
}

/// One check of an operation's verification.
struct StudioCheck: Codable, Hashable, Sendable {
    var name: String
    var passed: Bool
    var detail: String = ""
}

extension StudioOperation {
    /// What an applied change is (REQ-012, DEC-008), as the assistant classified it: a repair of something broken (an
    /// overlap, wrong text, an error) is filed as a bug; a new or different look or behaviour is a requirement of the
    /// conversation's feature. Lenient: a value this version does not know reads as a change.
    enum ChangeKind: String, Codable, CaseIterable, Sendable {
        case repair, change

        init(from decoder: Decoder) throws {
            self = Self(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .change
        }
    }

    /// Where an applied change is recorded (REQ-012): a requirement of the conversation's feature or a bug report linked
    /// to it, written through the project's feature store.
    struct Tracking: Codable, Hashable, Sendable {
        /// `REQ-003` or `BUG-079`; empty when a damaged entry was read, which counts as not recorded.
        var id = ""
        /// The slug of the conversation's feature.
        var feature = ""
        /// The record's file, relative to the project root.
        var file = ""
        /// The change's before and after pictures, attached to the feature as sources: their ids and their files
        /// (relative to the project root). A switch between requirement and bug reuses them.
        var sources: [String] = []
        var pictures: [String] = []

        var isBug: Bool { id.hasPrefix("BUG-") }
        var isRecorded: Bool { !id.isEmpty && !feature.isEmpty }
    }
}

extension StudioOperation.Tracking {
    /// Lenient, so one damaged entry never fails the whole history: a missing or malformed field is empty.
    init(from decoder: Decoder) throws {
        self.init()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        feature = (try? container.decodeIfPresent(String.self, forKey: .feature)) ?? ""
        file = (try? container.decodeIfPresent(String.self, forKey: .file)) ?? ""
        sources = (try? container.decodeIfPresent([String].self, forKey: .sources)) ?? []
        pictures = (try? container.decodeIfPresent([String].self, forKey: .pictures)) ?? []
    }
}

/// One file of an operation: its text before and after, for the patch and for selective undo.
struct StudioFileChange: Codable, Hashable, Sendable {
    var path: String
    /// nil = the file did not exist.
    var before: String?
    var after: String?
}

/// A question, a source change or a context change made from UI Studio (ChangeSet, §10.1; EDIT-06; REQ-013).
struct StudioOperation: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case question, edit
        /// What the view shows changed, not the code: a new saved scenario derived from the current one (DEC-009).
        case context
    }
    enum Status: String, Codable, Sendable {
        case answered, applied, kept, undone, conflict, failed
        /// The assistant asked what was meant before changing anything.
        case clarification
    }
    enum Scope: String, Codable, CaseIterable, Sendable {
        case recordData = "record-data", instance, sharedComponent = "shared-component", theme, unknown

        var title: String {
            switch self {
            case .recordData: return "Data of one record"
            case .instance: return "This instance only"
            case .sharedComponent: return "Shared component"
            case .theme: return "Shared theme"
            case .unknown: return "Unclear"
            }
        }
    }

    var id: String
    var kind: Kind
    var request: String
    var created = Date()
    var status: Status
    var scope: Scope = .unknown
    var scopeNote = ""
    var answer = ""
    var summary = ""
    /// The assistant's classification of the change and its one-line reason, and where the applied change is recorded
    /// (REQ-012). Optional, so that history saved before them still loads.
    var changeKind: ChangeKind? = nil
    var changeReason: String? = nil
    var tracking: Tracking? = nil
    var question: String? = nil
    var options: [String] = []
    var selection: String = ""
    var scenarioId: String? = nil
    var baseRevision: StudioRevision? = nil
    var finalRevision: StudioRevision? = nil
    var files: [StudioFileChange] = []
    var patch = ""
    var checks: [StudioCheck] = []
    var conflict: String? = nil
    var beforeCapture: String? = nil
    var afterCapture: String? = nil
    /// The scenarios and the changes of a context change (REQ-013). Optional, so that history saved before it still loads.
    var context: StudioContextChange? = nil
    /// The images the person attached to the request, as project-relative paths in `.dde/studio/attachments/` (REQ-005).
    /// Optional, so that history saved before them still loads; use `attachedImages`.
    var attachments: [String]? = nil
    var attachedImages: [String] { attachments ?? [] }
}

extension StudioOperation.Kind {
    /// Lenient: a kind this version does not know reads as a question, which nothing undoes or exports, so a history that
    /// holds it still loads.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .question
    }
}

/// What a context change did (REQ-013, DEC-009): the scenario it was made from, the new saved scenario, what changed in
/// words and what could not be done.
struct StudioContextChange: Codable, Hashable, Sendable {
    var previousScenarioId = ""
    var previousScenarioName = ""
    /// The scenario as it was, so that Undo returns to it exactly, also when it was never saved or was changed in memory.
    var previous: StudioScenario? = nil
    /// The new saved scenario; empty when nothing could be changed and no scenario was made.
    var scenarioId = ""
    var scenarioName = ""
    /// The number of records of each entity whose records changed, after and before the change.
    var records: [String: Int] = [:]
    var recordsBefore: [String: Int] = [:]
    /// The new scenario's overrides in words; nil when they did not change, empty when they were all removed.
    var overrides: [String]? = nil
    /// The new route; nil when it did not change.
    var route: String? = nil
    /// The new scenario's restoration steps in words; nil when they did not change, empty when they were all removed.
    var steps: [String]? = nil
    /// Other changes in words: the test user, the clock, the locale, the time zone, the theme.
    var other: [String] = []
    /// What the assistant could not do (an entity no rule serves, a state no step reaches), reported instead of faked.
    var unsupported: [String] = []

    private enum CodingKeys: String, CodingKey {
        case previousScenarioId, previousScenarioName, previous, scenarioId, scenarioName, records, recordsBefore, overrides, route, steps
        case other, unsupported
    }

    var changesAnything: Bool { !records.isEmpty || overrides != nil || route != nil || steps != nil || !other.isEmpty }

    /// What changed, one line per part.
    var lines: [String] {
        var lines: [String] = []
        if !records.isEmpty {
            lines.append("Records: " + records.keys.sorted().map { name in
                "\(name) " + (recordsBefore[name].map { "\($0) → " } ?? "") + "\(records[name] ?? 0)"
            }.joined(separator: ", "))
        }
        if let overrides { lines.append("Overrides: " + (overrides.isEmpty ? "none" : overrides.joined(separator: "; "))) }
        if let route { lines.append("Route: \(route)") }
        if let steps { lines.append("Steps: " + (steps.isEmpty ? "none" : steps.joined(separator: " → "))) }
        return lines + other
    }
}

extension StudioContextChange {
    /// Lenient: a damaged entry keeps what can be read, so the history it is in still loads.
    init(from decoder: Decoder) throws {
        self.init()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        previousScenarioId = (try? container.decodeIfPresent(String.self, forKey: .previousScenarioId)) ?? ""
        previousScenarioName = (try? container.decodeIfPresent(String.self, forKey: .previousScenarioName)) ?? ""
        previous = (try? container.decodeIfPresent(StudioScenario.self, forKey: .previous)) ?? nil
        scenarioId = (try? container.decodeIfPresent(String.self, forKey: .scenarioId)) ?? ""
        scenarioName = (try? container.decodeIfPresent(String.self, forKey: .scenarioName)) ?? ""
        records = (try? container.decodeIfPresent([String: Int].self, forKey: .records)) ?? [:]
        recordsBefore = (try? container.decodeIfPresent([String: Int].self, forKey: .recordsBefore)) ?? [:]
        overrides = (try? container.decodeIfPresent([String].self, forKey: .overrides)) ?? nil
        route = (try? container.decodeIfPresent(String.self, forKey: .route)) ?? nil
        steps = (try? container.decodeIfPresent([String].self, forKey: .steps)) ?? nil
        other = (try? container.decodeIfPresent([String].self, forKey: .other)) ?? []
        unsupported = (try? container.decodeIfPresent([String].self, forKey: .unsupported)) ?? []
    }
}

/// The rendering conditions of a capture (CAP-02): two captures compare only when these are equal.
struct StudioRendering: Codable, Hashable, Sendable {
    var engine: String
    var os: String
    var viewport: StudioViewport
    var devicePixelRatio: Double
    var fonts: [String]
    var locale: String
    var timeZone: String
    var colorScheme: String
    var animations = "disabled"
}

/// A picture of the preview linked to the code and scenario it shows (Capture, §10.1).
struct StudioCapture: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var label: String
    var file: String
    var created = Date()
    var revision: StudioRevision
    var scenarioId: String
    var scenarioRevision: Int
    var contractFingerprint: String
    var rendering: StudioRendering
    var operationId: String? = nil
}
