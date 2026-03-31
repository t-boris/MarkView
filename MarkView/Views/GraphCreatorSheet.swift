import SwiftUI

/// Sheet for creating a new graph diagram from selected source documents
struct GraphCreatorSheet: View {
    let workspaceManager: WorkspaceManager
    @Binding var isPresented: Bool
    var preselectedType: String = "architecture"

    @State private var selectedFiles: Set<String> = []
    @State private var diagramType = "architecture"
    @State private var customPrompt = ""
    @State private var isGenerating = false
    @State private var error: String?

    private let diagramTypes = [
        ("architecture", "System Architecture", "C4 component diagram showing all systems, services, databases and their connections"),
        ("pipeline", "Data Pipeline", "Data flow diagram showing how data moves through processing stages"),
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
                    .font(.system(size: 16)).foregroundColor(VSDark.blue)
                Text("New Graph Diagram").font(.title3.bold()).foregroundColor(VSDark.text)
                Spacer()
            }

            // Source documents
            GroupBox("Source Documents") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(selectedFiles.count) selected").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Current") { selectCurrentFile() }.font(.caption)
                        Button("All") { selectAll() }.font(.caption)
                        Button("None") { selectedFiles.removeAll() }.font(.caption)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(availableFiles(), id: \.self) { file in
                                HStack(spacing: 6) {
                                    Image(systemName: selectedFiles.contains(file) ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 11))
                                        .foregroundColor(selectedFiles.contains(file) ? VSDark.blue : .secondary)
                                    Text(file).font(.system(size: 11)).lineLimit(1)
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
                        .font(.system(size: 12))
                        .frame(minHeight: 60)
                        .padding(4)
                }
            }

            // Error
            if let error = error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            // Buttons
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                if isGenerating {
                    ProgressView().scaleEffect(0.6)
                    Text("Generating...").font(.caption).foregroundColor(.secondary)
                } else {
                    Button("Generate") { generate() }
                        .buttonStyle(.borderedProminent)
                        .tint(VSDark.blue)
                        .disabled(selectedFiles.isEmpty)
                }
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
                if availableFiles().contains(where: { $0.hasSuffix(currentFile) }) {
                    selectedFiles = Set(availableFiles().filter { $0.hasSuffix(currentFile) })
                } else {
                    selectAll()
                }
            } else {
                selectAll()
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
        guard !selectedFiles.isEmpty else { return }
        guard let root = workspaceManager.rootNode?.url else { return }
        guard let engine = workspaceManager.aiConsoleEngine else {
            error = "AI engine not initialized"
            return
        }

        isGenerating = true
        error = nil

        // Build content from selected files
        var content = ""
        for file in selectedFiles.sorted() {
            let url = root.appendingPathComponent(file)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                content += "--- \(file) ---\n\(String(text.prefix(3000)))\n\n"
            }
        }

        // Get diagram type description
        let typeDesc = diagramTypes.first(where: { $0.0 == diagramType })?.2 ?? "architecture diagram"
        let promptExtra = diagramType == "custom" ? customPrompt : ""

        let prompt = """
        Based on the following documentation, create a Mermaid diagram.

        Diagram type: \(typeDesc)
        \(promptExtra.isEmpty ? "" : "Additional instructions: \(promptExtra)")

        RULES:
        1. Create a markdown file called "graph-\(diagramType).md" in the current directory.
        2. Include a ```mermaid code block. The FIRST LINE inside the mermaid block MUST be: %%INTERACTIVE
        3. Node IDs: alphanumeric + underscore only. Labels in square brackets [].
        4. DO NOT limit nodes — include ALL components, services, entities from the source.
        5. Use subgraph blocks to organize by layers, domains, or logical groups.
        6. Show INTERNAL vs EXTERNAL systems in different subgraphs.
        7. Use classDef for color-coding by type.
        8. Add a brief description before the diagram and a legend after.

        Source documents (\(selectedFiles.count) files):
        \(String(content.prefix(15000)))
        """

        // Send to Claude Code
        engine.sendMessage(prompt)

        // Close sheet — results will appear in AI tab
        isPresented = false
        isGenerating = false

        // Switch to AI tab to see progress
        workspaceManager.showTOC = true
        workspaceManager.showSemanticPanel = true
    }
}
