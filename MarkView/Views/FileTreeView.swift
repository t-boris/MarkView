import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var searchText = ""
    @State private var currentDirectory: URL?

    private var _theme: Int { workspaceManager.themeVersion }
    private var git: GitClient { workspaceManager.gitClient }

    /// The directory we're currently browsing (defaults to workspace root)
    private var browseURL: URL? {
        currentDirectory ?? workspaceManager.rootNode?.url
    }

    /// List files and folders in the current directory
    private var directoryContents: [(url: URL, isDir: Bool, modDate: Date?)] {
        guard let dir = browseURL else { return [] }
        let fm = FileManager.default
        let sort = workspaceManager.fileTreeSortOrder
        let needsDate = sort.field == .dateModified
        let keys: [URLResourceKey] = needsDate
            ? [.isDirectoryKey, .contentModificationDateKey]
            : [.isDirectoryKey]

        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return [] }

        let items: [(url: URL, isDir: Bool, modDate: Date?)] = contents.compactMap { itemURL in
            let name = itemURL.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            let vals = try? itemURL.resourceValues(forKeys: Set(keys))
            let isDir = vals?.isDirectory ?? false
            let ext = itemURL.pathExtension.lowercased()
            guard isDir || FileType.supportedExtensions.contains(ext) else { return nil }
            return (itemURL, isDir, vals?.contentModificationDate)
        }

        let asc = sort.ascending
        return items.sorted { a, b in
            if a.isDir && !b.isDir { return true }
            if !a.isDir && b.isDir { return false }
            switch sort.field {
            case .name:
                let cmp = a.url.lastPathComponent.lowercased() < b.url.lastPathComponent.lowercased()
                return asc ? cmp : !cmp
            case .dateModified:
                let da = a.modDate ?? .distantPast
                let db = b.modDate ?? .distantPast
                let cmp = da < db
                return asc ? cmp : !cmp
            }
        }
    }

    /// Filtered contents based on search
    private var filteredContents: [(url: URL, isDir: Bool, modDate: Date?)] {
        if searchText.isEmpty { return directoryContents }
        let q = searchText.lowercased()
        return directoryContents.filter { $0.url.lastPathComponent.lowercased().contains(q) }
    }

    /// Breadcrumb path components from root to current directory
    private var breadcrumbs: [URL] {
        guard let root = workspaceManager.rootNode?.url,
              let current = browseURL else { return [] }
        var crumbs: [URL] = []
        var url = current
        while url.path.hasPrefix(root.path) {
            crumbs.insert(url, at: 0)
            if url.path == root.path { break }
            url = url.deletingLastPathComponent()
        }
        return crumbs
    }

    var body: some View {
        let _ = _theme
        VStack(spacing: 0) {
            // Git bar
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

            // Breadcrumb navigation
            if browseURL != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(breadcrumbs, id: \.path) { crumb in
                            if crumb != breadcrumbs.first {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7, weight: .semibold))
                                    .foregroundColor(VSDark.textDim)
                            }
                            Button(action: { currentDirectory = crumb }) {
                                Text(crumb.lastPathComponent)
                                    .font(.system(size: 10, weight: crumb == browseURL ? .semibold : .regular))
                                    .foregroundColor(crumb == browseURL ? VSDark.text : VSDark.blue)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.vertical, 4)
                .background(VSDark.bgActive)
            }

            // Toolbar: search + actions
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(VSDark.textDim)
                TextField("Filter...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(VSDark.text)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(VSDark.textDim)
                    }.buttonStyle(.plain)
                }
                if browseURL != nil {
                    // Sort toggle button
                    Button {
                        var s = workspaceManager.fileTreeSortOrder
                        if s.field == .name && s.ascending { s.ascending = false }
                        else if s.field == .name && !s.ascending { s.field = .dateModified; s.ascending = false }
                        else if s.field == .dateModified && !s.ascending { s.ascending = true }
                        else { s.field = .name; s.ascending = true }
                        workspaceManager.fileTreeSortOrder = s
                    } label: {
                        HStack(spacing: 1) {
                            Image(systemName: workspaceManager.fileTreeSortOrder.ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                            Text(workspaceManager.fileTreeSortOrder.field == .name ? "Az" : "Dt")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(VSDark.textDim)
                    }
                    .buttonStyle(.plain)
                    .help("Sort: \(workspaceManager.fileTreeSortOrder.field.rawValue)")
                }
            }
            .padding(8)
            .background(VSDark.bgSidebar)

            Divider().background(VSDark.border)

            // File list
            if browseURL != nil {
                // Back button (if not at root)
                if let root = workspaceManager.rootNode?.url,
                   let current = browseURL,
                   current.path != root.path {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(VSDark.blue)
                        Text("..")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(VSDark.blue)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        currentDirectory = current.deletingLastPathComponent()
                    }
                    .background(VSDark.bgSidebar)
                    Divider().background(VSDark.border).opacity(0.5)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredContents, id: \.url) { item in
                            if item.isDir {
                                folderRow(item.url)
                            } else {
                                fileRow(item.url)
                            }
                        }
                    }
                }
                .background(VSDark.bgSidebar)
            } else if workspaceManager.indexingProgress != nil {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView().scaleEffect(0.8)
                    Text(workspaceManager.indexingProgress ?? "")
                        .font(.system(size: 11)).foregroundColor(VSDark.blue)
                        .lineLimit(2).multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VSDark.bgSidebar)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28)).foregroundColor(VSDark.textDim)
                    Text("No Folder Open")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(VSDark.textDim)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VSDark.bgSidebar)
            }

            // Progress bar
            if let progress = workspaceManager.indexingProgress {
                Divider().background(VSDark.border)
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
                    Text(progress).font(.system(size: 10)).foregroundColor(VSDark.blue).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(VSDark.bgActive)
            }
        }
        .background(VSDark.bgSidebar)
    }

    // MARK: - Row Views

    private func folderRow(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(VSDark.yellow)
            Text(url.lastPathComponent)
                .font(.system(size: 12))
                .foregroundColor(VSDark.text)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundColor(VSDark.textDim)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { currentDirectory = url }
        .opacity(workspaceManager.isExcluded(url) ? 0.4 : 1.0)
        .contextMenu {
            if workspaceManager.isExcluded(url) {
                Button("Include Folder") {
                    if let root = workspaceManager.rootNode?.url {
                        let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                        workspaceManager.includeFolder(rel)
                    }
                }
            } else {
                Button("Exclude Folder") { workspaceManager.excludeFolder(url) }
            }
            Divider()
            Button("New File...") { createNewFile(in: url) }
            Button("New Folder...") { createNewFolder(in: url) }
            if git.isGitRepo {
                Divider()
                Button("Stage All in Folder") { stageAllInFolder(url) }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "") }
            Button("Open in Terminal") { openTerminal(at: url) }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
        }
    }

    private func fileRow(_ url: URL) -> some View {
        let gitStatus = fileGitStatus(url)
        let (icon, color) = fileIcon(for: url)
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(color).frame(width: 16)
            Text(url.lastPathComponent).font(.system(size: 12)).foregroundColor(VSDark.text).lineLimit(1)
            Spacer()
            if let gs = gitStatus {
                Text(gs.status)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(gs.status == "M" ? VSDark.orange : gs.status == "?" ? VSDark.green : VSDark.red)
                    .frame(width: 12)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { workspaceManager.openFile(url) }
        .onDrag { NSItemProvider(object: url.path as NSString) }
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
            Button("Show in Finder") { NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "") }
            Button("Open in Terminal") { openTerminal(at: url.deletingLastPathComponent()) }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
        }
    }

    // MARK: - Helpers

    private func fileIcon(for url: URL) -> (String, Color) {
        switch FileType.from(url: url) {
        case .json: return ("curlybraces", VSDark.green)
        case .xml:  return ("chevron.left.forwardslash.chevron.right", VSDark.orange)
        case .yaml: return ("list.bullet.indent", VSDark.purple)
        case .markdown: return ("doc.text", VSDark.blue)
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

    private func openTerminal(at folderURL: URL) {
        let script = "tell application \"Terminal\"\nactivate\ndo script \"cd \(folderURL.path.replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    private func createNewFile(in folderURL: URL) {
        let alert = NSAlert()
        alert.messageText = "New File"
        alert.informativeText = "Enter filename:"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = "untitled.md"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            var name = input.stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "untitled.md" }
            let fileURL = folderURL.appendingPathComponent(name)
            let template = name.hasSuffix(".md") ? "# \(name.replacingOccurrences(of: ".md", with: ""))\n\n" : ""
            try? template.write(to: fileURL, atomically: true, encoding: .utf8)
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
        }
    }
}

#Preview {
    FileTreeView().environmentObject(WorkspaceManager())
}
