import SwiftUI
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The workflow templates of the shared folder as the windows see them (feature workflow-templates, REQ-001..003): one list for the
/// Flow popover of every project window and for Settings. Every read and write of a file runs off the main thread; the list is
/// published on the main actor, and is read again after each change so that no window shows a stale one.
///
/// A change is started with `startSave`, `startDelete` or `startSetDefault` (`AR-19`): they return at once, keep the work here under a
/// key and tell the caller how it ended. A change of the same kind that is asked for while one is under way replaces it, and its
/// answer is dropped.
@MainActor
final class WorkflowTemplateLibrary: ObservableObject {
    static let shared = WorkflowTemplateLibrary(store: .shared)

    @Published private(set) var listing = WorkflowTemplateStore.Listing()
    /// False until the folder has been read once, so a view can tell "no templates" from "not read yet".
    @Published private(set) var loaded = false

    let store: WorkflowTemplateStore
    private let tasks = TaskBag()

    init(store: WorkflowTemplateStore) { self.store = store }

    var templates: [WorkflowTemplate] { listing.templates }

    /// The template the draft is, if it is one (the Flow button shows its name).
    func template(matching draft: ProjectWorkflow) -> WorkflowTemplate? { listing.templates.first { $0.matches(draft) } }

    func reload() async {
        let store = store
        listing = await Task.detached(priority: .utility) { store.list() }.value
        loaded = true
    }

    /// Stores `workflow` as a template; `replacing` writes over that template. `finished` gets the template, or the error whose text a
    /// person reads, once the list is read again.
    func startSave(name: String, note: String, workflow: ProjectWorkflow, replacing id: String?,
                   finished: @escaping @MainActor (Result<WorkflowTemplate, WorkflowTemplateError>) -> Void) {
        tasks.store(Task { [weak self] in
            guard let self else { return }
            let result = await self.save(name: name, note: note, workflow: workflow, replacing: id)
            guard !Task.isCancelled else { return }
            finished(result)
        }, for: "save")
    }

    /// Deletes a template; `finished` gets the reason when it could not be deleted.
    func startDelete(_ id: String, finished: @escaping @MainActor (String?) -> Void) {
        tasks.store(Task { [weak self] in
            guard let self else { return }
            let problem = await self.delete(id)
            guard !Task.isCancelled else { return }
            finished(problem)
        }, for: "choose")
    }

    /// Chooses the template new projects start on (nil: the built-in default); `finished` gets the reason on failure.
    func startSetDefault(_ id: String?, finished: @escaping @MainActor (String?) -> Void) {
        tasks.store(Task { [weak self] in
            guard let self else { return }
            let problem = await self.setDefault(id)
            guard !Task.isCancelled else { return }
            finished(problem)
        }, for: "choose")
    }

    private func save(name: String, note: String, workflow: ProjectWorkflow, replacing id: String?) async -> Result<WorkflowTemplate, WorkflowTemplateError> {
        let store = store
        let result: Result<WorkflowTemplate, WorkflowTemplateError> = await Task.detached(priority: .userInitiated) {
            do { return .success(try store.save(name: name, note: note, workflow: workflow, replacing: id)) }
            catch let error as WorkflowTemplateError { return .failure(error) }
            catch { return .failure(.writeFailed(error.localizedDescription)) }
        }.value
        await reload()
        return result
    }

    private func delete(_ id: String) async -> String? {
        let store = store
        let problem: String? = await Task.detached(priority: .userInitiated) {
            do { try store.delete(id); return nil } catch { return error.localizedDescription }
        }.value
        await reload()
        return problem
    }

    private func setDefault(_ id: String?) async -> String? {
        let store = store
        let problem: String? = await Task.detached(priority: .userInitiated) {
            do { try store.setDefault(id); return nil } catch { return error.localizedDescription }
        }.value
        await reload()
        return problem
    }

    /// Makes sure the folder exists, off the main thread, so that Reveal in Finder has something to show.
    func ensureFolder() async -> URL {
        let store = store
        return await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
            return store.folder
        }.value
    }
}
