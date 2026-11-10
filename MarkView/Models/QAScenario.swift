import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-001..REQ-003): a branching scenario as a persistent project asset. Foundation only, so the
// rules are compiled and checked on their own (tools/tests/qa-tests.sh).

enum QAAppKind: String, Codable, CaseIterable {
    case web
    case nativeMacOS
}

enum QATargetKind: String, Codable, CaseIterable {
    case local
    case development
    case production
}

/// An installed macOS application the user picked; MarkView launches it (DEC-008).
struct QAApplication: Codable, Equatable {
    var bundleIdentifier: String
    var name: String
}

/// Where a check runs: a web address for a web scenario, an installed application for a native one.
struct QATarget: Codable, Equatable, Identifiable {
    var id: String
    var kind: QATargetKind
    var name: String
    var url: String? = nil
    var application: QAApplication? = nil
}

/// A saved login in the macOS Keychain store of the browser (host and user name). A scenario never holds a password (DEC-014).
struct QALoginReference: Codable, Equatable {
    var host: String
    var username: String
}

struct QAActor: Codable, Equatable, Identifiable {
    var id: String
    var name: String
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
    enum Mode: String, Codable {
        case fail
        case delay
        case status
    }
    var urlPattern: String
    var mode: Mode
    var status: Int? = nil
    var milliseconds: Int? = nil
}

/// What a branch needs to be true before it can be executed (DEC-011): how preparation brings it about and how that is confirmed.
struct QACondition: Codable, Equatable {
    var kind: QAConditionKind
    var establish: String
    var verify: String
    var fault: QAFault? = nil

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
    var changesData: QADataChange = .unknown
    var condition: QACondition? = nil
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
        case emptyTitle
        case missingExpectation
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

struct QAScenario: Codable, Equatable, Identifiable {
    static let currentSchema = 1

    var schema: Int = QAScenario.currentSchema
    var id: String
    var title: String
    /// What the person wanted to test, in their words.
    var goal: String
    /// One scenario targets one kind of application; web and native are never mixed (DEC-007).
    var appKind: QAAppKind
    var targets: [QATarget] = []
    var actors: [QAActor] = []
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

    static func isValidNodeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 40 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// What stops the scenario from being run. A scenario with problems can still be saved while it is being edited.
    func problems() -> [QAProblem] {
        var found: [QAProblem] = []
        func add(_ kind: QAProblem.Kind, _ subject: String, _ message: String) { found.append(QAProblem(kind: kind, subject: subject, message: message)) }

        var seenNodes = Set<String>()
        for node in nodes {
            if !QAScenario.isValidNodeID(node.id) { add(.badID, node.id, "Step id \"\(node.id)\" may use only letters, digits, - and _.") }
            if !seenNodes.insert(node.id).inserted { add(.duplicateNode, node.id, "Two steps share the id \(node.id).") }
            if node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.emptyTitle, node.id, "Step \(node.id) has no title.") }
            if node.kind == .check && node.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(.missingExpectation, node.id, "Check \(node.id) does not say what must hold.")
            }
            if let actor = node.actor, !actors.contains(where: { $0.id == actor }) { add(.unknownActor, node.id, "Step \(node.id) names the unknown actor \(actor).") }
            if (node.kind == .action || node.kind == .check) && node.actor == nil && actors.count > 1 {
                add(.ambiguousActor, node.id, "Step \(node.id) does not say which of the \(actors.count) actors does it.")
            }
            if let condition = node.condition { found.append(contentsOf: QAScenario.conditionProblems(condition, node: node.id)) }
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
        for target in targets { found.append(contentsOf: QAScenario.targetProblems(target, appKind: appKind)) }

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
        if condition.verify.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("The condition of \(node) does not say how it is verified.") }
        if condition.kind == .networkFault || condition.kind == .delay {
            guard let fault = condition.fault, !fault.urlPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                add("The network condition of \(node) names no request to disturb.")
                return found
            }
            if fault.mode == .delay && (fault.milliseconds ?? 0) <= 0 { add("The delay of \(node) needs a positive time.") }
            if fault.mode == .status && !(100...599).contains(fault.status ?? 0) { add("The status answer of \(node) needs a status from 100 to 599.") }
        }
        return found
    }

    private static func targetProblems(_ target: QATarget, appKind: QAAppKind) -> [QAProblem] {
        func problem(_ message: String) -> [QAProblem] { [QAProblem(kind: .incompleteTarget, subject: target.id, message: message)] }
        switch appKind {
        case .web:
            guard let text = target.url, let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty else {
                return problem("The target \(target.name) needs an http or https address.")
            }
        case .nativeMacOS:
            if (target.application?.bundleIdentifier ?? "").isEmpty { return problem("The target \(target.name) needs an installed application.") }
        }
        return []
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
