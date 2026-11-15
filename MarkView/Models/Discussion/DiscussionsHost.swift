import Foundation

/// The Discussions tool of a window: the store of the project's discussions, and the project's assistant answering inside them. The
/// answer streams into `store.live` and becomes a turn when it is finished. The host owns what the answer needs (one request in
/// flight, its event stream) in a `TaskBag`: stopping, switching the folder and closing the window cancel it (`AR-19`).
@MainActor
final class DiscussionsHost {
    let store = DiscussionStore()
    private let project: any ProjectProviding
    private weak var tabs: (any ToolOpening)?
    private let tasks = TaskBag()
    private let runner: AIOperation<CLICompletion.Request, CLICompletion.Result>.Runner

    /// What the assistant's run reports while it is asked, in order, to be applied on the main actor.
    private enum Event: Sendable {
        case delta(String)
        case activity(CLICompletion.Activity)
        case finished(String)
        case stopped
        case failed(String)
    }

    init(project: any ProjectProviding, tabs: any ToolOpening, runner: @escaping AIOperation<CLICompletion.Request, CLICompletion.Result>.Runner = AIAssistantRunner.run) {
        self.project = project
        self.tabs = tabs
        self.runner = runner
    }

    /// What opening the Discussions tab does: the store reads the project's folder.
    var opener: ToolOpener {
        ToolOpener(prepare: { [store] root in store.setRoot(root) })
    }

    /// The folder finished opening. An answer being written for another folder is dropped.
    func projectOpened(_ root: URL) {
        if store.root?.standardizedFileURL != root.standardizedFileURL { tasks.cancelAll() }
        store.setRoot(root)
    }

    /// The window lets go of its folder.
    func projectClosed() {
        tasks.cancelAll()
        store.setRoot(nil)
    }

    /// The window closes: nothing it started goes on.
    func close() { tasks.cancelAll() }

    /// Discussions → ask: the project's assistant reads the project (read-only) and answers inside the conversation,
    /// in the form the question needs. The answer streams into `store.live`, then becomes a turn.
    func ask(_ slug: String, question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = project.root, !text.isEmpty, store.asking == nil,
              let discussion = store.discussions.first(where: { $0.slug == slug }) else { return }
        store.asking = slug
        store.live = DiscussionStore.Live(question: text)
        store.lastError = nil
        let scope = Self.scope(of: discussion, root: root)
        var request = CLICompletion.Request(
            project: project.aiProject ?? root,
            prompt: DiscussionPrompt.prompt(discussion: discussion, question: text, scope: scope.description,
                                            language: ActionOutputLanguage.explanationLine()),
            systemPrompt: DiscussionPrompt.system, readableFolder: scope.readable)
        if scope.readable.standardizedFileURL != root.standardizedFileURL { request.extraReadableFolders = [root] }
        request.effort = "medium"
        request.timeout = 900
        request.label = "discussion"

        var continuation: AsyncStream<Event>.Continuation!
        let events = AsyncStream<Event> { continuation = $0 }
        let sink = continuation!
        tasks.store(Task { [weak self] in
            for await event in events { self?.apply(event, slug: slug, question: text) }
        }, for: "events")
        let runner = runner
        tasks.store(Task {
            do {
                let result = try await AIOperation<CLICompletion.Request, CLICompletion.Result>.run(name: "discussion", runner: runner)
                    .execute(request, onDelta: { sink.yield(.delta($0)) }, onActivity: { sink.yield(.activity($0)) }).result
                try Task.checkCancellation()
                sink.yield(.finished(result.text))
            } catch is CancellationError {
                sink.yield(.stopped)
            } catch {
                sink.yield(.failed(error.localizedDescription))
            }
            sink.finish()
        }, for: "ask")
    }

    /// Stops the answer being written; what was written so far is dropped.
    func stop() { tasks.cancel(key: "ask") }

    /// File tree → "Discuss…": a discussion about this file or folder.
    func discuss(about url: URL) {
        guard let root = project.root else { return }
        tabs?.open(.discussions)
        let rel = project.relativePath(of: url)
        let path = url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") ? rel : url.path
        if let existing = store.discussions.first(where: { $0.scope == path && $0.turns.isEmpty }) {
            store.selectedSlug = existing.slug
        } else {
            store.create(title: url.lastPathComponent, scope: path)
        }
    }

    private func apply(_ event: Event, slug: String, question: String) {
        switch event {
        case .delta(let delta):
            guard store.asking == slug else { return }
            store.live?.text += delta
            store.live?.status = "Writing the answer"
        case .activity(let activity):
            guard store.asking == slug else { return }
            switch activity {
            case .read(let path): store.live?.status = DiscussionPrompt.status(read: path); store.live?.text = ""
            case .search(let pattern): store.live?.status = "Searching for \(pattern.prefix(40))"; store.live?.text = ""
            case .run: store.live?.status = "Looking at the project"; store.live?.text = ""
            case .webSearch, .webFetch: store.live?.status = "Reading the web"; store.live?.text = ""
            case .thinking: store.live?.status = "Thinking"
            case .writing, .answerDelta: break
            }
        case .finished(let text):
            defer { store.asking = nil; store.live = nil }
            guard let answer = DiscussionPrompt.parse(text),
                  store.addTurn(slug, question: question, answer: answer.answer, followUps: [],
                                decisions: answer.decisions, openQuestions: answer.openQuestions) != nil else {
                store.lastError = "The assistant gave no answer."
                return
            }
        case .stopped:
            store.asking = nil
            store.live = nil
        case .failed(let message):
            store.lastError = message
            store.asking = nil
            store.live = nil
        }
    }

    /// Where the conversation looks: the text the assistant is told, and the folder it may read.
    private static func scope(of discussion: Discussion, root: URL) -> (description: String, readable: URL) {
        let raw = discussion.scope ?? ""
        guard !raw.isEmpty else { return ("The whole project (\(root.lastPathComponent))", root) }
        let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : root.appendingPathComponent(raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return ("The whole project (\(root.lastPathComponent)); the chosen path \(raw) no longer exists", root)
        }
        let inside = url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
        let readable = inside ? root : (isDirectory.boolValue ? url : url.deletingLastPathComponent())
        return ("\(isDirectory.boolValue ? "The folder" : "The file") `\(raw)`. Stay on it; look elsewhere only when it is needed to answer.", readable)
    }
}
