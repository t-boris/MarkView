import SwiftUI

// MARK: - Assistant Picker

/// Chooses the assistant CLI and its model in DDE Settings for the window's project: the same
/// choice as the project's toolbar menu, so other projects keep theirs (BUG-021, BUG-022). Without
/// a project (a single file, the welcome screen) it edits the defaults, which projects that have not
/// chosen their own follow.
struct AIAssistantPickerView: View {
    /// The project whose choice is edited; nil edits the defaults.
    let project: URL?

    @State private var options: [CLITool: [AIModelOption]] = [:]
    @State private var customModel = ""
    /// Bumped when any choice changes (here, in the toolbar or in another window), so the picker
    /// shows the stored values.
    @State private var refresh = 0

    private var choice: AssistantChoice { AssistantChoice(project: project) }
    private var backend: CLITool { choice.tool }

    private var backendRaw: Binding<String> {
        Binding(get: { choice.tool.rawValue }, set: { choice.setTool($0) })
    }

    private var selectedModel: Binding<String> {
        let tool = backend
        return Binding(get: { choice.model(for: tool) }, set: { choice.setModel($0, for: tool) })
    }

    /// Catalog for the active CLI, plus the stored model when it was typed by hand.
    private var currentOptions: [AIModelOption] {
        let catalog = options[backend] ?? []
        let stored = selectedModel.wrappedValue
        guard !stored.isEmpty, !catalog.contains(where: { $0.id == stored }) else { return catalog }
        return catalog + [AIModelOption(id: stored, name: stored, detail: "Custom model name")]
    }

    var body: some View {
        let _ = refresh
        VStack(alignment: .leading, spacing: 8) {
            Picker("Assistant", selection: backendRaw) {
                ForEach(CLITool.allCases, id: \.self) { tool in
                    Text(tool.displayName).tag(tool.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Model").uiFont(.caption, weight: .bold)

            if options[backend] == nil {
                ProgressView().scaleEffect(0.5)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(currentOptions) { option in
                        modelRow(option)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Other model name", text: $customModel)
                    .textFieldStyle(.roundedBorder)
                    .uiFont(size: 11, design: .monospaced)
                    .onSubmit(applyCustomModel)
                Button("Use", action: applyCustomModel)
                    .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text("Applies from the next message. Switching assistant starts a new session.")
                .uiFont(size: 9).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in refresh += 1 }
        .task { await loadOptions() }
    }

    private func modelRow(_ option: AIModelOption) -> some View {
        let isSelected = selectedModel.wrappedValue == option.id
        return Button(action: { selectedModel.wrappedValue = option.id }) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .uiFont(size: 11)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(option.name).uiFont(size: 11, weight: .medium)
                        if !option.id.isEmpty && option.id != option.name {
                            Text(option.id)
                                .uiFont(size: 9, design: .monospaced)
                                .foregroundColor(.secondary)
                        }
                    }
                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .uiFont(size: 9).foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3).padding(.horizontal, 4)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func applyCustomModel() {
        let name = customModel.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        selectedModel.wrappedValue = name
        customModel = ""
    }

    /// Codex's catalog is a large JSON file, so build the lists off the main thread.
    private func loadOptions() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: CLITool.allCases.map { ($0, AIAssistantPreferences.modelOptions(for: $0)) })
        }.value
        options = loaded
        // ACP assistants list the account's models; fetch them when none are cached.
        for tool in CLITool.allCases where tool.usesACP && (loaded[tool]?.count ?? 0) <= 1 {
            if let path = CLIToolLocator.resolve(tool), let models = try? await ACPAssistant.refreshModels(tool, toolPath: path) {
                options[tool] = [loaded[tool]?.first].compactMap { $0 } + models
            }
        }
    }
}
