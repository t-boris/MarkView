import Foundation

// Workflow templates kept in a folder every project shares (feature workflow-templates, REQ-001..003, DEC-001, DEC-003).
//
// A template is the whole workflow a person configured: the states and transitions of features and bugs, and every process with
// its delivery settings. It is a copy, like a process template: the project that gave it keeps its own workflow, and a project that
// takes it gets a copy it then edits on its own. It is a plain JSON file, `<id>.json` in
// `~/Library/Application Support/MarkView/WorkflowTemplates/`, written with the same encoder and read through the same decoder and
// validation as `.dde/workflow/workflow.json`, so a template can never hold what a project could not. A small `default.json` in the
// same folder names the template that new projects start on; the folder is the whole store, so copying it moves both.
//
// A file that cannot be used (unreadable, not a template, invalid workflow, a newer schema) is listed with the reason and is never
// rewritten or deleted by the app. Foundation only (with FeatureVocabulary.swift, IssueListing.swift, ProjectWorkflow.swift,
// IssueLifecycle.swift and WorkflowFlow.swift), so tools/tests/workflow-template-tests.sh compiles it on its own. Every function
// here does file work: callers run them off the main thread.

struct WorkflowTemplate: Codable, Identifiable, Equatable, Sendable {
    static let currentSchema = 1

    var schema: Int
    /// The file name without `.json`: lower-case words joined by hyphens.
    var id: String
    var name: String
    /// What the template is for, one sentence; may be empty.
    var note: String
    var savedAt: Date
    var workflow: ProjectWorkflow

    /// A template workflow is stored from revision 1: the revision belongs to the project that takes it.
    init(id: String, name: String, note: String, savedAt: Date, workflow: ProjectWorkflow) {
        var stored = workflow
        stored.revision = 1
        stored.name = name
        self.schema = Self.currentSchema
        self.id = id
        self.name = name
        self.note = note
        self.savedAt = savedAt
        self.workflow = stored
    }

    /// `draft` replaced by this template as a whole: states, transitions, processes and their defaults. What stays the project's own
    /// is the revision, so that a save still notices that the file moved on. Saving shows what this takes away from the work items
    /// (DEC-021).
    func applied(to draft: ProjectWorkflow) -> ProjectWorkflow {
        var result = workflow
        result.revision = draft.revision
        result.schema = ProjectWorkflow.currentSchema
        result.name = name
        return result
    }

    /// True while `draft` is this template: everything equal except the revision and the workflow's own name.
    func matches(_ draft: ProjectWorkflow) -> Bool {
        var same = workflow
        same.revision = draft.revision
        same.name = draft.name
        return same == draft
    }

    /// Some process asks for a pull request, passing checks or a GitHub release, which cannot be judged without GitHub.
    var needsGitHub: Bool { workflow.variants.contains { $0.deliveryRules.needsGitHub } }

    func outline(_ kind: IssueKind) -> String { WorkflowFlow.outline(workflow.lifecycle(kind)) }

    /// True when bugs have states of their own, so a list shows their outline too.
    var bugsDiffer: Bool { WorkflowFlow.outline(workflow.feature) != WorkflowFlow.outline(workflow.bug) }
}

enum WorkflowTemplateError: Error, LocalizedError, Equatable {
    case emptyName
    /// The workflow breaks a rule; each message says what to change.
    case invalid([String])
    case notFound(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return "A template needs a name."
        case .invalid(let problems): return "This workflow cannot be a template yet: " + problems.joined(separator: " ")
        case .notFound(let id): return "There is no template “\(id)”."
        case .writeFailed(let reason): return "The template could not be written: \(reason)"
        }
    }
}

final class WorkflowTemplateStore: @unchecked Sendable {
    /// A file that is in the folder but cannot be used.
    struct Unusable: Equatable, Identifiable, Sendable {
        let file: String
        let reason: String
        var id: String { file }
    }

    /// Everything the folder holds.
    struct Listing: Equatable, Sendable {
        /// The usable templates by name.
        var templates: [WorkflowTemplate] = []
        var unusable: [Unusable] = []
        /// What `default.json` names; may name a template that is gone or unusable (new projects then use the built-in default).
        var defaultID: String?

        /// The template new projects start on; nil when none is chosen or the chosen one cannot be used.
        var defaultTemplate: WorkflowTemplate? { defaultID.flatMap { id in templates.first { $0.id == id } } }
    }

    let folder: URL
    private let lock = NSLock()

    init(folder: URL) { self.folder = folder }

    /// `~/Library/Application Support/MarkView/WorkflowTemplates`: where the rest of the app keeps what every project shares.
    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkView/WorkflowTemplates", isDirectory: true)
    }

    static let shared = WorkflowTemplateStore(folder: defaultFolder)

    /// The pointer file; it is not a template and never listed as one.
    static let pointerName = "default.json"
    private static let maxFileSize = 2_000_000

    private var pointerURL: URL { folder.appendingPathComponent(Self.pointerName) }

    // MARK: Reading

    func list() -> Listing {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    /// The template new projects start on, or nil (none chosen, deleted, or unusable).
    func defaultTemplate() -> WorkflowTemplate? { list().defaultTemplate }

    private func read() -> Listing {
        var listing = Listing()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" && url.lastPathComponent != Self.pointerName {
            switch Self.load(url) {
            case .success(let template): listing.templates.append(template)
            case .failure(let problem): listing.unusable.append(Unusable(file: url.lastPathComponent, reason: problem.reason))
            }
        }
        listing.templates.sort { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        listing.defaultID = readPointer()
        return listing
    }

    struct Problem: Error { let reason: String }

    private static func load(_ url: URL) -> Result<WorkflowTemplate, Problem> {
        let id = url.deletingPathExtension().lastPathComponent
        guard isValid(id: id) else { return .failure(Problem(reason: "the file name is not a template id (lower-case letters, digits and hyphens)")) }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileSize {
            return .failure(Problem(reason: "the file is larger than \(maxFileSize / 1_000_000) MB"))
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .failure(Problem(reason: "the file cannot be read: \(error.localizedDescription)")) }
        return parse(data, id: id)
    }

    /// A template document. The schema is read on its own first: a file from a newer app may have a shape this app cannot decode.
    static func parse(_ data: Data, id: String) -> Result<WorkflowTemplate, Problem> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(Problem(reason: "the file is not a JSON object")) }
        guard let schema = object["schema"] as? Int else { return .failure(Problem(reason: "the file has no schema version")) }
        if schema > WorkflowTemplate.currentSchema {
            return .failure(Problem(reason: "schema \(schema) is newer than this app understands (\(WorkflowTemplate.currentSchema)); update MarkView"))
        }
        guard schema == WorkflowTemplate.currentSchema else { return .failure(Problem(reason: "schema \(schema) is not a known version")) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var template: WorkflowTemplate
        do { template = try decoder.decode(WorkflowTemplate.self, from: data) } catch {
            return .failure(Problem(reason: "the content does not match the template format: \(describe(error))"))
        }
        let workflowSchema = template.workflow.schema
        if workflowSchema > ProjectWorkflow.currentSchema {
            return .failure(Problem(reason: "its workflow has schema \(workflowSchema), newer than this app understands (\(ProjectWorkflow.currentSchema)); update MarkView"))
        }
        guard workflowSchema == ProjectWorkflow.currentSchema else { return .failure(Problem(reason: "its workflow has schema \(workflowSchema), which is not a known version")) }
        let problems = template.workflow.validate()
        guard problems.isEmpty else { return .failure(Problem(reason: "its workflow is invalid: " + problems.map(\.message).joined(separator: " "))) }
        // The file name is the id: a file copied under another name is that template, not a second one with a stale id inside.
        template.id = id
        return .success(template)
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

    private func readPointer() -> String? {
        guard let data = try? Data(contentsOf: pointerURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["template"] as? String, Self.isValid(id: id) else { return nil }
        return id
    }

    // MARK: Writing

    /// Stores `workflow` as a template. A new name gets its own file; `replacing` writes over that template's file and keeps its id.
    /// The workflow must be valid: a template is something a project can start on.
    @discardableResult
    func save(name rawName: String, note: String = "", workflow: ProjectWorkflow, replacing id: String? = nil, now: Date = Date()) throws -> WorkflowTemplate {
        lock.lock(); defer { lock.unlock() }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw WorkflowTemplateError.emptyName }
        let problems = workflow.validate()
        guard problems.isEmpty else { throw WorkflowTemplateError.invalid(problems.map(\.message)) }
        let target: String
        if let id {
            guard Self.isValid(id: id), FileManager.default.fileExists(atPath: file(id).path) else { throw WorkflowTemplateError.notFound(id) }
            target = id
        } else {
            target = uniqueID(for: name)
        }
        let template = WorkflowTemplate(id: target, name: name, note: note.trimmingCharacters(in: .whitespacesAndNewlines), savedAt: now, workflow: workflow)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.encode(template).write(to: file(target), options: .atomic)
        } catch {
            throw WorkflowTemplateError.writeFailed(error.localizedDescription)
        }
        return template
    }

    /// Removes a template; when it was the default for new projects, that choice goes with it.
    func delete(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard Self.isValid(id: id), FileManager.default.fileExists(atPath: file(id).path) else { throw WorkflowTemplateError.notFound(id) }
        do { try FileManager.default.removeItem(at: file(id)) } catch { throw WorkflowTemplateError.writeFailed(error.localizedDescription) }
        if readPointer() == id { try? FileManager.default.removeItem(at: pointerURL) }
    }

    /// Chooses the template new projects start on; nil returns to the built-in default.
    func setDefault(_ id: String?) throws {
        lock.lock(); defer { lock.unlock() }
        guard let id else {
            if FileManager.default.fileExists(atPath: pointerURL.path) {
                do { try FileManager.default.removeItem(at: pointerURL) } catch { throw WorkflowTemplateError.writeFailed(error.localizedDescription) }
            }
            return
        }
        guard Self.isValid(id: id), FileManager.default.fileExists(atPath: file(id).path) else { throw WorkflowTemplateError.notFound(id) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["template": id], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: pointerURL, options: .atomic)
        } catch {
            throw WorkflowTemplateError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Ids

    private func file(_ id: String) -> URL { folder.appendingPathComponent(id + ".json") }

    /// Where the file of a template is (for Reveal in Finder); the template need not exist.
    func url(of id: String) -> URL { file(id) }

    /// Only lower-case letters, digits and hyphens: an id is a file name inside the folder and can never point outside it.
    static func isValid(id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64, id != "default" else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// "My Kanban (no CI)" → "my-kanban-no-ci"; a name that is taken gets "-2", "-3"…
    static func slug(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        for character in name.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) { current.append(character) }
            else if !current.isEmpty { words.append(current); current = "" }
        }
        if !current.isEmpty { words.append(current) }
        let joined = words.joined(separator: "-")
        let trimmed = String(joined.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "template" : trimmed
    }

    private func uniqueID(for name: String) -> String {
        let base = Self.slug(name)
        var candidate = Self.isValid(id: base) ? base : base + "-template"
        var n = 2
        while FileManager.default.fileExists(atPath: file(candidate).path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    private static func encode(_ template: WorkflowTemplate) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(template) + Data("\n".utf8)
    }
}
