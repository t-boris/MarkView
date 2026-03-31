import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var searchText = ""
    @State private var commitMessage = ""

    private var _theme: Int { workspaceManager.themeVersion }
    private var git: GitClient { workspaceManager.gitClient }

    var body: some View {
        let _ = _theme
        VStack(spacing: 0) {
            // Git bar (if git repo)
            if git.isGitRepo {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9)).foregroundColor(VSDark.blue)
                    Text(git.branch).font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.text)
                    Spacer()
                    if git.isOperating { ProgressView().scaleEffect(0.3) }
                    Button(action: { Task { await git.pull() } }) {
                        Image(systemName: "arrow.down").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                    }.buttonStyle(.plain).help("Pull")
                    Button(action: { Task { await git.push() } }) {
                        Image(systemName: "arrow.up").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                    }.buttonStyle(.plain).help("Push")
                    Button(action: { Task { await git.refresh() } }) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                    }.buttonStyle(.plain).help("Refresh")
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(VSDark.bgActive)
            }

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(VSDark.textDim)
                TextField("Filter files...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(VSDark.text)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(VSDark.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(VSDark.bgSidebar)

            Divider().background(VSDark.border)

            if let root = workspaceManager.rootNode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        FileNodeView(node: root, level: 0, searchText: searchText)
                    }
                }
                .background(VSDark.bgSidebar)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28))
                        .foregroundColor(VSDark.textDim)
                    Text("No Folder Open")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(VSDark.textDim)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VSDark.bgSidebar)
            }
        }
        .background(VSDark.bgSidebar)
    }
}

struct FileNodeView: View {
    @ObservedObject var node: FileNode
    let level: Int
    let searchText: String
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var shouldShow: Bool {
        if searchText.isEmpty { return true }
        return node.name.lowercased().contains(searchText.lowercased()) ||
            (node.children?.contains { shouldShowNode($0) } ?? false)
    }

    private func shouldShowNode(_ node: FileNode) -> Bool {
        if searchText.isEmpty { return true }
        return node.name.lowercased().contains(searchText.lowercased()) ||
            (node.children?.contains { shouldShowNode($0) } ?? false)
    }

    var body: some View {
        if !shouldShow { return AnyView(EmptyView()) }

        if node.isDirectory {
            return AnyView(
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { node.isExpanded },
                        set: { node.isExpanded = $0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let children = node.children {
                            ForEach(children, id: \.self) { child in
                                FileNodeView(node: child, level: level + 1, searchText: searchText)
                            }
                        }
                    }
                    .padding(.leading, 12)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundColor(VSDark.yellow)
                        Text(node.name)
                            .font(.system(size: 12))
                            .foregroundColor(VSDark.text)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        node.isExpanded.toggle()
                        if node.children == nil || node.children?.isEmpty == true {
                            node.loadChildren()
                        }
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .contextMenu {
                    if workspaceManager.isExcluded(node.url) {
                        Button("Include Folder") {
                            if let root = workspaceManager.rootNode?.url {
                                let rel = node.url.path.replacingOccurrences(of: root.path + "/", with: "")
                                workspaceManager.includeFolder(rel)
                            }
                        }
                    } else {
                        Button("Exclude Folder") {
                            workspaceManager.excludeFolder(node.url)
                        }
                    }
                    Divider()
                    Button("New File...") { createNewFile(in: node.url) }
                    Button("New Folder...") { createNewFolder(in: node.url) }
                    if workspaceManager.gitClient.isGitRepo {
                        Divider()
                        Button("Stage All in Folder") { stageAllInFolder(node.url) }
                        Button("Commit...") { promptCommit() }
                        Button("Push") { Task { await workspaceManager.gitClient.push() } }
                    }
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(node.url.path, inFileViewerRootedAtPath: "") }
                    Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(node.url.path, forType: .string) }
                }
                .opacity(workspaceManager.isExcluded(node.url) ? 0.4 : 1.0)
            )
        } else if node.isMarkdown {
            let gitStatus = fileGitStatus(node.url)
            return AnyView(
                HStack(spacing: 4) {
                    Image(systemName: "doc.text").font(.system(size: 11)).foregroundColor(VSDark.blue).frame(width: 16)
                    Text(node.name).font(.system(size: 12)).foregroundColor(VSDark.text).lineLimit(1)
                    Spacer()
                    // Git status indicator
                    if let gs = gitStatus {
                        Text(gs.status)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(gs.status == "M" ? VSDark.orange : gs.status == "?" ? VSDark.green : VSDark.red)
                            .frame(width: 12)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { workspaceManager.openFile(node.url) }
                .onDrag { NSItemProvider(object: node.url.path as NSString) }
                .contextMenu {
                    if let gs = gitStatus {
                        if gs.isStaged {
                            Button("Unstage") { workspaceManager.gitClient.unstageFile(gs.file) }
                        } else {
                            Button("Stage") { workspaceManager.gitClient.stageFile(gs.file) }
                        }
                        Button("Discard Changes") { workspaceManager.gitClient.discardChanges(gs.file) }
                        Divider()
                    }
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(node.url.path, inFileViewerRootedAtPath: "") }
                    Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(node.url.path, forType: .string) }
                }
            )
        } else {
            return AnyView(EmptyView())
        }
    }

    private func fileGitStatus(_ url: URL) -> GitClient.GitFileStatus? {
        let git = workspaceManager.gitClient
        guard let root = git.workingDirectory else { return nil }
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        return git.changedFiles.first(where: { $0.file == relative })
    }

    private func stageAllInFolder(_ url: URL) {
        let git = workspaceManager.gitClient
        guard let root = git.workingDirectory else { return }
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        for file in git.changedFiles where file.file.hasPrefix(relative) {
            git.stageFile(file.file)
        }
    }

    private func promptCommit() {
        let alert = NSAlert()
        alert.messageText = "Commit"
        alert.informativeText = "Enter commit message:"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "Commit message..."
        alert.accessoryView = input
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Commit & Push")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        let message = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else { return }

        Task {
            if response == .alertFirstButtonReturn {
                _ = await workspaceManager.gitClient.commit(message: message)
            } else if response == .alertSecondButtonReturn {
                if await workspaceManager.gitClient.commit(message: message) {
                    _ = await workspaceManager.gitClient.push()
                }
            }
        }
    }

    private func createNewFile(in folderURL: URL) {
        let alert = NSAlert()
        alert.messageText = "New Markdown File"
        alert.informativeText = "Enter filename:"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = "untitled.md"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            var name = input.stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "untitled.md" }
            if !name.hasSuffix(".md") { name += ".md" }
            let fileURL = folderURL.appendingPathComponent(name)
            let template = "# \(name.replacingOccurrences(of: ".md", with: ""))\n\n"
            try? template.write(to: fileURL, atomically: true, encoding: .utf8)
            // Reload tree and open file
            if let root = workspaceManager.rootNode?.url {
                workspaceManager.rootNode = FileNode.buildTree(from: root)
            }
            workspaceManager.openFile(fileURL)
        }
    }

    private func createNewFolder(in parentURL: URL) {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Enter folder name:"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = "New Folder"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let folderURL = parentURL.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            if let root = workspaceManager.rootNode?.url {
                workspaceManager.rootNode = FileNode.buildTree(from: root)
            }
        }
    }
}

#Preview {
    FileTreeView().environmentObject(WorkspaceManager())
}
