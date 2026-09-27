import Foundation
import Combine

/// One run of Start a Project from Scratch in a window: idea → adaptive clarification →
/// confirmed brief → destination → local project → optional GitHub (REQ-001…004).
///
/// Clarification reuses the feature discovery on a draft workspace outside any project
/// (DEC-015, DEC-021): its own FeatureStore and FeatureAssistant, without GitHub (no issue is
/// filed) and without lifecycle events.
@MainActor
final class NewProjectFlow: ObservableObject {
    enum Step: Equatable {
        case idea
        case clarify
        case destination
        case github(URL)
    }

    @Published private(set) var step: Step = .idea
    @Published private(set) var draft: ProjectDraft?
    @Published private(set) var working = false
    @Published var error: String?
    /// Chosen destination (DEC-009).
    @Published var parentFolder: URL
    @Published var folderName = ""

    let store = FeatureStore()
    var assistant: FeatureAssistant { store.assistant }
    private let drafts = ProjectDraftStore.shared

    private static let parentKey = "newProject.parentFolder"
    /// The specification and the AI's running jobs change inside the store and the assistant; the
    /// sheet's buttons (Confirm Brief) follow them through this flow.
    private var forwarding: [AnyCancellable] = []

    init(resume id: UUID? = nil) {
        store.recordsLifecycle = false
        let saved = UserDefaults.standard.string(forKey: Self.parentKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        parentFolder = saved.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? Self.defaultParent
        assistant.projectDiscovery = true
        forwarding = [
            store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            assistant.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
        ]
        if let id, let draft = drafts.draft(id) { load(draft) }
    }

    /// ~/Developer when it exists, else ~/Documents.
    private static var defaultParent: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let developer = home.appendingPathComponent("Developer", isDirectory: true)
        return FileManager.default.fileExists(atPath: developer.path) ? developer : home.appendingPathComponent("Documents", isDirectory: true)
    }

    private func load(_ draft: ProjectDraft) {
        self.draft = draft
        store.setup(root: drafts.workspace(draft.id))
        if let parent = draft.parentPath { parentFolder = URL(fileURLWithPath: parent, isDirectory: true) }
        folderName = draft.folderName ?? ProjectNaming.suggestedFolderName(draft.title.isEmpty ? draft.displayTitle : draft.title)
        error = draft.lastError
        step = draft.stage == .clarifying ? .clarify : .destination
    }

    // MARK: The specification being clarified

    var feature: Feature? { draft?.slug.flatMap { store.feature($0) } }

    var openQuestions: [ProjectConfirmation.OpenQuestion] {
        (feature?.list(.question) ?? []).filter { $0.status == "open" }
            .map { ProjectConfirmation.OpenQuestion(id: $0.id, title: $0.title, blocking: $0.isBlocking) }
    }

    var goal: String { feature.map { ProjectFoundation.section("Idea", of: $0.overviewBody) } ?? "" }

    var canConfirm: Bool { ProjectConfirmation.canConfirm(goal: goal, open: openQuestions) }

    /// A folder this draft already created still exists: Retry continues there, so the destination
    /// cannot change (no orphaned folder). When it is gone, a new destination may be chosen.
    var creationLocked: Bool {
        guard let path = draft?.createdPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: Steps

    /// The first idea: a draft is saved at once (it survives closing the window), then the AI
    /// turns the idea into the start of the specification.
    func start(idea: String, attachments: [URL]) async {
        let text = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !working else { return }
        let new = ProjectDraft(idea: text)
        do { try await drafts.save(new) } catch {
            self.error = "Could not save the draft: \(error.localizedDescription)"
            return
        }
        draft = new
        store.setup(root: drafts.workspace(new.id))
        step = .clarify
        await analyze(attachments: attachments)
    }

    /// The idea → overview, first requirements and questions. Retried from the clarify step
    /// when the AI failed.
    func analyze(attachments: [URL] = []) async {
        guard var draft, draft.slug == nil, !working else { return }
        working = true
        defer { working = false }
        error = nil
        guard let outcome = await assistant.newFeature(from: draft.idea, attachments: attachments), let slug = outcome.feature else {
            error = assistant.error ?? "The AI could not analyze the idea."
            return
        }
        draft.slug = slug
        draft.title = store.feature(slug)?.title ?? ""
        await save(draft)
    }

    /// The user confirms the brief (DEC-003, DEC-016). Recorded in the overview.
    func confirm() async {
        guard var draft, let slug = draft.slug, canConfirm else { return }
        store.updateFeature(slug) { front, _ in front.set("confirmed", FeatureStore.today) }
        draft.title = feature?.title ?? draft.title
        draft.stage = .confirmed
        if draft.folderName == nil { folderName = ProjectNaming.suggestedFolderName(draft.title) }
        await save(draft)
        step = .destination
    }

    /// Back from the destination to clarification: the brief needs to be confirmed again.
    func reopenClarification() async {
        guard var draft, !creationLocked else { return }
        draft.stage = .clarifying
        await save(draft)
        step = .clarify
    }

    /// Create (or continue creating) the local project (REQ-004). The draft is removed only
    /// after every stage succeeded; on failure it keeps the stage reached for Retry (DEC-019).
    func create() async -> URL? {
        guard var draft, let slug = draft.slug, let feature, !working else { return nil }
        if let problem = ProjectNaming.folderNameProblem(folderName) { error = problem; return nil }
        working = true
        defer { working = false }
        error = nil
        draft.parentPath = parentFolder.path
        draft.folderName = folderName
        draft.stage = .creating
        draft.lastError = nil
        UserDefaults.standard.set(parentFolder.path, forKey: Self.parentKey)
        let readme = ProjectFoundation.readme(
            title: feature.title, idea: goal,
            problem: ProjectFoundation.section("Problem", of: feature.overviewBody),
            scope: ProjectFoundation.section("Scope", of: feature.overviewBody),
            specificationPath: FeatureStore.folderName + "/" + slug,
            requirements: feature.activeRequirements.map { (id: $0.id, title: $0.title) },
            openQuestions: feature.list(.question).filter { $0.status == "open" }.map { (id: $0.id, title: $0.title) })
        let drafts = drafts
        do {
            let url = try await ProjectBootstrap.run(&draft, specification: feature.folder, slug: slug, readme: readme) { saved in
                try await drafts.save(saved)
            }
            self.draft = draft
            await drafts.remove(draft.id)
            step = .github(url)
            return url
        } catch {
            draft.lastError = error.localizedDescription
            self.error = error.localizedDescription
            await save(draft)
            return nil
        }
    }

    /// Discard the unfinished draft (DEC-015).
    func discard() async {
        guard let draft else { return }
        store.reset()
        await drafts.remove(draft.id)
        self.draft = nil
    }

    private func save(_ draft: ProjectDraft) async {
        self.draft = draft
        do { try await drafts.save(draft) } catch {
            self.error = "Could not save the draft: \(error.localizedDescription)"
        }
    }
}

/// Shows Start a Project from Scratch in a window: a new idea, or `resume` an unfinished draft.
struct NewProjectRequest: Identifiable {
    let id = UUID()
    var resume: UUID?
}
