import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-001..REQ-003): a branching scenario as a persistent project asset. Foundation only, so the
// rules are compiled and checked on their own (tools/tests/qa-tests.sh).

enum QAAppKind: String, Codable, CaseIterable {
    case web
    case nativeMacOS
    case api
}

enum QATargetKind: String, Codable, CaseIterable {
    case local
    case development
    case production
}

enum QANativeStartupPolicy: String, Codable, CaseIterable {
    case launch, attach
    var title: String { self == .launch ? "Launch a new instance" : "Attach to a running application" }
}

/// The installed application and optional startup policy for this environment.
struct QAApplication: Codable, Equatable {
    var bundleIdentifier: String
    var name: String
    var startupPolicy: QANativeStartupPolicy? = nil
    var effectiveStartupPolicy: QANativeStartupPolicy { startupPolicy ?? .launch }
}

/// Where one application runs in one environment: a web address for a web scenario, an installed application for a native one.
struct QALocation: Codable, Equatable {
    var url: String? = nil
    var application: QAApplication? = nil

    /// What a player opens for this kind of application: the web address, or the bundle identifier of the installed application.
    func address(for kind: QAAppKind) -> String? {
        switch kind {
        case .web, .api: return url
        case .nativeMacOS: return application?.bundleIdentifier
        }
    }
}

/// An environment a check can run in (local, development, production) and, for each application of the scenario, where it runs there
/// (DEC-018). The key is the application's id.
struct QATarget: Codable, Equatable, Identifiable {
    var id: String
    var kind: QATargetKind
    var name: String
    var locations: [String: QALocation] = [:]
}

/// What an application is judged by (DEC-019).
enum QAReviewProfile: String, Codable, CaseIterable {
    /// A product people choose to use: it has to look right and hold their attention.
    case userFacing
    /// A working tool for staff: it has to be fast, economical to operate and ready for automation.
    case administration
    /// Only the requirement text the person wrote.
    case custom

    var title: String {
        switch self {
        case .userFacing: return "User-facing"
        case .administration: return "Administration"
        case .custom: return "Custom"
        }
    }

    /// The text a new application of this profile starts with; the person edits it.
    var presetRequirements: String {
        switch self {
        case .userFacing:
            return """
            - Attractive: a clear visual hierarchy, consistent spacing, type and colour, and a polished first impression.
            - Production-ready: no placeholder text, broken layout, raw error messages or unfinished states; the empty, loading and error states are designed.
            - Holds attention: the main action of each screen is obvious, the wording is clear and inviting, and nothing distracts from the task.
            """
        case .administration:
            return """
            - Fast: pages and actions answer quickly; slow steps are named with their measured times.
            - Optimal: the common tasks take few steps, lists can be filtered, sorted and acted on in bulk, and nothing has to be done twice.
            - Ready for automation: controls have stable identifiers and labels, addresses are predictable, actions can be repeated safely, and results are visible without guessing.
            """
        case .custom:
            return ""
        }
    }

    /// Whether the run measures step timings for an application of this profile as evidence for the review.
    var measuresSpeed: Bool { self == .administration }
    /// Whether the run collects the signals of automation readiness (identifiers, labels, addresses).
    var assessesAutomation: Bool { self == .administration }
}

/// One application of the product under test. A scenario lists the applications its players use (a user application, an
/// administration application, a partner application); each is reviewed against its own requirements (REQ-007).
struct QAApp: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var profile: QAReviewProfile = .userFacing
    /// What this application is reviewed against. Empty means the profile's preset.
    var requirements: String = ""

    var effectiveRequirements: String {
        let own = requirements.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? profile.presetRequirements : own
    }
}

/// A saved login in the macOS Keychain store of the browser (host and user name). A scenario never holds a password (DEC-014).
struct QALoginReference: Codable, Equatable, Hashable {
    var host: String
    var username: String
}

struct QAActor: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// The application this player uses, unless a step says otherwise.
    var app: String? = nil
    var login: QALoginReference? = nil
    /// Preparation creates a test account for this actor where the target allows it (REQ-002).
    var createTestAccount: Bool = false
}

enum QANodeKind: String, Codable, CaseIterable {
    /// An actor does something, written in words.
    case action
    /// What must hold at this point.
    case check
    /// A fork: a different action or option than the main line.
    case alternative
    /// A failure the scenario expects to be able to meet (an error, a timeout).
    case failure
}

/// Whether doing a step changes data in the target. Unknown counts as changing it where it matters (production).
enum QADataChange: String, Codable {
    case yes
    case no
    case unknown
}

enum QAConditionKind: String, Codable, CaseIterable {
    case state
    case data
    case networkFault
    case delay
}

/// A network fault the actor's page is made to show: matching requests fail, wait or answer with a status.
struct QAFault: Codable, Equatable {
    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    enum Mode: String, Codable {
        case fail
        case delay
        case status
    }
    var urlPattern: String
    var mode: Mode
    var status: Int? = nil
    var milliseconds: Int? = nil
    /// Nil preserves existing scenarios: every matching request is affected.
    var method: String? = nil
}

/// What a branch needs to be true before it can be executed (DEC-011): how preparation brings it about and how that is confirmed.
struct QACondition: Codable, Equatable {
    var kind: QAConditionKind
    var establish: String
    var verify: String
    var fault: QAFault? = nil
    /// A person brings this about before the check (restoring a snapshot, seeding a database, anything the application's own pages cannot do);
    /// MarkView asks them to confirm it and does not try itself. Absent in older files.
    var manual: Bool? = nil
    var isManual: Bool { manual == true && kind != .networkFault && kind != .delay }

    /// A fault injected into the actor's own page leaves nothing in the target; any other condition may.
    var changesData: QADataChange { kind == .networkFault || kind == .delay ? .no : .unknown }
}

struct QANode: Codable, Equatable, Identifiable {
    var id: String
    var kind: QANodeKind
    var title: String
    /// The instruction for an action, the expectation for a check, the reason for an alternative or a failure.
    var detail: String = ""
    var actor: String? = nil
    /// The application the step happens in, when it is not the actor's own.
    var app: String? = nil
    var changesData: QADataChange = .unknown
    var condition: QACondition? = nil
    /// Executable request and deterministic response checks for HTTP API scenarios.
    var api: QAAPIRequest? = nil
}

struct QAEdge: Codable, Equatable, Hashable {
    var from: String
    var to: String
    var label: String? = nil
}

/// One line from the start to a step with nothing after it. A run checks the branches the person selected, each on its own (DEC-003).
struct QABranch: Equatable, Hashable, Identifiable {
    var nodes: [String]
    var id: String { nodes.joined(separator: ">") }
}

struct QABranchEnumeration: Equatable {
    var branches: [QABranch]
    /// True when the scenario has more branches than were listed.
    var truncated: Bool
}

struct QAProblem: Equatable {
    enum Kind: String {
        case badID
        case duplicateNode
        case duplicateActor
        case noApp
        case duplicateApp
        case unknownApp
        case ambiguousApp
        case emptyTitle
        case missingExpectation
        case invalidAPI
        case missingStart
        case unknownNode
        case unreachableNode
        case cycle
        case noActor
        case unknownActor
        case ambiguousActor
        case incompleteCondition
        case noTarget
        case incompleteTarget
        case selectionGone
    }
    var kind: Kind
    var subject: String
    var message: String
}

/// Answers supplied during scenario discovery, retained separately from the original request.
struct QAClarification: Codable, Equatable {
    var question: String
    var answer: String
}

struct QAScenario: Codable, Equatable, Identifiable {
    static let currentSchema = 1

    var schema: Int = QAScenario.currentSchema
    var id: String
    var title: String
    /// What the person wanted to test, in their words.
    var goal: String
    var summary: String? = nil
    var summarySource: String? = nil
    var clarifications: [QAClarification]? = nil
    /// One scenario targets web, native macOS or HTTP API applications; surface kinds are never mixed (DEC-007).
    var appKind: QAAppKind
    var apps: [QAApp] = []
    var targets: [QATarget] = []
    var actors: [QAActor] = []
    /// How the application is brought to the state every selected check starts from, and how that is confirmed (REQ-003). Nil means the
    /// application as it is once the players have signed in.
    var baseline: QACondition? = nil
    var nodes: [QANode] = []
    var edges: [QAEdge] = []
    var start: String? = nil
    /// The branches the person chose to test, by branch id.
    var selected: [String] = []
    var created: Date
    var updated: Date

    // MARK: Lookup

    func node(_ id: String) -> QANode? { nodes.first { $0.id == id } }

    func target(_ id: String) -> QATarget? { targets.first { $0.id == id } }

    /// The actor a step belongs to; a scenario with one actor needs no name on its steps.
    func actorID(of node: QANode) -> String? {
        if let actor = node.actor { return actor }
        return actors.count == 1 ? actors[0].id : nil
    }

    /// The application a step happens in: its own, else its actor's, else the only application there is.
    func appID(of node: QANode) -> String? {
        if let app = node.app { return app }
        if let actor = actorID(of: node), let app = actors.first(where: { $0.id == actor })?.app { return app }
        return apps.count == 1 ? apps[0].id : nil
    }

    func app(_ id: String) -> QAApp? { apps.first { $0.id == id } }

    /// The applications a branch uses, in order of first appearance.
    func apps(in branch: QABranch) -> [String] {
        var seen: [String] = []
        for id in branch.nodes {
            if let node = node(id), let app = appID(of: node), !seen.contains(app) { seen.append(app) }
        }
        return seen
    }

    // MARK: Branches

    /// Every branch from the start, in the order the edges are written. Edges back to a step already on the line are not followed, so a
    /// cycle ends a line instead of looping (and is reported by `problems`).
    func enumerateBranches(limit: Int = 500) -> QABranchEnumeration {
        let known = Set(nodes.map(\.id))
        guard let start, known.contains(start) else { return QABranchEnumeration(branches: [], truncated: false) }
        var next: [String: [String]] = [:]
        for edge in edges where known.contains(edge.from) && known.contains(edge.to) {
            if !(next[edge.from] ?? []).contains(edge.to) { next[edge.from, default: []].append(edge.to) }
        }
        var branches: [QABranch] = []
        var truncated = false
        var line: [String] = []
        var onLine = Set<String>()
        func walk(_ id: String) {
            if truncated { return }
            line.append(id)
            onLine.insert(id)
            let children = (next[id] ?? []).filter { !onLine.contains($0) }
            if children.isEmpty {
                if branches.count >= limit { truncated = true } else { branches.append(QABranch(nodes: line)) }
            } else {
                for child in children { walk(child) }
            }
            line.removeLast()
            onLine.remove(id)
        }
        walk(start)
        return QABranchEnumeration(branches: branches, truncated: truncated)
    }

    /// The selected branches that still exist, and the ids of those that no longer do (an edit removed their line).
    func selectedBranches() -> (found: [QABranch], gone: [String]) {
        let all = enumerateBranches()
        let byID = Dictionary(all.branches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [QABranch] = []
        var gone: [String] = []
        for id in selected {
            if let branch = byID[id] { found.append(branch) } else { gone.append(id) }
        }
        return (found, gone)
    }

    /// The conditions along a branch, in order: what preparation has to establish before the branch runs (DEC-011).
    func conditions(of branch: QABranch) -> [(node: String, condition: QACondition)] {
        branch.nodes.compactMap { id in node(id)?.condition.map { (id, $0) } }
    }

    /// The actors a branch uses, in order of first appearance.
    func actors(in branch: QABranch) -> [String] {
        var seen: [String] = []
        for id in branch.nodes {
            if let node = node(id), let actor = actorID(of: node), !seen.contains(actor) { seen.append(actor) }
        }
        return seen
    }

    /// A short name for a branch: the alternatives and failures it takes, or the main line.
    func label(of branch: QABranch) -> String {
        let taken = branch.nodes.compactMap { id -> String? in
            guard let node = node(id), node.kind == .alternative || node.kind == .failure else { return nil }
            return node.title
        }
        return taken.isEmpty ? "Main line" : taken.joined(separator: ", ")
    }

    // MARK: Problems

    /// An id of a step, an actor or an application: plain letters, digits, - and _.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 40 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// What stops the scenario from being run. A scenario with problems can still be saved while it is being edited.
    func problems() -> [QAProblem] {
        var found: [QAProblem] = []
        func add(_ kind: QAProblem.Kind, _ subject: String, _ message: String) { found.append(QAProblem(kind: kind, subject: subject, message: message)) }

        var seenNodes = Set<String>()
        for node in nodes {
            if !QAScenario.isValidID(node.id) { add(.badID, node.id, "Step id \"\(node.id)\" may use only letters, digits, - and _.") }
            if !seenNodes.insert(node.id).inserted { add(.duplicateNode, node.id, "Two steps share the id \(node.id).") }
            if node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.emptyTitle, node.id, "Step \(node.id) has no title.") }
            if node.kind == .check && node.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(.missingExpectation, node.id, "Check \(node.id) does not say what must hold.")
            }
            if let actor = node.actor, !actors.contains(where: { $0.id == actor }) { add(.unknownActor, node.id, "Step \(node.id) names the unknown actor \(actor).") }
            if (node.kind == .action || node.kind == .check) && node.actor == nil && actors.count > 1 {
                add(.ambiguousActor, node.id, "Step \(node.id) does not say which of the \(actors.count) actors does it.")
            }
            if let app = node.app, self.app(app) == nil { add(.unknownApp, node.id, "Step \(node.id) names the unknown application \(app).") }
            if let condition = node.condition { found.append(contentsOf: QAScenario.conditionProblems(condition, node: node.id)) }
            if appKind == .api {
                if let api = node.api {
                    for message in api.problems { add(.invalidAPI, node.id, "Step \(node.id): \(message)") }
                    if node.changesData == .no || node.kind == .check || node.kind == .failure {
                        if !api.path.isEmpty && !["GET", "HEAD", "OPTIONS"].contains(api.method) {
                            add(.invalidAPI, node.id, "A mutating HTTP request must be an action marked as changing data.")
                        }
                    }
                } else if node.kind == .action || node.kind == .check {
                    add(.invalidAPI, node.id, "Step \(node.id) needs an API request or a previous-response check.")
                }
                if let condition = node.condition, condition.kind == .networkFault || condition.kind == .delay {
                    add(.invalidAPI, node.id, "API faults must be produced by real service requests or manual preparation.")
                }
            }
        }

        if let baseline { found.append(contentsOf: QAScenario.conditionProblems(baseline, node: "baseline")) }

        var seenApps = Set<String>()
        for app in apps {
            if !QAScenario.isValidID(app.id) { add(.badID, app.id, "Application id \"\(app.id)\" may use only letters, digits, - and _.") }
            if !seenApps.insert(app.id).inserted { add(.duplicateApp, app.id, "Two applications share the id \(app.id).") }
        }
        if apps.isEmpty { add(.noApp, id, "The scenario has no application.") }
        for actor in actors {
            if appKind == .api && actor.createTestAccount { add(.invalidAPI, actor.id, "API accounts and authentication must be explicit request steps; turn off automatic test account creation.") }
            if let app = actor.app, self.app(app) == nil { add(.unknownApp, actor.id, "Actor \(actor.id) uses the unknown application \(app).") }
            if actor.app == nil && apps.count > 1 && nodes.contains(where: { $0.actor == actor.id && $0.app == nil }) {
                add(.ambiguousApp, actor.id, "Actor \(actor.id) does not say which of the \(apps.count) applications they use.")
            }
        }

        var seenActors = Set<String>()
        for actor in actors where !seenActors.insert(actor.id).inserted { add(.duplicateActor, actor.id, "Two actors share the id \(actor.id).") }
        if actors.isEmpty { add(.noActor, id, "The scenario has no actor.") }

        let known = Set(nodes.map(\.id))
        if let start, known.contains(start) {
            var reached: Set<String> = [start]
            var queue = [start]
            while let current = queue.popLast() {
                for edge in edges where edge.from == current && known.contains(edge.to) && reached.insert(edge.to).inserted { queue.append(edge.to) }
            }
            for node in nodes where !reached.contains(node.id) { add(.unreachableNode, node.id, "Step \(node.id) cannot be reached from the start.") }
        } else {
            add(.missingStart, start ?? "", "The scenario has no valid start step.")
        }
        for edge in edges {
            if !known.contains(edge.from) { add(.unknownNode, edge.from, "A connection starts at the unknown step \(edge.from).") }
            if !known.contains(edge.to) { add(.unknownNode, edge.to, "A connection ends at the unknown step \(edge.to).") }
        }
        if let loop = firstCycleNode() { add(.cycle, loop, "The steps lead back to \(loop); a branch must not loop.") }

        if targets.isEmpty { add(.noTarget, id, "The scenario has no target.") }
        for target in targets { found.append(contentsOf: QAScenario.targetProblems(target, apps: apps, appKind: appKind)) }

        let all = enumerateBranches()
        if !all.truncated {
            let ids = Set(all.branches.map(\.id))
            for branch in selected where !ids.contains(branch) { add(.selectionGone, branch, "The selected branch \(branch) no longer exists.") }
        }
        return found
    }

    private static func conditionProblems(_ condition: QACondition, node: String) -> [QAProblem] {
        var found: [QAProblem] = []
        func add(_ message: String) { found.append(QAProblem(kind: .incompleteCondition, subject: node, message: message)) }
        if condition.establish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("The condition of \(node) does not say how it is established.") }
        // What a person does themselves is confirmed by their word, so it needs no way to verify it.
        if !condition.isManual && condition.verify.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("The condition of \(node) does not say how it is verified.") }
        if condition.kind == .networkFault || condition.kind == .delay {
            guard let fault = condition.fault, !fault.urlPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                add("The network condition of \(node) names no request to disturb.")
                return found
            }
            if fault.mode == .delay && (fault.milliseconds ?? 0) <= 0 { add("The delay of \(node) needs a positive time.") }
            if fault.mode == .status && !(100...599).contains(fault.status ?? 0) { add("The status answer of \(node) needs a status from 100 to 599.") }
            if let method = fault.method, !QAFault.methods.contains(method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()) {
                add("The network condition of \(node) has an unsupported HTTP method.")
            }
        }
        return found
    }

    private static func targetProblems(_ target: QATarget, apps: [QAApp], appKind: QAAppKind) -> [QAProblem] {
        var found: [QAProblem] = []
        for app in apps {
            func problem(_ message: String) { found.append(QAProblem(kind: .incompleteTarget, subject: target.id, message: message)) }
            guard let location = target.locations[app.id] else {
                problem("The target \(target.name) does not say where \(app.name) runs.")
                continue
            }
            switch appKind {
            case .web, .api:
                guard let text = location.url, let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      let host = url.host, !host.isEmpty else {
                    problem("\(app.name) in the target \(target.name) needs an http or https address.")
                    continue
                }
            case .nativeMacOS:
                if (location.application?.bundleIdentifier ?? "").isEmpty { problem("\(app.name) in the target \(target.name) needs an installed application.") }
            }
        }
        return found
    }

    /// A step that is on a loop, or nil. Depth-first over every step, not only those reachable from the start.
    private func firstCycleNode() -> String? {
        var next: [String: [String]] = [:]
        for edge in edges { next[edge.from, default: []].append(edge.to) }
        var state: [String: Int] = [:]   // 1 = on the current line, 2 = done
        var found: String?
        func visit(_ id: String) {
            if found != nil { return }
            state[id] = 1
            for child in next[id] ?? [] {
                if state[child] == 1 { found = child; return }
                if state[child] == nil { visit(child) }
            }
            state[id] = 2
        }
        for node in nodes where state[node.id] == nil { visit(node.id) }
        return found
    }
}
