import Foundation

// Where the project workflow lives and how it gets there (feature-3, DEC-026, DEC-022). Foundation only, so
// tools/tests/project-workflow-tests.sh compiles it on its own.
//
// One JSON document, `.dde/workflow/workflow.json`. The assignment of a rule variant to an item is not kept here: it is a
// record of the lifecycle journal (`TransitionRecord.Phase.assignment`), next to the transitions it explains. Two small files
// next to it carry work that must survive an interruption: `assignments-pending` (the items that existed when the workflow was
// adopted still need their standard variant, DEC-024) and `pending-replacements.json` (a save still owes items a replacement, DEC-021).
//
// Three outcomes of a read are told apart and never merged: no file yet (the project has not adopted a workflow), a file that
// cannot be read, and a file written by a newer app. The last two are never overwritten or replaced by defaults without notice.

/// What reading `workflow.json` found.
// An `Error` so that `parse` can return it as the failure of a `Result`; it is never thrown.
enum WorkflowLoad: Error, Equatable, Sendable {
    /// No file: the project has not adopted a workflow yet.
    case missing
    case loaded(ProjectWorkflow)
    /// The file exists but cannot be used; the text says why. It is left as it is.
    case damaged(String)
    /// The file was written by a newer app (its schema is greater than this app knows).
    case unsupported(schema: Int)

    /// The workflow that decides transitions now. Anything but a loaded workflow runs on the built-in standard rules.
    var effective: ProjectWorkflow {
        if case .loaded(let workflow) = self { return workflow }
        return .standard
    }

    /// Why the standard rules apply although the project may mean something else; nil when the workflow is loaded or not adopted yet.
    var problem: String? {
        switch self {
        case .missing, .loaded:
            return nil
        case .damaged(let reason):
            return "The project workflow file cannot be used (\(reason)). Repair or remove .dde/workflow/workflow.json; editing the workflow is off until then."
        case .unsupported(let schema):
            return "The project workflow file has schema \(schema), newer than this app understands (\(ProjectWorkflow.currentSchema)). Update MarkView; editing the workflow is off."
        }
    }

    var isEditable: Bool {
        switch self {
        case .missing, .loaded: return true
        case .damaged, .unsupported: return false
        }
    }
}

enum WorkflowStoreError: Error, LocalizedError, Equatable {
    /// The workflow is invalid; each message says what to change.
    case invalid([String])
    /// Someone saved a newer revision first (another window, or an edit by hand).
    case stale(current: Int)
    /// The file on disk cannot be edited (damaged or from a newer app).
    case notEditable(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let problems): return problems.joined(separator: " ")
        case .stale(let current): return "The workflow changed meanwhile (revision \(current)). Reload it and apply the change again."
        case .notEditable(let reason): return reason
        case .writeFailed(let reason): return "The workflow could not be saved: \(reason)"
        }
    }
}

final class ProjectWorkflowStore: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    convenience init(projectRoot: URL) {
        self.init(url: projectRoot.appendingPathComponent(".dde/workflow/workflow.json"))
    }

    private var assignmentMarker: URL { url.deletingLastPathComponent().appendingPathComponent("assignments-pending") }
    private var pendingURL: URL { url.deletingLastPathComponent().appendingPathComponent("pending-replacements.json") }

    // MARK: Reading

    func load() -> WorkflowLoad {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    private func read() -> WorkflowLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .damaged("the file cannot be read: \(error.localizedDescription)") }
        return Self.load(from: data)
    }

    /// What a workflow document holds. The file is read through here, and so is the text of the editor's source view, so both
    /// accept exactly the same documents.
    static func load(from data: Data) -> WorkflowLoad {
        switch parse(data) {
        case .failure(let outcome): return outcome
        case .success(let workflow):
            let problems = workflow.validate()
            guard problems.isEmpty else { return .damaged(problems.map(\.message).joined(separator: " ")) }
            return .loaded(workflow)
        }
    }

    /// Reads a document without judging it: the workflow it describes, or why it cannot be one. A workflow that decodes but breaks a
    /// rule is returned as it is; `ProjectWorkflow.validate` says what is wrong with it.
    static func parse(_ data: Data) -> Result<ProjectWorkflow, WorkflowLoad> {
        // The schema is read on its own first: a file from a newer app may have a shape this app cannot decode at all.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.damaged("the file is not a JSON object")) }
        guard let schema = object["schema"] as? Int else { return .failure(.damaged("the file has no schema version")) }
        if schema > ProjectWorkflow.currentSchema { return .failure(.unsupported(schema: schema)) }
        guard schema == ProjectWorkflow.currentSchema else { return .failure(.damaged("schema \(schema) is not a known version")) }
        do { return .success(try JSONDecoder().decode(ProjectWorkflow.self, from: data)) } catch {
            return .failure(.damaged("the content does not match the workflow format: \(Self.describe(error))"))
        }
    }

    /// The document as it is written to the file and shown in the source view: sorted keys, indented, one trailing newline.
    static func text(of workflow: ProjectWorkflow) -> String {
        (try? String(decoding: encode(workflow), as: UTF8.self)) ?? ""
    }

    private static func encode(_ workflow: ProjectWorkflow) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(workflow) + Data("\n".utf8)
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, _): return "\"\(key.stringValue)\" is missing"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }

    // MARK: Adoption

    /// The standard workflow with the delivery rules the project already declared (DEC-022): the Definition of Done and the
    /// project guide are read once, here, and never again for transitions. A feature keeps the standard feature variant, which
    /// never needed a pull request, checks or a release.
    static func adopted(definition: Data?, guide: String?) -> ProjectWorkflow {
        let policy = ProjectDeliveryPolicy.read(definition: definition, guide: guide)
        let release = ReleaseRequirement.isRequired(definitionOfDoneJSON: definition)
        return StandardWorkflow.make(bug: .init(pullRequestRequired: policy.pullRequestRequired,
                                                checksRequired: policy.checksRequired, releaseRequired: release))
    }

    /// True when the project has no feature folder in docs/features and no bug report in docs/bugs: nothing in it was written under a
    /// flow yet, so it can start on the default one for new projects.
    static func hasNoItems(in root: URL) -> Bool {
        let fileManager = FileManager.default
        let features = (try? fileManager.contentsOfDirectory(at: root.appendingPathComponent("docs/features", isDirectory: true),
                                                             includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        if features.contains(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) { return false }
        let bugs = (try? fileManager.contentsOfDirectory(at: root.appendingPathComponent("docs/bugs", isDirectory: true),
                                                         includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return !bugs.contains { $0.pathExtension.lowercased() == "md" }
    }

    /// Reads the Definition of Done and the guides of a project folder, for `adopted`.
    static func existingSettings(in root: URL) -> (definition: Data?, guide: String?) {
        let definition = try? Data(contentsOf: root.appendingPathComponent(".dde/definition-of-done.json"))
        let guides = ["AGENTS.md", "CLAUDE.md"].compactMap { name -> String? in
            guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8), text.utf8.count <= 1_000_000 else { return nil }
            return text
        }.joined(separator: "\n")
        return (definition, guides.isEmpty ? nil : guides)
    }

    /// Writes the adopted standard workflow when the project has none, and returns what is in effect. A file that exists, damaged or
    /// not, is never replaced here.
    @discardableResult
    func adoptIfMissing(projectRoot: URL) -> WorkflowLoad {
        lock.lock(); defer { lock.unlock() }
        let current = read()
        guard case .missing = current else { return current }
        let settings = Self.existingSettings(in: projectRoot)
        var workflow = Self.adopted(definition: settings.definition, guide: settings.guide)
        // A project that starts empty starts on a board (DEC-002); one that has features or bugs was written under the specification
        // stages and keeps them. The processes stay those the project's own delivery settings gave.
        if Self.hasNoItems(in: projectRoot) { workflow = WorkflowFlow.kanban.applied(to: workflow) }
        workflow.revision = 1
        do {
            // The marker first: a file without its marker would leave the items that existed without their variant for good.
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: assignmentMarker, options: .atomic)
            try write(workflow)
            return .loaded(workflow)
        } catch {
            // Not being able to write must not stop the project: the same rules apply from memory and the next start tries again.
            return .loaded(workflow)
        }
    }

    // MARK: Work that survives an interruption

    /// True while the items that existed when the workflow was adopted still have to be given their standard variant (DEC-024).
    var assignmentPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: assignmentMarker.path)
    }

    func clearAssignmentPending() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: assignmentMarker)
    }

    /// Writes what a save owes the items it takes a status or a variant from, before the workflow file changes.
    func savePending(_ plan: PendingReplacements) throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(plan).write(to: pendingURL, options: .atomic)
    }

    /// The plan an interrupted save left, nil when there is none or the file cannot be read (it is then left as it is).
    func pending() -> PendingReplacements? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: pendingURL) else { return nil }
        return try? JSONDecoder().decode(PendingReplacements.self, from: data)
    }

    func clearPending() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: pendingURL)
    }

    // MARK: Saving

    /// Saves a changed workflow. `expectedRevision` is the revision the change was made from; the stored one must still be that.
    /// The saved revision is one higher. The caller handles the items the change leaves without a status or variant (Q-009) first.
    @discardableResult
    func save(_ changed: ProjectWorkflow, expectedRevision: Int) throws -> ProjectWorkflow {
        lock.lock(); defer { lock.unlock() }
        let current = read()
        var stored = expectedRevision
        switch current {
        case .damaged, .unsupported:
            throw WorkflowStoreError.notEditable(current.problem ?? "The workflow file cannot be edited.")
        case .loaded(let workflow):
            guard workflow.revision == expectedRevision else { throw WorkflowStoreError.stale(current: workflow.revision) }
            stored = workflow.revision
        case .missing:
            stored = 0
        }
        var next = changed
        next.schema = ProjectWorkflow.currentSchema
        next.revision = stored + 1
        let problems = next.validate()
        guard problems.isEmpty else { throw WorkflowStoreError.invalid(problems.map(\.message)) }
        do { try write(next) } catch { throw WorkflowStoreError.writeFailed(error.localizedDescription) }
        return next
    }

    /// Puts the standard workflow back (revision raised), after the same handling of items as any other change.
    @discardableResult
    func resetToStandard(expectedRevision: Int) throws -> ProjectWorkflow {
        try save(.standard, expectedRevision: expectedRevision)
    }

    // MARK: File

    private func write(_ workflow: ProjectWorkflow) throws {
        let data = try Self.encode(workflow)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
