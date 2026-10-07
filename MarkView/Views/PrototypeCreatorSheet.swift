import AppKit
import SwiftUI

/// Starts Prototype Studio: choose the requirement sources (files or folders of the project), say what to
/// build, and open the studio tab. Earlier prototypes of the project are listed to reopen.
struct PrototypeCreatorSheet: View {
    @ObservedObject var workspaceManager: WorkspaceManager
    @Binding var isPresented: Bool

    @State private var sources: [String] = []
    @State private var title = ""
    @State private var brief = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "rectangle.on.rectangle.angled").uiFont(size: 16).foregroundColor(VSDark.blue)
                Text("New Prototype").uiFont(.title3, weight: .bold).foregroundColor(VSDark.text)
                Spacer()
            }
            Text("An agent reads the requirements and builds a clickable HTML prototype. You then review it in the studio — point at things, ask for changes — until you approve it and export the package for implementation.")
                .uiFont(size: 11).foregroundColor(VSDark.textDim)

            GroupBox("Requirements") {
                VStack(alignment: .leading, spacing: 6) {
                    if sources.isEmpty {
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
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }

            GroupBox("What should the prototype show?") {
                TextEditor(text: $brief)
                    .uiFont(size: 12).frame(height: 90).scrollContentBackground(.hidden)
                    .padding(2)
            }
            Text("Optional: the audience, the flows that matter most, what to leave out.")
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
                    workspaceManager.newPrototype(title: title.isEmpty ? defaultTitle : title, brief: brief, sources: sources)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { if sources.isEmpty, let current = currentFile { sources = [current] } }
    }

    private var root: URL? { workspaceManager.rootNode?.url.standardizedFileURL }

    /// The active tab's file, relative to the project, when it is a real file inside it.
    private var currentFile: String? {
        guard let root, let tab = workspaceManager.activeTab, case .file = tab.kind else { return nil }
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
