import SwiftUI

/// Sheet for creating a new graph diagram from selected source documents
struct GraphCreatorSheet: View {
    @Environment(\.palette) private var palette
    let workspaceManager: WorkspaceManager
    @EnvironmentObject private var tabs: TabsController
    @Binding var isPresented: Bool
    var preselectedType: String = "architecture"

    @State private var selectedFiles: Set<String> = []
    @State private var cachedFiles: [String] = []
    @State private var loadingFiles = true
    @State private var diagramType = "architecture"
    @State private var customPrompt = ""
    @FocusState private var promptFocused: Bool

    private let diagramTypes = [
        ("architecture", "System Architecture", "C4 component diagram showing all systems, services, databases and their connections"),
        ("dataflow", "Data Flow", "Data flow diagram showing where data comes from, how it is transformed and where it goes"),
        ("pipeline", "Data Pipeline", "Pipeline diagram showing the processing stages data passes through"),
        ("sequence", "Sequence Diagram", "Sequence diagram showing interactions between components"),
        ("er", "Entity-Relationship", "ER diagram showing data models and their relationships"),
        ("deployment", "Deployment", "Deployment diagram showing infrastructure, servers, and services"),
        ("flowchart", "Flowchart", "Process flowchart showing decision points and actions"),
        ("custom", "Custom", "Custom diagram — describe what you want in the prompt below"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .uiFont(size: 16).foregroundColor(palette.blue)
                Text("New Graph Diagram").uiFont(.title3, weight: .bold).foregroundColor(palette.text)
                Spacer()
            }

            // Source documents
            GroupBox("Source Documents") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(selectedFiles.count) selected").uiFont(.caption).foregroundColor(palette.textDim)
                        if loadingFiles { ProgressView().controlSize(.mini) }
                        Spacer()
                        Button("Current") { selectCurrentFile() }.uiFont(.caption)
                        Button("All") { selectAll() }.uiFont(.caption)
                        Button("None") { selectedFiles.removeAll() }.uiFont(.caption)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(cachedFiles, id: \.self) { file in
                                HStack(spacing: 6) {
                                    Image(systemName: selectedFiles.contains(file) ? "checkmark.square.fill" : "square")
                                        .uiFont(size: 11)
                                        .foregroundColor(selectedFiles.contains(file) ? palette.blue : .secondary)
                                    Text(file).uiFont(size: 11).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { toggle(file) }
                            }
                        }
                    }.frame(maxHeight: 150)
                    .accessibilityRepresentation {
                        VStack {
                            ForEach(cachedFiles, id: \.self) { file in
                                Button(file) { toggle(file) }
                                    .accessibilityValue(selectedFiles.contains(file) ? "Selected" : "Not selected")
                            }
                        }
                    }
                }.padding(6)
            }

            // Diagram type
            GroupBox("Diagram Type") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $diagramType) {
                        ForEach(diagramTypes, id: \.0) { type in
                            Text(type.1).tag(type.0)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }.padding(6)
            }

            // Custom prompt
            if diagramType == "custom" {
                GroupBox("Custom Prompt") {
                    DictationInput(text: $customPrompt, isFocused: { promptFocused }) { voice in
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $customPrompt)
                                .uiFont(size: 12)
                                .focused($promptFocused)
                                .frame(minHeight: 60)
                                .padding(4)
                                .overlay(alignment: .bottomTrailing) { voice.mic().padding(4) }
                            voice.status
                        }
                    }
                }
            }

            // Buttons
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Text(selectedFiles.isEmpty ? "No documents: the assistant works from the code" : "")
                    .uiFont(.caption).foregroundColor(palette.textDim)
                Button("Generate") { generate() }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.blue)
            }
        }
        .padding(20)
        .frame(width: 500, height: 550)
        .onAppear { diagramType = preselectedType }
        // The document list is a walk of the project tree: it runs off the main thread and the list fills in when it is done.
        .task {
            let loaded = await availableFiles()
            cachedFiles = loaded
            loadingFiles = false
            // Pre-select current file if one is open
            if let tab = tabs.activeTab {
                let currentFile = tab.url.lastPathComponent
                // Only the open document by default: many documents blur the diagram's question.
                selectedFiles = Set(loaded.filter { $0.hasSuffix(currentFile) })
            }
        }
    }

    // MARK: - Helpers

    private func availableFiles() async -> [String] {
        guard let root = workspaceManager.rootNode?.url else { return [] }
        return await Task.detached(priority: .userInitiated) { BackgroundFileScans.markdownPaths(in: root) }.value
    }

    private func selectAll() {
        selectedFiles = Set(cachedFiles)
    }

    private func toggle(_ file: String) {
        if selectedFiles.contains(file) { selectedFiles.remove(file) }
        else { selectedFiles.insert(file) }
    }

    private func selectCurrentFile() {
        guard let currentFile = tabs.activeTab?.url, let root = workspaceManager.rootNode?.url else { return }
        let relative = currentFile.path.replacingOccurrences(of: root.path + "/", with: "")
        selectedFiles = [relative]
    }

    private func generate() {
        guard !selectedFiles.isEmpty || diagramType == "custom" else { return }
        guard let kind = DiagramKind(rawValue: diagramType) else { return }
        // The agent works headless; progress and errors show in the banner, the result opens when done.
        workspaceManager.generateDiagram(kind: kind, instruction: diagramType == "custom" ? customPrompt : "",
                                         sourcePaths: Array(selectedFiles), folder: workspaceManager.graphCreatorFolder)
        isPresented = false
    }
}
