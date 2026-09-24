import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var searchText = ""
    @State private var currentDirectory: URL?
    /// Bumped after this view creates something, so the list (read from disk) redraws.
    @State private var listVersion = 0
    /// Folder a drag is currently over (highlighted as the drop target).
    @State private var dropTarget: URL?

    private var _theme: Int { workspaceManager.themeVersion }
    private var git: GitClient { workspaceManager.gitClient }

    /// The directory we're currently browsing (defaults to workspace root)
    private var browseURL: URL? {
        currentDirectory ?? workspaceManager.rootNode?.url
    }

    /// List files and folders in the current directory
    private var directoryContents: [(url: URL, isDir: Bool, modDate: Date?)] {
        _ = listVersion
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
            guard isDir || FileType.isSupported(itemURL) else { return nil }
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
                .overlay(alignment: .trailing) {
                    HStack(spacing: 0) {
                    Button(action: { workspaceManager.openArchitecture() }) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(VSDark.textDim)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(VSDark.bgActive)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open X-Ray (⌘4)")
                    Button(action: { workspaceManager.closeFolder() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(VSDark.textDim)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(VSDark.bgActive)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close Folder")
                    }
                }
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
                if let here = browseURL {
                    // Create in the folder being browsed.
                    Button { createNewFile(in: here) } label: {
                        Image(systemName: "doc.badge.plus").font(.system(size: 11)).foregroundColor(VSDark.textDim)
                    }
                    .buttonStyle(.plain)
                    .help("New file here")
                    Button { createNewFolder(in: here) } label: {
                        Image(systemName: "folder.badge.plus").font(.system(size: 11)).foregroundColor(VSDark.textDim)
                    }
                    .buttonStyle(.plain)
                    .help("New folder here")
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
                    .background(dropTarget == current.deletingLastPathComponent() ? VSDark.blue.opacity(0.25) : VSDark.bgSidebar)
                    .onDrop(of: [.fileURL], isTargeted: dropBinding(current.deletingLastPathComponent())) { providers in
                        drop(providers, into: current.deletingLastPathComponent())
                    }
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
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard let here = browseURL else { return false }
                    return drop(providers, into: here)
                }
                // Right-click on empty space: create in the folder being browsed.
                .contextMenu {
                    if let here = browseURL {
                        Button("New File...") { createNewFile(in: here) }
                        Button("New Folder...") { createNewFolder(in: here) }
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
                    Button("Open Folder...", action: chooseFolder)
                    .font(.system(size: 11))
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
        .onChange(of: workspaceManager.rootNode?.url) { _ in
            // Browsing state belongs to the previous folder.
            currentDirectory = nil
            searchText = ""
        }
    }

    /// Pick a folder for this window. Local panel rather than the global
    /// `.showFolderPicker` notification, which every open window would answer.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to open in MarkView"
        if panel.runModal() == .OK, let url = panel.url {
            workspaceManager.openFolder(url)
        }
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
        .onDrag { dragItem(url) }
        .background(dropTarget == url ? VSDark.blue.opacity(0.25) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: dropBinding(url)) { providers in drop(providers, into: url) }
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
            Button { workspaceManager.openXRay(for: url) } label: { Label("X-Ray", systemImage: "viewfinder") }
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
        .onDrag { dragItem(url) }
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
            Button { workspaceManager.openXRay(for: url) } label: { Label("X-Ray", systemImage: "viewfinder") }
            Divider()
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
        case .canvas: return ("rectangle.3.group", VSDark.yellow)
        case .markdown: return ("doc.text", VSDark.blue)
        case .code: return ("curlybraces.square", VSDark.cyan)
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
            guard isValidName(name) else { return showError("“\(name)” is not a valid file name.") }
            let fileURL = folderURL.appendingPathComponent(name)
            // Never replace an existing file.
            guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                return showError("“\(name)” already exists in this folder.")
            }
            let template = name.hasSuffix(".md") ? "# \(name.replacingOccurrences(of: ".md", with: ""))\n\n" : ""
            do {
                try template.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                return showError("Couldn't create “\(name)”: \(error.localizedDescription)")
            }
            listVersion += 1
            workspaceManager.refreshFileTree()
            workspaceManager.openFile(fileURL)
        }
    }

    // MARK: - Drag and drop

    /// A dragged tree item: the file URL (moving within the tree, other apps) plus its
    /// path as text, as dragging it into the editor always provided.
    private func dragItem(_ url: URL) -> NSItemProvider {
        let item = NSItemProvider(object: url as NSURL)
        item.registerObject(url.path as NSString, visibility: .all)
        return item
    }

    private func dropBinding(_ url: URL) -> Binding<Bool> {
        Binding(get: { dropTarget == url }, set: { dropTarget = $0 ? url : (dropTarget == url ? nil : dropTarget) })
    }

    /// Files dropped on a folder: moved when they come from this project (⌥ Option copies,
    /// as in Finder), copied when they come from elsewhere (e.g. Finder).
    private func drop(_ providers: [NSItemProvider], into folder: URL) -> Bool {
        let copyRequested = NSEvent.modifierFlags.contains(.option)
        let root = workspaceManager.rootNode?.url.standardizedFileURL.path ?? ""
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url, url.isFileURL { urls.append(url) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            let inside = urls.allSatisfy { !root.isEmpty && $0.standardizedFileURL.path.hasPrefix(root + "/") }
            let errors = workspaceManager.transfer(urls, into: folder, copy: copyRequested || !inside)
            listVersion += 1
            dropTarget = nil
            if !errors.isEmpty { showError(errors.joined(separator: "\n")) }
        }
        return true
    }

    /// One path component: no slashes, not "." or "..".
    private func isValidName(_ name: String) -> Bool {
        !name.contains("/") && !name.contains(":") && name != "." && name != ".."
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
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
            guard isValidName(name) else { return showError("“\(name)” is not a valid folder name.") }
            let folderURL = parentURL.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: folderURL.path) else {
                return showError("“\(name)” already exists in this folder.")
            }
            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
            } catch {
                return showError("Couldn't create “\(name)”: \(error.localizedDescription)")
            }
            listVersion += 1
            workspaceManager.refreshFileTree()
        }
    }
}

#Preview {
    FileTreeView().environmentObject(WorkspaceManager())
}
