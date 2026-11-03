import AppKit
import SwiftUI

/// Starts Prototype Studio: choose the sources (files or folders of the project), say what to build, and
/// open the studio tab. In `.requirements` mode the sources are requirement documents; in `.code` mode
/// (Previews from Existing Code, DEC-004) they are the existing web-interface code the agent reconstructs,
/// and the sheet refuses to start when no web interface is detected in the chosen scope (DEC-003).
/// Earlier prototypes of the project are listed to reopen.
struct PrototypeCreatorSheet: View {
    @ObservedObject var workspaceManager: WorkspaceManager
    @Binding var isPresented: Bool
    var mode: PrototypeFiles.Mode = .requirements

    @State private var sources: [String] = []
    @State private var title = ""
    @State private var brief = ""
    /// Code mode: the web apps detected inside the selected scope; nil while detection runs.
    @State private var detected: [PrototypeAI.CodeScope.App]?

    private var isCode: Bool { mode == .code }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "rectangle.on.rectangle.angled").uiFont(size: 16).foregroundColor(VSDark.blue)
                Text(isCode ? "New Prototype from Code" : "New Prototype").uiFont(.title3, weight: .bold).foregroundColor(VSDark.text)
                Spacer()
            }
            Text(intro).uiFont(size: 11).foregroundColor(VSDark.textDim)

            GroupBox(isCode ? "Existing code" : "Requirements") {
                VStack(alignment: .leading, spacing: 6) {
                    if isCode {
                        Text("The agent reproduces the interface found in these files; nothing selected means the whole project.")
                            .uiFont(size: 11).foregroundColor(VSDark.textDim)
                    } else if sources.isEmpty {
                        Text("Nothing chosen: the agent reads the whole project.").uiFont(size: 11).foregroundColor(VSDark.textDim)
                    }
                    ForEach(sources, id: \.self) { path in
                        HStack {
                            Image(systemName: "doc.text").foregroundColor(VSDark.textDim)
                            Text(path).uiFont(size: 11).lineLimit(1)
                            Spacer()
                            Button { sources.removeAll { $0 == path } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundColor(VSDark.textDim)
                        }
                    }
                    HStack {
                        Button("Add file or folder…") { chooseSources() }
                        if let current = currentFile, !sources.contains(current) {
                            Button("Add current file") { sources.append(current) }
                        }
                    }
                    .controlSize(.small)
                    if isCode { detection }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }

            GroupBox(isCode ? "What should the preview focus on?" : "What should the prototype show?") {
                TextEditor(text: $brief)
                    .uiFont(size: 12).frame(height: 90).scrollContentBackground(.hidden)
                    .padding(2)
            }
            Text(isCode ? "Optional: the screens or flows that matter most, what to leave out."
                        : "Optional: the audience, the flows that matter most, what to leave out.")
                .uiFont(size: 10).foregroundColor(VSDark.textDim)

            TextField("Name (optional)", text: $title).textFieldStyle(.roundedBorder)

            let saved = workspaceManager.savedPrototypes()
            if !saved.isEmpty {
                GroupBox("Open an earlier prototype") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(saved) { prototype in
                                Button(prototype.label) {
                                    isPresented = false
                                    workspaceManager.openSavedPrototype(prototype.slug)
                                }
                                .buttonStyle(.link)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 70)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Build Prototype") {
                    isPresented = false
                    workspaceManager.newPrototype(title: title.isEmpty ? defaultTitle : title, brief: brief, sources: sources,
                                                  mode: mode, codeScope: PrototypeAI.CodeScope(apps: detected ?? []))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCode && (detected?.isEmpty ?? true))
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            // The open file is a natural first source; in code mode only when it is a web-interface file.
            guard sources.isEmpty, let current = currentFile else { return }
            if !isCode || PrototypeFiles.isInventoryFile((current as NSString).lastPathComponent) { sources = [current] }
        }
        .task(id: sources) { await detect() }
    }

    private var intro: String {
        if isCode {
            return "An agent reads the existing code and rebuilds its web interface as a standalone clickable HTML prototype with simulated data. You then review it in the studio — point at things, ask for changes — until you approve it and export the package for implementation. What the reconstruction cannot reproduce is listed as known gaps."
        }
        return "An agent reads the requirements and builds a clickable HTML prototype. You then review it in the studio — point at things, ask for changes — until you approve it and export the package for implementation."
    }

    /// Code mode: what Preview Web App discovery found inside the selected scope (DEC-003).
    @ViewBuilder
    private var detection: some View {
        if let detected {
            if detected.isEmpty {
                Label("No web interface detected in the selected files. Select a folder that contains a web application or an Electron renderer.",
                      systemImage: "exclamationmark.triangle")
                    .uiFont(size: 11).foregroundColor(VSDark.yellow)
            } else {
                ForEach(detected, id: \.path) { app in
                    Label("Detected: \(app.label)\(app.isElectron ? " (Electron renderer)" : "")", systemImage: "checkmark.circle")
                        .uiFont(size: 11).foregroundColor(VSDark.green)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking for web interfaces…").uiFont(size: 11).foregroundColor(VSDark.textDim)
            }
        }
    }

    /// Runs the web-app discovery off the main thread and keeps the apps inside the selected scope (the same
    /// `CodeScope.detect` that "Sync from code" runs later, so both see the same hints).
    private func detect() async {
        guard isCode, let root else { return }
        let sources = self.sources
        let scope = await Task.detached { PrototypeAI.CodeScope.detect(root: root, sources: sources) }.value
        guard !Task.isCancelled else { return }
        detected = scope.apps
    }

    private var root: URL? { workspaceManager.rootNode?.url.standardizedFileURL }

    /// The active tab's file, relative to the project, when it is a real file inside it.
    private var currentFile: String? {
        guard root != nil, let tab = workspaceManager.activeTab, case .file = tab.kind else { return nil }
        return relative(tab.url)
    }

    private var defaultTitle: String {
        if let first = sources.first { return ((first as NSString).lastPathComponent as NSString).deletingPathExtension }
        return root?.lastPathComponent ?? "Prototype"
    }

    private func relative(_ url: URL) -> String? {
        guard let root else { return nil }
        let path = url.standardizedFileURL.path, base = root.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

    private func chooseSources() {
        guard let root else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = root
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let path = relative(url), !sources.contains(path) { sources.append(path) }
        }
    }
}
