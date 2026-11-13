import Foundation

@MainActor
final class CockpitSession: ObservableObject {
    let root: URL
    @Published var goal = ""
    @Published var controls = CockpitControls()
    @Published var refinement = ""
    @Published private(set) var plan: CockpitPlan?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?

    init(root: URL) { self.root = root }

    func generate(refining: Bool = false) {
        guard !busy, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let goal = self.goal, controls = self.controls, previous = plan, refinement = self.refinement
        let root = self.root
        busy = true; error = nil
        task = Task { [weak self] in
            do {
                var agents: [String] = []
                for tool in CLITool.allCases {
                    try Task.checkCancellation()
                    if await CLIToolLocator.resolveThorough(tool) != nil { agents.append(tool.displayName) }
                }
                guard !agents.isEmpty else { throw PlanningFailure.noAgents }
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let settings = String(decoding: try encoder.encode(controls), as: UTF8.self)
                var prompt = "Goal: \(goal)\nAvailable agents: \(agents.joined(separator: ", "))\nAdvisory controls: \(settings)\n"
                prompt += "Available project actions include the MarkView MCP project, browser and control tools and the user's agent terminal. Check project capabilities before asserting an action is available.\n"
                if refining, let previous {
                    prompt += "Current plan: \(String(decoding: try encoder.encode(previous), as: UTF8.self))\nRequested changes: \(refinement)\n"
                }
                let result = try await CLICompletion.run(CLICompletion.Request(project: root, prompt: prompt,
                    systemPrompt: CockpitPlanning.systemPrompt, jsonSchema: CockpitPlanning.schema,
                    readableFolder: root, timeout: nil, label: "cockpit-plan"))
                let plan = try CockpitPlanning.parse(result.structured, goal: goal, controls: controls, availableAgents: Set(agents))
                try Task.checkCancellation()
                guard self?.goal == goal, self?.controls == controls else {
                    self?.error = "The goal or controls changed during planning. Propose the plan again."
                    self?.busy = false
                    return
                }
                self?.plan = plan; self?.refinement = ""; self?.busy = false
            } catch is CancellationError {
                self?.busy = false
            } catch {
                self?.error = error.localizedDescription; self?.busy = false
            }
        }
    }

    func cancel() { task?.cancel() }
    func invalidatePlan() { plan = nil }

    enum PlanningFailure: LocalizedError {
        case noAgents
        var errorDescription: String? { "No supported agent CLI was found." }
    }
}
