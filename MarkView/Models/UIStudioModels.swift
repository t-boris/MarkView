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
    }
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
    var testTime = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
    var steps: [StudioStep] = []
    /// The contracts this scenario was saved against (`StudioScenarioCompatibility.fingerprint`).
    var contractFingerprint = ""
    var updated = Date()
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

/// One file of an operation: its text before and after, for the patch and for selective undo.
struct StudioFileChange: Codable, Hashable, Sendable {
    var path: String
    /// nil = the file did not exist.
    var before: String?
    var after: String?
}

/// A question or a source change made from UI Studio (ChangeSet, §10.1; EDIT-06).
struct StudioOperation: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case question, edit }
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
