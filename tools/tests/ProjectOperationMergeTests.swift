// Checks what Re-discover does to operations that are already in .markview/operations.json
// (ProjectOperation.merged / hasUserChanges in MarkView/Models/ProjectOperation.swift, BUG-036):
// an operation the user has not changed is refreshed, every single-field edit survives, user-added
// and deleted operations are left alone, and the stored file layout stays compatible.
// The same checks also run against a copy of the rule that was in the store before the fix; they
// must fail there, which shows they can see the bug.
import Foundation

var failures = 0
var quiet = false

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        if !quiet { print("ok  \(name)") }
    } else {
        failures += 1
        if !quiet { print("FAIL \(name) \(detail())") }
    }
}

func json(_ operation: ProjectOperation) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try! encoder.encode(operation), as: UTF8.self)
}

// MARK: Fixtures

/// What discovery proposed the first time, as it stands in the file when nobody touched it.
func firstRun() -> ProjectOperation {
    var operation = ProjectOperation(
        id: "deploy-prod", label: "Deploy production", kind: "deploy", environment: "production", target: "api",
        nodes: [.init(id: "n1", name: "API")], command: "make deploy", cwd: ".", origin: "discovered",
        confidence: "medium", prerequisites: ["docker login"],
        provenance: [.init(kind: "project", location: "Makefile", line: 3)], remoteTrigger: false)
    operation.discovered = .init(command: operation.command, cwd: operation.cwd)
    operation.discoveredFields = operation.currentFields
    return operation
}

/// What the next discovery run proposes: every value discovery owns has changed.
func secondRun() -> ProjectOperation {
    var operation = ProjectOperation(
        id: "deploy-prod", label: "Ship production", kind: "install", environment: "prod", target: "api-service",
        nodes: [.init(id: "n2", name: "API v2")], command: "make ship", cwd: "deploy", origin: "discovered",
        confidence: "high", prerequisites: ["docker login", "gh auth login"],
        provenance: [.init(kind: "project", location: "deploy.sh", line: 1)], remoteTrigger: false)
    operation.discovered = .init(command: operation.command, cwd: operation.cwd)
    operation.discoveredFields = operation.currentFields
    return operation
}

func edited(_ edit: (inout ProjectOperation) -> Void) -> ProjectOperation {
    var operation = firstRun()
    edit(&operation)
    return operation
}

/// The rule the store applied before BUG-036: an operation is the user's only when its command or
/// working directory differs from `discovered`; any other operation is replaced by the proposal.
func previousRule(stored: ProjectOperation, proposal: ProjectOperation) -> ProjectOperation {
    if stored.deleted || stored.origin == "user" { return stored }
    guard stored.isEdited else { return proposal }
    var kept = stored
    kept.discovered = proposal.discovered
    kept.provenance = proposal.provenance
    kept.confidence = proposal.confidence
    if !stored.nodesEdited { kept.nodes = proposal.nodes }
    return kept
}

typealias Merge = (ProjectOperation, ProjectOperation) -> ProjectOperation

// MARK: Merge decisions

func mergeChecks(_ merge: @escaping Merge) {
    // An operation nobody touched is refreshed with everything discovery now proposes.
    let refreshed = merge(firstRun(), secondRun())
    check("unedited operation: refreshed from the proposal", json(refreshed) == json(secondRun()), json(refreshed))

    var withFuture = firstRun()
    withFuture.extra["futureField"] = .string("kept")
    check("unedited operation: fields this version does not know are carried over",
          merge(withFuture, secondRun()).extra["futureField"] != nil)

    var next = secondRun()
    next.remoteTrigger = true
    check("unedited operation: remote-trigger flag refreshed", merge(firstRun(), next).remoteTrigger)

    // Each edit alone, on an operation whose command and working directory are as discovered.
    // Whatever else the user did not touch stays as it is; only discovery metadata is refreshed.
    struct Edit { let name: String; let apply: (inout ProjectOperation) -> Void; let kept: (ProjectOperation) -> Bool }
    let edits: [Edit] = [
        Edit(name: "label", apply: { $0.label = "My label" }, kept: { $0.label == "My label" }),
        Edit(name: "kind", apply: { $0.kind = "other" }, kept: { $0.kind == "other" }),
        Edit(name: "environment set", apply: { $0.environment = "staging" }, kept: { $0.environment == "staging" }),
        Edit(name: "environment cleared", apply: { $0.environment = nil }, kept: { $0.environment == nil }),
        Edit(name: "target", apply: { $0.target = "worker" }, kept: { $0.target == "worker" }),
        Edit(name: "target cleared", apply: { $0.target = nil }, kept: { $0.target == nil }),
        Edit(name: "prerequisites", apply: { $0.prerequisites = ["my step"] }, kept: { $0.prerequisites == ["my step"] }),
        Edit(name: "prerequisites cleared", apply: { $0.prerequisites = [] }, kept: { $0.prerequisites.isEmpty }),
        Edit(name: "remote trigger", apply: { $0.remoteTrigger = true }, kept: { $0.remoteTrigger }),
        Edit(name: "command", apply: { $0.command = "make deploy-hotfix" }, kept: { $0.command == "make deploy-hotfix" }),
        Edit(name: "working directory", apply: { $0.cwd = "scripts" }, kept: { $0.cwd == "scripts" }),
        Edit(name: "deployment node", apply: { $0.nodes = [.init(id: "n9", name: "Mine")]; $0.extra["nodesEdited"] = .bool(true) },
             kept: { $0.nodes.map(\.id) == ["n9"] }),
    ]
    for edit in edits {
        let stored = edited(edit.apply)
        let proposal = secondRun()
        let merged = merge(stored, proposal)
        check("\(edit.name) edit: user value kept", edit.kept(merged), json(merged))
        check("\(edit.name) edit: discovery metadata refreshed",
              merged.discovered == proposal.discovered && merged.discoveredFields == proposal.discoveredFields
                && merged.provenance == proposal.provenance && merged.confidence == proposal.confidence)
        var expected = stored
        expected.discovered = proposal.discovered
        expected.discoveredFields = proposal.discoveredFields
        expected.provenance = proposal.provenance
        expected.confidence = proposal.confidence
        if !stored.nodesEdited { expected.nodes = proposal.nodes }
        check("\(edit.name) edit: nothing else changes", json(merged) == json(expected), json(merged))
    }

    // An edit that was undone leaves nothing to protect.
    let undone = edited { $0.label = "Temporary"; $0.label = "Deploy production" }
    check("edit reverted by hand: refreshed again", json(merge(undone, secondRun())) == json(secondRun()))

    // A second run keeps comparing against the latest proposal, not the first one.
    let afterEdit = merge(edited { $0.label = "My label" }, secondRun())
    var third = secondRun()
    third.label = "Ship it"
    third.discoveredFields = third.currentFields
    check("edit survives a later run too", merge(afterEdit, third).label == "My label")

    // User-added and deleted operations are never touched by a proposal with the same id.
    var added = ProjectOperation(id: "deploy-prod", label: "Mine", kind: "deploy", command: "./mine.sh", cwd: ".", origin: "user")
    added.discoveredFields = nil
    check("user-added operation: untouched", json(merge(added, secondRun())) == json(added))
    var tombstone = firstRun()
    tombstone.deleted = true
    check("deleted operation: untouched", json(merge(tombstone, secondRun())) == json(tombstone))
    var editedTombstone = edited { $0.label = "Mine" }
    editedTombstone.deleted = true
    check("deleted operation with an edit: untouched", json(merge(editedTombstone, secondRun())) == json(editedTombstone))

    // The UI keys its confidence text and "Adopt discovered" action off isEdited: command or directory only.
    check("isEdited: a label edit is not a command edit", !edited { $0.label = "My label" }.isEdited)
    check("isEdited: a command edit is", edited { $0.command = "make x" }.isEdited)
}

// MARK: Operations written before the snapshot existed

func legacyChecks(_ merge: @escaping Merge) {
    func legacy(_ edit: (inout ProjectOperation) -> Void = { _ in }) -> ProjectOperation {
        var operation = firstRun()
        edit(&operation)
        operation.discoveredFields = nil
        return operation
    }
    // Same discovery output, newer metadata: nothing to protect, and the snapshot is recorded.
    var same = firstRun()
    same.confidence = "high"
    same.provenance = [.init(kind: "project", location: "Makefile", line: 9)]
    let sameMerged = merge(legacy(), same)
    check("no snapshot, nothing differs: refreshed", json(sameMerged) == json(same), json(sameMerged))
    check("no snapshot, nothing differs: snapshot recorded", sameMerged.discoveredFields == same.discoveredFields)

    // A field that differs cannot be told from a user edit, so it stays. The snapshot is recorded so
    // that later runs compare against it.
    let differs = merge(legacy { $0.label = "My label" }, secondRun())
    check("no snapshot, label differs: kept", differs.label == "My label", json(differs))
    check("no snapshot, label differs: snapshot recorded", differs.discoveredFields == secondRun().discoveredFields)
    let drift = merge(legacy(), secondRun())
    check("no snapshot, discovery changed the label: kept", drift.label == "Deploy production" && drift.command == "make deploy")
    check("no snapshot, command edited: kept", merge(legacy { $0.command = "make x" }, secondRun()).command == "make x")

    var noBaseline = firstRun()
    noBaseline.discovered = nil
    noBaseline.discoveredFields = nil
    check("no snapshot at all, command differs: kept", merge(noBaseline, secondRun()).command == "make deploy")
    var matching = secondRun()
    matching.discovered = nil
    matching.discoveredFields = nil
    check("no snapshot at all, identical to the proposal: refreshed", json(merge(matching, secondRun())) == json(secondRun()))
}

// MARK: File layout

func layoutChecks() {
    let decoder = JSONDecoder()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("markview-merge-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    // A file written by an earlier version has no snapshot and is saved back byte for byte.
    var document = ProjectOperationsDocument()
    var older = firstRun()
    older.discoveredFields = nil
    var user = ProjectOperation(id: "my-script", label: "Mine", kind: "other", command: "./mine.sh")
    user.extra["futureField"] = .object(["list": .array([.int(1), .string("two")]), "flag": .bool(true), "none": .null])
    document.operations = [older, user]
    try! ProjectOperationsFile.write(document, root: root)
    let first = try! Data(contentsOf: ProjectOperationsFile.url(root: root))
    let text = String(decoding: first, as: UTF8.self)
    check("earlier file: no snapshot key is written", !text.contains("discoveredFields"))
    try! ProjectOperationsFile.write(try! ProjectOperationsFile.read(root: root), root: root)
    check("earlier file: saved back byte for byte", try! Data(contentsOf: ProjectOperationsFile.url(root: root)) == first)
    let reread = try! ProjectOperationsFile.read(root: root)
    check("earlier file: unknown fields survive", reread.operations.first { $0.id == "my-script" }?.extra["futureField"] != nil)

    // The snapshot goes into the file as one extra key per operation and nothing else changes.
    var proposal = secondRun()
    proposal.environment = nil
    proposal.discoveredFields = proposal.currentFields
    document.operations = [proposal]
    try! ProjectOperationsFile.write(document, root: root)
    let written = String(decoding: try! Data(contentsOf: ProjectOperationsFile.url(root: root)), as: UTF8.self)
    check("snapshot: written under discoveredFields", written.contains("\"discoveredFields\""))
    check("snapshot: command and cwd stay in discovered", written.contains("\"discovered\"") && written.contains("\"make ship\""))
    let back = try! ProjectOperationsFile.read(root: root).operations[0]
    check("snapshot: read back as written", back.discoveredFields == proposal.discoveredFields)
    check("snapshot: not mistaken for an unknown field", back.extra.isEmpty)
    check("snapshot: no environment means none", back.discoveredFields?.environment == nil)

    // A damaged snapshot only means "not recorded"; it must not make the file unreadable.
    let damaged = """
    {"id":"a","label":"A","kind":"build","nodes":[],"command":"make a","cwd":".","origin":"discovered",
     "discovered":{"command":"make a","cwd":"."},"discoveredFields":{"label":5},"prerequisites":[],"provenance":[]}
    """
    let operation = try? decoder.decode(ProjectOperation.self, from: Data(damaged.utf8))
    check("damaged snapshot: operation still reads", operation != nil && operation?.discoveredFields == nil)

    // The whole Re-discover step on a file: what the store does inside ProjectOperationsFile.mutate.
    var userEdit = firstRun()
    userEdit.id = "edited-label"
    userEdit.label = "My label"
    var untouched = firstRun()
    untouched.id = "untouched"
    var mine = ProjectOperation(id: "mine", label: "Mine", kind: "other", command: "./mine.sh")
    mine.discovered = nil
    var gone = firstRun()
    gone.id = "gone"
    gone.deleted = true
    document.operations = [userEdit, untouched, mine, gone]
    try! ProjectOperationsFile.write(document, root: root)
    var proposals: [ProjectOperation] = []
    for id in ["edited-label", "untouched", "mine", "gone", "brand-new"] {
        var next = secondRun()
        next.id = id
        proposals.append(next)
    }
    let result = try! ProjectOperationsFile.mutate(root: root) { document in
        for proposal in proposals {
            if let index = document.operations.firstIndex(where: { $0.id == proposal.id }) {
                document.operations[index] = ProjectOperation.merged(stored: document.operations[index], proposal: proposal)
            } else {
                document.operations.append(proposal)
            }
        }
    }
    func find(_ id: String) -> ProjectOperation { result.operations.first { $0.id == id }! }
    check("file: edited label kept, snapshot refreshed",
          find("edited-label").label == "My label" && find("edited-label").discoveredFields == secondRun().discoveredFields)
    check("file: untouched operation refreshed", find("untouched").label == "Ship production")
    check("file: user-added operation unchanged", find("mine").command == "./mine.sh" && find("mine").label == "Mine")
    check("file: deleted operation unchanged", find("gone").deleted && find("gone").label == "Deploy production")
    check("file: new operation added", result.operations.count == 5)
    let onDisk = try! ProjectOperationsFile.read(root: root)
    check("file: result is what was saved", onDisk.operations.map(json) == result.operations.sorted { $0.id < $1.id }.map(json))
}

// MARK: Run

mergeChecks(ProjectOperation.merged(stored:proposal:))
legacyChecks(ProjectOperation.merged(stored:proposal:))
layoutChecks()
let current = failures

failures = 0
quiet = true
mergeChecks(previousRule(stored:proposal:))
legacyChecks(previousRule(stored:proposal:))
let previous = failures
print("Checks against the rule before BUG-036: \(previous) failed (must be more than 0)")

if current == 0 && previous > 0 {
    print("All project operation merge checks passed")
    exit(0)
}
print(current == 0 ? "The checks do not detect the old rule" : "\(current) check(s) failed")
exit(1)
