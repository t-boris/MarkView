import Combine
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The Deployments tool of a window: where the project runs and how each place is doing (`store`), the answers the project's assistant
/// reads out of an environment (`advisor`), and the two ways the tab asks the assistant in the Agents panel for more.
@MainActor
final class DeploymentsHost {
    let store = DeploymentStore()
    let advisor = DeploymentAdvisor()
    private let project: any ProjectProviding
    private let assistants: any AssistantPrompting
    /// Brings the Deployments tab forward (the window's own way to open a tool).
    private let showTab: () -> Void
    /// Follows the store's request for the tab; started when the tab is first opened.
    private var attention: AnyCancellable?

    init(project: any ProjectProviding, assistants: any AssistantPrompting, showTab: @escaping () -> Void) {
        self.project = project
        self.assistants = assistants
        self.showTab = showTab
    }

    /// What opening the Deployments tab does: the store reads the project's folder, and asks for the tab when an approval waits.
    func prepare(_ root: URL) {
        store.setRoot(root)
        attention = store.needsAttention.sink { [weak self] in self?.showTab() }
    }

    /// The folder finished opening: the store reads it, also when the tab was never opened (agents use the store).
    func projectOpened(_ root: URL) { store.setRoot(root) }

    /// The window lets go of its folder.
    func projectClosed() { store.setRoot(nil) }

    /// The window closes: the store's auto-refresh and looks, a request waiting for a yes, and the answers being written end.
    func close() {
        store.close()
        advisor.close()
    }

    /// Answers a question about an environment from what MarkView read of it (and the log being read), in the tab.
    func advise(_ question: String, env: DeploymentEnvironment, log: (title: String, text: String)? = nil) {
        let project = project
        advisor.ask(question, env: env, store: store, root: store.root, log: log) { result in
            result.record(in: project.database)
        }
    }

    /// Deployments → "Ask AI to find where it runs": the assistant reads the project and proposes environments.
    func analyzeWithAI() {
        guard let root = project.root else { return }
        guard !assistants.assistantIsBusy else { store.lastError = "The assistant is still working."; return }
        let prompt = DeploymentPrompt.analyze(project: root.lastPathComponent, existing: store.environments.map(\.name), hasMCP: true)
        assistants.sendToAssistant(prompt, submit: true)
    }

    /// Deployments → "Ask the AI": a question about one environment goes to the assistant with what MarkView
    /// last saw (and the log being read); it looks with the markview_deployments tools.
    func askAssistant(_ id: String, question: String, logTitle: String? = nil, log: String? = nil) {
        guard let env = store.environment(id) else { return }
        guard !assistants.assistantIsBusy else { store.lastError = "The assistant is still working."; return }
        let prompt = DeploymentPrompt.ask(environment: env.name, id: env.id, question: question, report: store.report(for: id), logTitle: logTitle, log: log)
        assistants.sendToAssistant(prompt, submit: true)
    }
}
