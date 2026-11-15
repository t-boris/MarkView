import Foundation

/// The in-app answer to a question about an environment: MarkView looks (state and logs, read-only), then asks the
/// project's own assistant (`CLICompletion`: no tools, nothing can change) to read that evidence, and shows the
/// answer in the Deployments tab. The assistant in the Agents tab, which can run commands, stays a second step.
@MainActor
final class DeploymentAdvisor: ObservableObject {
    struct Exchange: Identifiable, Equatable {
        enum State: Equatable { case working(String), done, failed(String) }
        let id = UUID()
        let question: String
        var answer = ""
        var state: State
        var evidence: [String] = []
        let at = Date()
    }

    @Published private(set) var exchanges: [String: [Exchange]] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func latest(_ env: String) -> Exchange? { exchanges[env]?.last }
    func isWorking(_ env: String) -> Bool { if case .working? = latest(env)?.state { return true } else { return false } }

    /// `log`: a log the person is reading (sent as evidence too). `record` adds the run to the usage counter.
    func ask(_ question: String, env: DeploymentEnvironment, store: DeploymentStore, root: URL?, log: (title: String, text: String)? = nil,
             record: @escaping @MainActor (CLICompletion.Result) -> Void) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isWorking(env.id) else { return }
        let exchange = Exchange(question: q, state: .working("Looking at \(env.name)…"))
        exchanges[env.id, default: []].append(exchange)
        if exchanges[env.id]!.count > 8 { exchanges[env.id]!.removeFirst() }
        let id = exchange.id
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            @MainActor func update(_ change: (inout Exchange) -> Void) {
                guard var list = exchanges[env.id], let i = list.firstIndex(where: { $0.id == id }) else { return }
                change(&list[i]); exchanges[env.id] = list
            }
            // 1. The state, now.
            await store.refresh(env.id)
            var evidence: [(title: String, text: String)] = []
            if let log { evidence.append(log) }
            // 2. The logs that matter.
            let plan = DeploymentLogs.evidencePlan(question: q, env: env, snapshot: store.states[env.id]?.snapshot)
            for source in plan {
                if Task.isCancelled { return }
                update { $0.state = .working("Reading \(source.title)…") }
                if case .ran(let result) = await store.run(source.command, on: env.id, origin: "Ask the AI", purpose: "Read \(source.title) to answer a question", timeout: 40) {
                    let text = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).suffix(90).joined(separator: "\n")
                    evidence.append((source.title, result.succeeded ? text : "(could not be read: \(result.stderr.split(separator: "\n").first.map(String.init) ?? "exit \(result.status)"))"))
                }
            }
            // Cloud commands already ran during the look.
            for command in env.cloudCommands { if let out = store.states[env.id]?.cloud[command.id] { evidence.append((command.title, out.result.succeeded ? out.result.stdout : out.result.stderr)) } }
            update { $0.evidence = evidence.map(\.title) }
            // 3. The assistant reads it.
            update { $0.state = .working("Asking the assistant to read it…") }
            let prompt = DeploymentPrompt.answer(environment: env.name, id: env.id, question: q, report: store.report(for: env.id), evidence: evidence)
            var request = CLICompletion.Request(project: root, prompt: prompt)
            request.timeout = 150
            request.label = "deployments:\(env.id)"
            do {
                let result = try await CLICompletion.run(request, onDelta: { text in
                    Task { @MainActor in update { $0.answer += text; if case .working = $0.state { $0.state = .working("Writing the answer…") } } }
                })
                update { if $0.answer.isEmpty { $0.answer = result.text }; $0.state = .done }
                record(result)
            } catch is CancellationError {
                update { $0.state = .failed("Stopped.") }
            } catch {
                update { $0.state = .failed(error.localizedDescription) }
            }
            tasks[id] = nil
        }
    }

    func cancel(_ env: String) {
        guard let current = latest(env) else { return }
        tasks[current.id]?.cancel()
    }

    func clear(_ env: String) { exchanges[env] = nil }
}
