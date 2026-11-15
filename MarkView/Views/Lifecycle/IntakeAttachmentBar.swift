import SwiftUI
import AppKit

/// The row under a request box that takes material for the assistant: files from anywhere, files of the project, and the chips of what
/// is attached. Pasting an image (⌘V) and dropping files go through the box itself (`IntakeTextEditor`) and land in the same list.
/// Every box that sends text to the assistant with material uses it: New Feature / Bug / Research, New Project, New scenario.
struct IntakeAttachmentBar: View {
    @Environment(\.palette) private var palette
    @Binding var attachments: [URL]
    /// The project folder; "From Project…" is offered only with one.
    let projectRoot: URL?
    var hint = "or paste images with ⌘V"
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Add Files…") { chooseFiles() }
                if let projectRoot {
                    Button("From Project…") { picking = true }
                        .help("Attach files of this project: type part of a name")
                        .popover(isPresented: $picking, arrowEdge: .bottom) {
                            ProjectFilePicker(root: projectRoot, attachments: $attachments)
                        }
                }
                Text(hint).uiFont(.caption).foregroundColor(palette.textDim)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { url in
                            HStack(spacing: 2) {
                                IntakeAttachmentThumbnail(url: url)
                                Text(url.lastPathComponent).uiFont(.caption).lineLimit(1)
                                Button(action: { attachments.removeAll { $0 == url } }) { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundColor(palette.textDim)
                            }
                            .padding(.horizontal, 5).padding(.vertical, 2).background(palette.bgInput).cornerRadius(4)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = projectRoot
        guard panel.runModal() == .OK else { return }
        attachments += panel.urls.filter { !attachments.contains($0) }
    }
}

/// Files of the project by name: a private index of the project (the search panel's), searched as the person types.
struct ProjectFilePicker: View {
    @Environment(\.palette) private var palette
    let root: URL
    @Binding var attachments: [URL]
    @State private var index = ProjectSearchIndex()
    @State private var query = ""
    @State private var ready = false
    @State private var paths: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search project files by name", text: $query).textFieldStyle(.roundedBorder)
            if !ready {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the project…").uiFont(.caption).foregroundColor(palette.textDim)
                }
            } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Type part of a file name or folder.").uiFont(.caption).foregroundColor(palette.textDim)
            } else if paths.isEmpty {
                Text("No file of the project has that in its path.").uiFont(.caption).foregroundColor(palette.textDim)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(paths, id: \.self) { path in
                        let url = root.appendingPathComponent(path)
                        let attached = attachments.contains(url)
                        Button {
                            if attached { attachments.removeAll { $0 == url } } else { attachments.append(url) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: attached ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(attached ? palette.blue : palette.textDim)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(url.lastPathComponent).uiFont(size: 11.5).lineLimit(1)
                                    Text(path).uiFont(.caption2).foregroundColor(palette.textDim).lineLimit(1).truncationMode(.head)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 400, height: 320)
        .task {
            try? await index.rebuild(root: root) { _ in }
            ready = true
        }
        .task(id: query + (ready ? "\u{1}" : "")) {
            guard ready else { return }
            let found = await index.search(query)
            // Files only, and not the entries inside archives: an archive is attached as the file it is.
            paths = found.filter { $0.scope == .file }.compactMap(\.path).filter { !$0.contains(ProjectSearchIndex.archiveSeparator) }
        }
    }
}
