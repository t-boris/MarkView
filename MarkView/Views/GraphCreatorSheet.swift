import SwiftUI

/// Sheet for creating a new graph diagram from selected source documents
struct GraphCreatorSheet: View {
    let workspaceManager: WorkspaceManager
    @Binding var isPresented: Bool
    var preselectedType: String = "architecture"

    @State private var selectedFiles: Set<String> = []
    @State private var diagramType = "architecture"
    @State private var customPrompt = ""

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
                    .uiFont(size: 16).foregroundColor(VSDark.blue)
                Text("New Graph Diagram").uiFont(.title3, weight: .bold).foregroundColor(VSDark.text)
                Spacer()
            }

            // Source documents
            GroupBox("Source Documents") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(selectedFiles.count) selected").uiFont(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Current") { selectCurrentFile() }.uiFont(.caption)
                        Button("All") { selectAll() }.uiFont(.caption)
                        Button("None") { selectedFiles.removeAll() }.uiFont(.caption)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(availableFiles(), id: \.self) { file in
                                HStack(spacing: 6) {
                                    Image(systemName: selectedFiles.contains(file) ? "checkmark.square.fill" : "square")
                                        .uiFont(size: 11)
                                        .foregroundColor(selectedFiles.contains(file) ? VSDark.blue : .secondary)
                                    Text(file).uiFont(size: 11).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selectedFiles.contains(file) { selectedFiles.remove(file) }
                                    else { selectedFiles.insert(file) }
                                }
                            }
                        }
                    }.frame(maxHeight: 150)
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
                    TextEditor(text: $customPrompt)
                        .uiFont(size: 12)
                        .frame(minHeight: 60)
                        .padding(4)
                }
            }

            // Buttons
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Text(selectedFiles.isEmpty ? "No documents: the assistant works from the code" : "")
                    .uiFont(.caption).foregroundColor(.secondary)
                Button("Generate") { generate() }
                    .buttonStyle(.borderedProminent)
                    .tint(VSDark.blue)
            }
        }
        .padding(20)
        .frame(width: 500, height: 550)
        .onAppear {
            diagramType = preselectedType
            // Pre-select current file if one is open
            let wm = workspaceManager
            if wm.activeTabIndex >= 0, wm.activeTabIndex < wm.openTabs.count {
                let currentFile = wm.openTabs[wm.activeTabIndex].url.lastPathComponent
                // Only the open document by default: many documents blur the diagram's question.
                selectedFiles = Set(availableFiles().filter { $0.hasSuffix(currentFile) })
            }
        }
    }

    // MARK: - Helpers

    private func availableFiles() -> [String] {
        guard let root = workspaceManager.rootNode?.url else { return [] }
        let fm = FileManager.default
        var files: [String] = []
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension.lowercased() == "md" {
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                files.append(relative)
            }
        }
        return files.sorted()
    }

    private func selectAll() {
        selectedFiles = Set(availableFiles())
    }

    private func selectCurrentFile() {
        let wm = workspaceManager
        guard wm.activeTabIndex >= 0, wm.activeTabIndex < wm.openTabs.count else { return }
        let currentFile = wm.openTabs[wm.activeTabIndex].url
        guard let root = wm.rootNode?.url else { return }
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
