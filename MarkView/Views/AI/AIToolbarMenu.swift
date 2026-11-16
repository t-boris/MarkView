import SwiftUI
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The one toolbar menu of the AI: the assistant CLI and its model for this window's project (BUG-021; other projects keep theirs), the model
/// that X-Ray and the other large structured answers use, and the AI tools (diagrams, prototypes, analyses). A window showing a single file
/// edits the defaults, as DDE Settings does. The bar shows the assistant and its model; the X-Ray model is named in the menu.
struct AIToolbarMenu: View {
    let workspaceManager: WorkspaceManager
    /// Passed in: toolbar content does not get the window's environment objects.
    let fileTree: WorkspaceFileTreeStore
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
            AIToolsMenuItems(workspaceManager: workspaceManager, fileTree: fileTree)
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
        .help(unavailable ? "Assistant unavailable. Set its CLI path in Settings." :
              (workspaceManager.aiProject == nil ? "Default assistant and model" : "Assistant and model for this project")
              + " — the AI terminal, features and research. X-Ray model: \(xrayName). The menu also holds the AI tools.")
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

/// The AI tools, as submenus of the AI menu: diagrams (Graph Creator), prototypes and the analyses that work.
private struct AIToolsMenuItems: View {
    // Passed in: toolbar content does not get the window's environment objects.
    @ObservedObject var workspaceManager: WorkspaceManager
    @ObservedObject var fileTree: WorkspaceFileTreeStore

    var body: some View {
        Menu("Diagrams") {
            Button("System Architecture") { workspaceManager.runAITool(named: "architecture") }
            Button("Data Flow") { workspaceManager.runAITool(named: "dataflow") }
            Button("Pipeline") { workspaceManager.runAITool(named: "pipeline") }
            Button("Deployment") { workspaceManager.runAITool(named: "deployment") }
            Button("Sequence") { workspaceManager.runAITool(named: "sequence") }
            Button("Entity-Relationship") { workspaceManager.runAITool(named: "er") }
        }
        Menu("Prototype") {
            Button("New Prototype…") { workspaceManager.toolTabs.prototypes.openCreator(mode: .requirements) }
                .disabled(fileTree.rootNode == nil)
            // Existing code opens as the real application in UI Studio, not as a reconstruction (DEC-002, DEC-005).
            Button("UI Studio (Existing Code)") { workspaceManager.openTool(.uiStudio) }
                .disabled(fileTree.rootNode == nil)
            let saved = workspaceManager.toolTabs.prototypes.saved()
            Menu("Open Prototype (\(saved.count))") {
                if saved.isEmpty {
                    Text("No prototypes in this project yet")
                } else {
                    ForEach(saved) { prototype in
                        Button(prototype.label) { workspaceManager.toolTabs.prototypes.openSaved(prototype.slug) }
                    }
                }
            }
            .disabled(fileTree.rootNode == nil || saved.isEmpty)
        }
        Menu("Analysis") {
            Button("Constructive Critic") { workspaceManager.runAITool(named: "critic") }
            // Superseded by New Research, which saves a report (DEC-010).
            Button("Deep Research…") { workspaceManager.flow.newResearch() }
            Button("Codebase Audit") { workspaceManager.runAITool(named: "audit") }
            Button("Code Structure Map") { workspaceManager.runAITool(named: "codemap") }
            Button("Recursive Insight") { workspaceManager.insight.start() }
                .disabled(fileTree.rootNode == nil || !fileTree.hasMarkdownFiles)
        }
    }
}
