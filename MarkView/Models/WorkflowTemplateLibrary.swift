import SwiftUI

/// The workflow templates of the shared folder as the windows see them (feature workflow-templates, REQ-001..003): one list for the
/// Flow popover of every project window and for Settings. Every read and write of a file runs off the main thread; the list is
/// published on the main actor, and is read again after each change so that no window shows a stale one.
@MainActor
final class WorkflowTemplateLibrary: ObservableObject {
    static let shared = WorkflowTemplateLibrary(store: .shared)

    @Published private(set) var listing = WorkflowTemplateStore.Listing()
    /// False until the folder has been read once, so a view can tell "no templates" from "not read yet".
    @Published private(set) var loaded = false

    let store: WorkflowTemplateStore

    init(store: WorkflowTemplateStore) { self.store = store }

    var templates: [WorkflowTemplate] { listing.templates }

    /// The template the draft is, if it is one (the Flow button shows its name).
    func template(matching draft: ProjectWorkflow) -> WorkflowTemplate? { listing.templates.first { $0.matches(draft) } }

    func reload() async {
        let store = store
        listing = await Task.detached(priority: .utility) { store.list() }.value
        loaded = true
    }

    /// Stores `workflow` as a template; `replacing` writes over that template. The error text is what a person reads.
    func save(name: String, note: String, workflow: ProjectWorkflow, replacing id: String?) async -> Result<WorkflowTemplate, WorkflowTemplateError> {
        let store = store
        let result: Result<WorkflowTemplate, WorkflowTemplateError> = await Task.detached(priority: .userInitiated) {
            do { return .success(try store.save(name: name, note: note, workflow: workflow, replacing: id)) }
            catch let error as WorkflowTemplateError { return .failure(error) }
            catch { return .failure(.writeFailed(error.localizedDescription)) }
        }.value
        await reload()
        return result
    }

    /// Returns the reason when the template could not be deleted.
    func delete(_ id: String) async -> String? {
        let store = store
        let problem: String? = await Task.detached(priority: .userInitiated) {
            do { try store.delete(id); return nil } catch { return error.localizedDescription }
        }.value
        await reload()
        return problem
    }

    /// Chooses the template new projects start on; nil goes back to the built-in default. Returns the reason on failure.
    func setDefault(_ id: String?) async -> String? {
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
