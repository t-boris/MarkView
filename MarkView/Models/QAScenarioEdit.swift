import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-001): the edits a person makes to a scenario in the editor. Every edit keeps the scenario a
// graph without loops, keeps the selected branches pointing at lines that still exist, and stamps the change. Foundation only; checked on
// its own by tools/tests/qa-tests.sh.

extension QAScenario {
    // MARK: Ids

    /// An id for a new step that no step uses: the prefix and the next free number (n7, a3, ...).
    func freshNodeID(prefix: String) -> String {
        let used = Set(nodes.map(\.id))
        var number = 1
        while used.contains("\(prefix)\(number)") { number += 1 }
        return "\(prefix)\(number)"
    }

    static func idPrefix(for kind: QANodeKind) -> String {
        switch kind {
        case .action: return "n"
        case .check: return "c"
        case .alternative: return "a"
        case .failure: return "f"
        }
    }

    /// The step `to` can be reached from `from` by following the connections.
    func reaches(_ from: String, _ to: String) -> Bool {
        var seen: Set<String> = [from]
        var queue = [from]
        while let current = queue.popLast() {
            if current == to { return true }
            for edge in edges where edge.from == current && seen.insert(edge.to).inserted { queue.append(edge.to) }
        }
        return false
    }

    // MARK: Steps

    /// Adds a step after `parent` and connects it from there; with `parent` nil the step becomes the start of an empty scenario.
    /// A parent that already has lines out of it gets another one: a fork. Returns the new id, or nil when the parent is unknown (or the
    /// scenario already has steps and no parent was given).
    @discardableResult
    mutating func addNode(_ kind: QANodeKind, title: String, after parent: String?, actor: String? = nil, label: String? = nil, at time: Date = Date()) -> String? {
        if let parent, node(parent) == nil { return nil }
        if parent == nil && !nodes.isEmpty { return nil }
        let id = freshNodeID(prefix: QAScenario.idPrefix(for: kind))
        let resolvedActor = actor ?? (parent.flatMap { node($0) }.flatMap { actorID(of: $0) }) ?? (actors.count == 1 ? actors[0].id : nil)
        nodes.append(QANode(id: id, kind: kind, title: title, actor: resolvedActor))
        if let parent { edges.append(QAEdge(from: parent, to: id, label: label)) } else { start = id }
        touch(time)
        return id
    }

    /// Puts a new step on the connection from `from` to `to`: from → new → to. The selected branches that ran over the connection run over
    /// the new step as well.
    @discardableResult
    mutating func insertNode(_ kind: QANodeKind, title: String, between from: String, and to: String, at time: Date = Date()) -> String? {
        guard let index = edges.firstIndex(where: { $0.from == from && $0.to == to }) else { return nil }
        let id = freshNodeID(prefix: QAScenario.idPrefix(for: kind))
        let actor = node(from).flatMap { actorID(of: $0) }
        let label = edges[index].label
        nodes.append(QANode(id: id, kind: kind, title: title, actor: actor))
        edges[index] = QAEdge(from: from, to: id, label: label)
        edges.append(QAEdge(from: id, to: to))
        selected = selected.map { branch in
            var tokens = branch.split(separator: ">").map(String.init)
            if let at = zip(tokens, tokens.dropFirst()).enumerated().first(where: { $0.element.0 == from && $0.element.1 == to })?.offset {
                tokens.insert(id, at: at + 1)
            }
            return tokens.joined(separator: ">")
        }
        touch(time)
        return id
    }

    mutating func update(node id: String, at time: Date = Date(), _ change: (inout QANode) -> Void) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        change(&nodes[index])
        touch(time)
    }

    /// Removes a step and its connections. With `reconnect` the steps before it are joined to the steps after it, so a step taken out of
    /// the middle of a line leaves the line whole. The start moves to the next step when the start is removed.
    mutating func removeNode(_ id: String, reconnect: Bool, at time: Date = Date()) {
        guard node(id) != nil else { return }
        let before = edges.filter { $0.to == id }.map(\.from)
        let after = edges.filter { $0.from == id }
        edges.removeAll { $0.from == id || $0.to == id }
        nodes.removeAll { $0.id == id }
        if reconnect {
            for source in before {
                for next in after where source != next.to && !edges.contains(where: { $0.from == source && $0.to == next.to }) {
                    edges.append(QAEdge(from: source, to: next.to, label: next.label))
                }
            }
        }
        if start == id { start = after.first?.to }
        selected = selected.map { $0.split(separator: ">").map(String.init).filter { $0 != id }.joined(separator: ">") }
        pruneSelection()
        touch(time)
    }

    // MARK: Connections

    /// Joins two steps. Refused when a step is unknown, the connection exists, or it would make a line lead back to itself.
    @discardableResult
    mutating func connect(_ from: String, _ to: String, label: String? = nil, at time: Date = Date()) -> Bool {
        guard from != to, node(from) != nil, node(to) != nil, !edges.contains(where: { $0.from == from && $0.to == to }), !reaches(to, from) else { return false }
        edges.append(QAEdge(from: from, to: to, label: label))
        touch(time)
        return true
    }

    mutating func disconnect(_ from: String, _ to: String, at time: Date = Date()) {
        let count = edges.count
        edges.removeAll { $0.from == from && $0.to == to }
        guard edges.count != count else { return }
        pruneSelection()
        touch(time)
    }

    mutating func setLabel(_ label: String?, from: String, to: String, at time: Date = Date()) {
        guard let index = edges.firstIndex(where: { $0.from == from && $0.to == to }) else { return }
        let text = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        edges[index].label = (text?.isEmpty ?? true) ? nil : text
        touch(time)
    }

    // MARK: Selection

    /// Chooses or drops a branch for testing. Only a branch that exists can be chosen.
    mutating func setSelected(_ branch: String, _ isSelected: Bool, at time: Date = Date()) {
        if isSelected {
            guard !selected.contains(branch), enumerateBranches().branches.contains(where: { $0.id == branch }) else { return }
            selected.append(branch)
        } else {
            guard selected.contains(branch) else { return }
            selected.removeAll { $0 == branch }
        }
        touch(time)
    }

    mutating func selectAllBranches(at time: Date = Date()) {
        selected = enumerateBranches().branches.map(\.id)
        touch(time)
    }

    mutating func clearSelection(at time: Date = Date()) {
        guard !selected.isEmpty else { return }
        selected = []
        touch(time)
    }

    /// Drops the selected branches that no longer exist and the repeats, keeping the order.
    mutating func pruneSelection() {
        let all = enumerateBranches()
        guard !all.truncated else { return }
        let ids = Set(all.branches.map(\.id))
        var seen = Set<String>()
        selected = selected.filter { ids.contains($0) && seen.insert($0).inserted }
    }

    private mutating func touch(_ time: Date) { updated = time }
}
