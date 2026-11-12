import Foundation

/// What the review of observed file changes shows and asks for: the files the scanner found changed, and the assistant's reading of them.
/// The scanner itself (disk walking, no UI, no AI) is in ProjectChangeReview.swift so that tools/tests/project-change-tests.sh can compile it alone.
@MainActor
final class ProjectChangeReview: ObservableObject {
    @Published private(set) var changes: [ProjectChange] = []
    @Published private(set) var isScanning = false
    @Published var error: String?
    /// The assistant's reading of a file's changes, by `explanationKey`; asked for by the person, never automatically.
    @Published private(set) var explanations: [String: ChangeExplanation] = [:]
    @Published private(set) var explaining: Set<String> = []
    @Published private(set) var explanationFailures: [String: String] = [:]

    private let scanner = ProjectChangeScanner()
    private var project: URL?
    private var monitor: ProjectChangeMonitor?
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false

    /// One reading belongs to one pair of texts: a file that changes again is a new question.
    static func explanationKey(_ change: ProjectChange) -> String {
        ContentHash.of("\(change.path)\u{0}\(change.before ?? "")\u{0}\(change.current ?? "")")
    }

    func open(_ project: URL?) async {
        monitor = nil
        refreshTask?.cancel()
        self.project = project
        isScanning = true
        if let project {
            monitor = ProjectChangeMonitor(root: project) { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        }
        defer {
            isScanning = false
            if refreshPending { refreshPending = false; scheduleRefresh() }
        }
        do {
            try await scanner.open(project)
            guard !Task.isCancelled, self.project == project else { return }
            changes = []
            explanations = [:]
            explanationFailures = [:]
            error = nil
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard !isScanning else { refreshPending = true; return }
        isScanning = true
        defer {
            isScanning = false
            if refreshPending { refreshPending = false; scheduleRefresh() }
        }
        do {
            changes = try await scanner.refresh()
            error = nil
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func acknowledge() async {
        await scanner.acknowledge()
        changes = []
        explanations = [:]
        explanationFailures = [:]
    }

    /// Ask the project's assistant what each change of `change` does, why it was probably made and what it affects (BUG-109). The
    /// file's changes and the assistant's read-only access to the project are the only things that leave this app, and only here.
    func explain(_ change: ProjectChange, hunks: [DiffHunk]) {
        let key = Self.explanationKey(change)
        guard !hunks.isEmpty, explanations[key] == nil, !explaining.contains(key) else { return }
        explaining.insert(key)
        explanationFailures[key] = nil
        let asked = ChangeExplainer.prompt(path: change.path, kind: change.kind.rawValue, hunks: hunks)
        var request = CLICompletion.Request(project: project, prompt: asked.text,
                                            systemPrompt: ChangeExplainer.systemPrompt(language: ActionOutputLanguage.current),
                                            jsonSchema: ChangeExplainer.schema)
        request.readableFolder = project
        request.timeout = 300
        request.effort = "low"
        request.label = "change-review"
        Task {
            defer { explaining.remove(key) }
            do {
                let result = try await CLICompletion.run(request)
                guard let object = result.structured as? [String: Any],
                      let reading = ChangeExplainer.parse(object, hunkCount: asked.included) else {
                    explanationFailures[key] = "The assistant's answer did not explain these changes. Try again."
                    return
                }
                explanations[key] = reading
            } catch is CancellationError {
            } catch {
                explanationFailures[key] = error.localizedDescription
            }
        }
    }
}
