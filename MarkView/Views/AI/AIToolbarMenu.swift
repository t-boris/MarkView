import SwiftUI
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The one toolbar menu of the AI: the assistant CLI and its model for this window's project (BUG-021; other projects keep theirs), and the model
/// that X-Ray and the other large structured answers use. A window showing a single file edits the defaults, as DDE Settings does. The bar shows
/// the assistant and its model; the X-Ray model is named in the menu.
struct AIToolbarMenu: View {
    let workspaceManager: WorkspaceManager
    var compact = false
    /// The models each tool offers, as loaded (Codex's list is read from disk, so off the main thread).
    @State private var catalog: [CLITool: [AIModelOption]] = [:]
    @State private var availability: [CLITool: Bool] = [:]
    /// The look for a tool's CLI that "Check Again" starts: a second tap replaces the first, and it ends with the menu (`AR-19`).
    @State private var checks = TaskBag()
    /// Bumped when any choice changes, so the menu shows the stored values.
    @State private var refresh = 0
    @State private var seenSnapshot = ""

    private var choice: AssistantChoice { AssistantChoice(project: workspaceManager.aiProject) }
    private var tool: CLITool { choice.tool }
    private var backend: Binding<String> {
        Binding(get: { choice.tool.rawValue }, set: { choice.setTool($0) })
    }
    private var model: Binding<String> {
        let tool = tool
        return Binding(get: { choice.model(for: tool) }, set: { choice.setModel($0, for: tool) })
    }
    private var xrayModel: Binding<String> {
        let tool = tool
        return Binding(get: { choice.xrayModel(for: tool) }, set: { choice.setXRayModel($0, for: tool) })
    }

    /// The assistant's models. A model saved earlier stays selectable, but the list says that the CLI does not offer it
    /// (Codex rejects models its catalog dropped or the account cannot use).
    private var assistantOptions: [AIModelOption] {
        let id = model.wrappedValue
        guard let loaded = catalog[tool] else {
            return [AIModelOption(id: id, name: id.isEmpty ? "Default" : id, detail: "")]
        }
        return loaded.contains { $0.id == id } ? loaded
            : loaded + [AIModelOption(id: id, name: "\(id) — not in \(tool.displayName)'s list", detail: "")]
    }

    var body: some View {
        let _ = refresh
        let unavailable = availability[tool] == false
        let xrayRecommended = AIAssistantPreferences.defaultXRayModel(for: tool)
        let xrayListed = (catalog[tool] ?? []).filter { !$0.id.isEmpty }
        let xrayName = xrayModel.wrappedValue.isEmpty ? "assistant's model" : xrayModel.wrappedValue
        Menu {
            if unavailable {
                Text("Assistant unavailable. Set its CLI path in Settings.")
                Button("Open AI Settings…") { DDESettingsWindow.show(workspace: workspaceManager) }
                Button("Check Again") {
                    let selected = tool
                    checks.store(Task { availability[selected] = await CLIToolLocator.resolveThorough(selected) != nil }, for: "check-" + selected.rawValue)
                }
                Divider()
            }
            Picker("Assistant", selection: backend) {
                ForEach(CLITool.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Picker("Model", selection: model) {
                ForEach(assistantOptions) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            Divider()
            // X-Ray, operations discovery, filters and explanations write large structured answers, where a fast model matters more than raw
            // capability: the fast default is marked as recommended.
            Menu("X-Ray model · " + xrayName) {
                Picker("X-Ray model", selection: xrayModel) {
                    Text("Same as the assistant's model").tag("")
                    ForEach(xrayListed) { option in
                        Text(option.id == xrayRecommended ? "\(option.name) (Recommended)" : option.name).tag(option.id)
                    }
                    if !xrayModel.wrappedValue.isEmpty, !xrayListed.contains(where: { $0.id == xrayModel.wrappedValue }) {
                        Text(xrayModel.wrappedValue).tag(xrayModel.wrappedValue)
                    }
                }
                .pickerStyle(.inline)
                Text("Used by X-Ray, operations discovery, filters and explanations.")
            }
        } label: {
            if compact {
                Image(systemName: unavailable ? "exclamationmark.triangle" : "cpu")
            } else {
                Label(AIAssistantPreferences.summary(tool: tool, model: model.wrappedValue),
                      systemImage: unavailable ? "exclamationmark.triangle" : "cpu")
            }
        }
        // An icon-only menu has no room for the chevron: it would reach into the button beside it.
        .menuIndicator(compact ? .hidden : .automatic)
        .help(Self.helpText(unavailable: unavailable, hasProject: workspaceManager.aiProject != nil, xrayName: xrayName))
        .onAppear { seenSnapshot = AIAssistantPreferences.snapshot(project: workspaceManager.aiProject) }
        .onReceive(SettingsObserver.changes(of: AIAssistantPreferences.observedKeys)) { _ in
            let next = AIAssistantPreferences.snapshot(project: workspaceManager.aiProject)
            if next != seenSnapshot {
                seenSnapshot = next
                refresh += 1
            }
        }
        .task(id: tool) {
            let current = tool
            availability[current] = await CLIToolLocator.resolveThorough(current) != nil
            guard catalog[current] == nil else { return }
            catalog[current] = await Self.loadOptions(for: current)
        }
    }
}

extension AIToolbarMenu {
    static func helpText(unavailable: Bool, hasProject: Bool, xrayName: String) -> String {
        if unavailable {
            return "Assistant unavailable. Set its CLI path in Settings."
        }
        let scope = hasProject ? "Assistant and model for this project" : "Default assistant and model"
        return "\(scope) — the AI terminal, features and research. X-Ray model: \(xrayName)."
    }

    /// The models `tool` offers. ACP assistants list the account's models only over ACP:
    /// they are fetched the first time.
    static func loadOptions(for tool: CLITool) async -> [AIModelOption] {
        var loaded = await Task.detached { AIAssistantPreferences.modelOptions(for: tool) }.value
        if tool.usesACP, loaded.count <= 1, let path = CLIToolLocator.resolve(tool),
           let models = try? await ACPAssistant.refreshModels(tool, toolPath: path) {
            loaded = [loaded.first].compactMap { $0 } + models
        }
        return loaded
    }
}
