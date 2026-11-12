import SwiftUI

/// Files: the project folder and its linked folders in three views (Icons, List, Tree), with filters and an
/// explicit sort. The rules are in `FileBrowserModel.swift`; this view draws them and keeps the actions
/// (open, create, rename, move, trash, drag and drop, Git, archives).
struct FileTreeView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject var workspaceManager: WorkspaceManager
    /// The view and the filter choices of this window; they persist across restarts with its session (AC-5, DEC-008)
    /// and no other window follows them. The sort order persists in the file tree store.
    @WindowStorage("fileBrowser.viewMode") private var storedMode = FileBrowserViewMode.list
    @WindowStorage("fileBrowser.showHidden") private var storedShowHidden = false
    @WindowStorage("fileBrowser.hideIgnored") private var storedHideIgnored = false
    @WindowStorage("fileBrowser.category") private var storedCategory = FileBrowserCategory.all
    private var preferences: FileBrowserPreferences {
        get { FileBrowserPreferences(mode: storedMode, showHidden: storedShowHidden, hideIgnored: storedHideIgnored, category: storedCategory) }
        nonmutating set {
            storedMode = newValue.mode
            storedShowHidden = newValue.showHidden
            storedHideIgnored = newValue.hideIgnored
            storedCategory = newValue.category
        }
    }
    private var preferencesBinding: Binding<FileBrowserPreferences> {
        Binding(get: { preferences }, set: { preferences = $0 })
    }
    /// The name query: the entries of the browsed folder in Icon and List views, the whole workspace in Tree.
    @State private var searchText = ""
    /// The folder browsed in Icon and List views; nil is the project folder.
    @State private var currentDirectory: URL?
    /// Icon and List views are on the Workspace level, above the project folder and its linked folders (DEC-009).
    @State private var atWorkspace = false
    /// Tree view: the open folders (`FileBrowser.key`); the project folder starts open.
    @State private var expanded = Set<String>()
    /// The project folder the tree was last opened for, so that it is opened once and a collapse sticks.
    @State private var seededRoot: String?
    /// Tree view: the folder New File, dropping on empty space and Move to… start from (the folder last clicked).
    @State private var treeAnchor: URL?
    /// Tree view with a query: what the walk of the disk found, and whether a walk is running.
    @State private var searchResult: FileBrowserSearchResult?
    @State private var isSearching = false
    /// Bumped after this view creates something, so the list (read from disk) redraws.
    @State private var listVersion = 0
    @State private var cachedDirectoryEntries: [FileBrowserEntry] = []
    @State private var cachedTreeRows: [FileBrowserRow] = []
    @State private var cachedSearchRows: [FileBrowserRow] = []
    @State private var listingMonitors: [ProjectChangeMonitor] = []
    @State private var listingRefresh: Task<Void, Never>?
    /// Folder a drag is currently over (highlighted as the drop target).
    @State private var dropTarget: URL?
    /// Row shown by "Reveal in File Tree" (highlighted until the next reveal).
    @State private var revealedURL: URL?
    /// Rows selected with click, ⌘-click and ⇧-click, for actions on several at once.
    @State private var selection = ListSelection<URL>()
    /// The list has keyboard focus: ⌫ moves the selection to the Trash.
    @FocusState private var listFocused: Bool

    private var git: GitClient { workspaceManager.gitClient }
    private var mode: FileBrowserViewMode { preferences.mode }
    private var projectRootURL: URL? { workspaceManager.rootNode?.url }

    // MARK: Model glue

    /// The project folder and the linked folders: the places of the Workspace level.
    private var roots: [FileBrowserRoot] {
        guard let project = projectRootURL else { return [] }
        return [FileBrowserRoot(url: project, name: project.lastPathComponent, linkedID: nil)]
            + workspaceManager.linkedFolders.map { FileBrowserRoot(url: $0.url, name: $0.name, linkedID: $0.id) }
    }

    private var filter: FileBrowserFilter {
        FileBrowserFilter(query: searchText, showHidden: preferences.showHidden,
                          hideIgnored: preferences.hideIgnored && git.isGitRepo, category: preferences.category)
    }

    private var source: FileBrowserSource {
        FileBrowserSource(roots: roots, filter: filter, sort: workspaceManager.fileTreeSortOrder,
                          hasViewer: { FileType.hasViewer($0) }, isIgnored: ignoredLookup)
    }

    /// Git's ignore list for the project (REQ-001). Linked folders have no data of the project's repository.
    private var ignoredLookup: @Sendable (URL, Bool) -> Bool {
        guard git.isGitRepo, let root = git.workingDirectory else { return { _, _ in false } }
        let status = git.repoStatus
        let prefix = root.standardizedFileURL.path + "/"
        let linkedPaths = workspaceManager.linkedFolders.map { $0.url.standardizedFileURL.path }
        return { url, isDirectory in
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix), !linkedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
            return status.decoration(of: String(path.dropFirst(prefix.count)), isDirectory: isDirectory).state == .ignored
        }
    }

    private var sortBinding: Binding<FileTreeSortOrder> {
        Binding(get: { workspaceManager.fileTreeSortOrder }, set: { workspaceManager.fileTreeSortOrder = $0 })
    }

    /// Where Icon and List views are.
    private var location: FileBrowserLocation {
        guard let project = projectRootURL, !atWorkspace else { return .workspace }
        return .folder(currentDirectory ?? project)
    }

    private func go(_ target: FileBrowserLocation) {
        switch target {
        case .workspace:
            atWorkspace = true
            currentDirectory = nil
        case .folder(let url):
            atWorkspace = false
            let isProject = projectRootURL.map { FileBrowser.key($0) == FileBrowser.key(url) } ?? false
            currentDirectory = isProject ? nil : url
        }
    }

    /// The folder that New File here, dropping on empty space and Move to… start from: the folder being
    /// browsed; in Tree view the folder last clicked (the folder of the file last clicked), else the project
    /// folder. nil on the Workspace level, where nothing can be created (DEC-009).
    private var destination: URL? {
        switch mode {
        case .tree:
            // The folder last clicked, unless it was renamed, moved or trashed since.
            if let anchor = treeAnchor, FileManager.default.fileExists(atPath: anchor.path) { return anchor }
            return projectRootURL
        case .icon, .list:
            if case .folder(let url) = location { return url }
            return nil
        }
    }

    /// Disk listings are built once per relevant state change, away from SwiftUI's render pass.
    private var directoryEntries: [FileBrowserEntry] { cachedDirectoryEntries }

    private var isTreeSearch: Bool {
        mode == .tree && !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var treeRows: [FileBrowserRow] {
        if isTreeSearch { return cachedSearchRows }
        return cachedTreeRows
    }

    private var listingKey: String {
        let rootIdentity = workspaceManager.rootNode.map { String(describing: ObjectIdentifier($0)) } ?? ""
        let directory = currentDirectory?.standardizedFileURL.path ?? ""
        let sort = workspaceManager.fileTreeSortOrder
        return [searchKey, rootIdentity, directory, String(atWorkspace), mode.rawValue,
                String(describing: sort.field), String(sort.ascending), expanded.sorted().joined(separator: "|")].joined(separator: "#")
    }

    private var listingMonitorKey: String {
        [workspaceManager.searchRootsKey, currentDirectory?.path ?? "", String(atWorkspace), mode.rawValue,
         String(isTreeSearch), expanded.sorted().joined(separator: "|")].joined(separator: "#")
    }

    private func installListingMonitors() {
        let watched: Set<String>
        if mode == .tree {
            watched = Set(expanded.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path })
        } else if case .folder(let directory) = location {
            watched = [directory.standardizedFileURL.resolvingSymlinksInPath().path]
        } else {
            watched = Set(roots.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path })
        }
        let searchAll = isTreeSearch
        listingMonitors = roots.map { root in
            ProjectChangeMonitor(root: root.url, includeGenerated: true, shouldInclude: { path in
                searchAll || watched.contains(path) || watched.contains(URL(fileURLWithPath: path).deletingLastPathComponent().path)
            }) {
                Task { @MainActor in
                    listingRefresh?.cancel()
                    listingRefresh = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        listVersion += 1
                    }
                }
            }
        }
    }

    private func refreshSearchRows() async {
        guard let result = searchResult else { cachedSearchRows = []; return }
        let snapshot = source
        let worker = Task.detached(priority: .userInitiated) { FileBrowser.searchRows(result, source: snapshot) }
        let rows = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled else { return }
        cachedSearchRows = rows
        selection.keep(only: selectableURLs)
    }

    private func refreshListings() async {
        let snapshot = source, place = location, selectedMode = mode, openFolders = expanded
        let worker = Task.detached(priority: .userInitiated) { () -> ([FileBrowserEntry], [FileBrowserRow]) in
            if selectedMode == .tree { return ([], FileBrowser.treeRows(source: snapshot, expanded: openFolders)) }
            switch place {
            case .workspace: return (FileBrowser.workspaceEntries(source: snapshot, applyQuery: true), [])
            case .folder(let url): return (FileBrowser.listing(of: url, source: snapshot, applyQuery: true), [])
            }
        }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled else { return }
        cachedDirectoryEntries = result.0
        cachedTreeRows = result.1
        selection.keep(only: selectableURLs)
    }

    /// What a click, a range selection and the actions on a selection see, in display order.
    private var selectableEntries: [FileBrowserEntry] { mode == .tree ? treeRows.map(\.entry) : directoryEntries }
    private var selectableURLs: [URL] { selectableEntries.map(\.url) }

    private func linkedFolder(of entry: FileBrowserEntry) -> LinkedFolder? {
        guard let id = entry.root?.linkedID else { return nil }
        return workspaceManager.linkedFolders.first { $0.id == id }
    }

    /// The path shown in the breadcrumb strip: where Icon and List views are; in Tree view the folder that
    /// new items go to.
    private var crumbLocation: FileBrowserLocation {
        mode == .tree ? (destination.map { .folder($0) } ?? .workspace) : location
    }
    private var breadcrumbs: [FileBrowserCrumb] { FileBrowser.crumbs(for: crumbLocation, roots: roots) }

    private func open(_ crumb: FileBrowserCrumb) {
        if mode == .tree {
            if case .folder(let url) = crumb.location { treeAnchor = url } else { treeAnchor = nil }
        } else {
            go(crumb.location)
        }
    }

    /// Everything that restarts the walk of the disk behind a Tree search.
    private var searchKey: String {
        [String(isTreeSearch), searchText, String(preferences.showHidden), String(preferences.hideIgnored),
         preferences.category.rawValue, workspaceManager.searchRootsKey, String(listVersion),
         String(preferences.hideIgnored ? git.repoStatus.entries.hashValue : 0)].joined(separator: "|")
    }

    /// The first time a project is shown, its folder is open in Tree view.
    private func seedTree() {
        guard let project = projectRootURL else { return }
        let key = FileBrowser.key(project)
        guard seededRoot != key else { return }
        seededRoot = key
        expanded.insert(key)
    }

    /// Debounced, cancelled by the next keystroke, and run off the main actor (DEC-001).
    private func runTreeSearch() async {
        guard isTreeSearch else {
            searchResult = nil
            isSearching = false
            return
        }
        isSearching = true
        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
        let result = await FileBrowser.searchInBackground(source: source)
        guard !Task.isCancelled else { return }
        searchResult = result
        isSearching = false
    }

    private var searchNote: String? {
        guard isTreeSearch else { return nil }
        guard let result = searchResult else { return "Searching the workspace…" }
        var parts = [result.matches.isEmpty ? "No matches in the workspace"
                     : "\(result.matches.count) match\(result.matches.count == 1 ? "" : "es")"]
        if result.truncated { parts.append("more exist — refine the search") }
        if result.unreadableFolders > 0 {
            parts.append("\(result.unreadableFolders) folder\(result.unreadableFolders == 1 ? "" : "s") could not be read")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Body

    var body: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            gitBar
            if projectRootURL != nil { breadcrumbBar }
            toolbar
            if projectRootURL != nil {
                FileBrowserControls(preferences: preferencesBinding, sort: sortBinding, canHideIgnored: git.isGitRepo)
                    .padding(.horizontal, 8).padding(.bottom, 6)
                    .background(palette.bgSidebar)
            }

            Divider().background(palette.border)

            if projectRootURL != nil {
                browserArea
            } else if workspaceManager.indexingProgress != nil {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView().scaleEffect(0.8)
                    Text(workspaceManager.indexingProgress ?? "")
                        .uiFont(size: 11).foregroundColor(palette.blue)
                        .lineLimit(2).multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bgSidebar)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "folder.badge.plus")
                        .uiFont(size: 28).foregroundColor(palette.textDim)
                    Text("No Folder Open")
                        .uiFont(size: 12, weight: .medium).foregroundColor(palette.textDim)
                    Button("Open Folder...", action: chooseFolder)
                    .uiFont(size: 11)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bgSidebar)
            }

            // Progress bar
            if let progress = workspaceManager.indexingProgress {
                Divider().background(palette.border)
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
                    Text(progress).uiFont(size: 10).foregroundColor(palette.blue).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(palette.bgActive)
            }
        }
        .background(palette.bgSidebar)
        .onChange(of: workspaceManager.rootNode?.url) { _ in
            // Browsing state belongs to the previous folder.
            currentDirectory = nil
            atWorkspace = false
            cachedDirectoryEntries = []
            cachedTreeRows = []
            cachedSearchRows = []
            expanded = []
            seededRoot = nil
            seedTree()
            treeAnchor = nil
            searchText = ""
            revealedURL = nil
        }
        .onChange(of: workspaceManager.linkedFolders) { _ in
            // An unlinked folder cannot stay browsed or open.
            if let current = currentDirectory, workspaceManager.containerRoot(for: current) == nil { currentDirectory = nil }
            if let anchor = treeAnchor, workspaceManager.containerRoot(for: anchor) == nil { treeAnchor = nil }
            expanded = expanded.filter { key in roots.contains { key == $0.key || key.hasPrefix($0.key + "/") } }
        }
        .task(id: listingMonitorKey) { installListingMonitors() }
        .task(id: listingKey) { await refreshListings() }
        .task(id: searchResult) { await refreshSearchRows() }
        .task(id: searchKey) { await runTreeSearch() }
        // The tree may have been hidden when the reveal was asked for.
        .onDisappear { listingRefresh?.cancel(); listingMonitors = [] }
        .onAppear {
            seedTree()
            reveal(with: proxy)
        }
        .onChange(of: workspaceManager.fileTreeRevealRequest) { _ in reveal(with: proxy) }
        }
    }

    @ViewBuilder private var gitBar: some View {
        if git.isGitRepo {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").uiFont(size: 9).foregroundColor(palette.blue)
                GitBranchMenu(git: git, workspaceManager: workspaceManager, fontSize: 10)
                Spacer()
                if let activity = git.activity {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    Text(activity).uiFont(size: 9).foregroundColor(palette.textDim).lineLimit(1)
                } else if git.isOperating { ProgressView().scaleEffect(0.3) }
                Button(action: { Task { await git.pull() } }) {
                    Image(systemName: "arrow.down").uiFont(size: 9).foregroundColor(palette.textDim)
                }.buttonStyle(.plain).help("Pull")
                Button(action: { Task { await git.push() } }) {
                    Image(systemName: "arrow.up").uiFont(size: 9).foregroundColor(palette.textDim)
                }.buttonStyle(.plain).help("Push")
                Button(action: { Task { await git.refresh() } }) {
                    Image(systemName: "arrow.clockwise").uiFont(size: 9).foregroundColor(palette.textDim)
                }.buttonStyle(.plain).help("Refresh")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(palette.bgActive)
        }
    }

    /// Breadcrumb navigation: Workspace › place › folders. In Tree view it names the folder that new items go to.
    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .uiFont(size: 7, weight: .semibold)
                            .foregroundColor(palette.textDim)
                    }
                    let isCurrent = crumb.location == crumbLocation
                    Button(action: { open(crumb) }) {
                        Text(crumb.title)
                            .uiFont(size: 10, weight: isCurrent ? .semibold : .regular)
                            .foregroundColor(isCurrent ? palette.text : palette.blue)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(mode == .tree ? "New items are created in the last folder you clicked" : "Go to \(crumb.title)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.trailing, 56)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .trailing) {
            HStack(spacing: 0) {
            Button(action: { workspaceManager.openArchitecture() }) {
                Image(systemName: "viewfinder")
                    .uiFont(size: 9, weight: .semibold)
                    .foregroundColor(palette.textDim)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(palette.bgActive)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open X-Ray (⌘4)")
            Button(action: { workspaceManager.closeFolder() }) {
                Image(systemName: "xmark")
                    .uiFont(size: 9, weight: .semibold)
                    .foregroundColor(palette.textDim)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(palette.bgActive)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Folder")
            }
        }
        .background(palette.bgActive)
    }

    /// Search field and the create actions.
    private var toolbar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .uiFont(size: 11)
                .foregroundColor(palette.textDim)
            TextField(mode == .tree ? "Search the workspace..." : "Filter...", text: $searchText)
                .textFieldStyle(.plain)
                .uiFont(size: 11)
                .foregroundColor(palette.text)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(palette.textDim)
                }.buttonStyle(.plain)
            }
            if let here = destination {
                // Create in the folder being browsed (Tree: the folder last clicked).
                Button { createNewFile(in: here) } label: {
                    Image(systemName: "doc.badge.plus").uiFont(size: 11).foregroundColor(palette.textDim)
                }
                .buttonStyle(.plain)
                .help("New file in \(here.lastPathComponent)")
                Button { createNewFolder(in: here) } label: {
                    Image(systemName: "folder.badge.plus").uiFont(size: 11).foregroundColor(palette.textDim)
                }
                .buttonStyle(.plain)
                .help("New folder in \(here.lastPathComponent)")
                Button { workspaceManager.presentGraphCreator(in: here) } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted").uiFont(size: 11).foregroundColor(palette.textDim)
                }
                .buttonStyle(.plain)
                .help("New graph diagram in \(here.lastPathComponent) (AI)")
            } else if projectRootURL != nil {
                // The Workspace level has no folder to create in: it is where folders are linked (DEC-009).
                Button { workspaceManager.chooseFoldersToLink() } label: {
                    Image(systemName: "link.badge.plus").uiFont(size: 11).foregroundColor(palette.textDim)
                }
                .buttonStyle(.plain)
                .help("Link a folder to this project")
            }
        }
        .padding(8)
        .background(palette.bgSidebar)
    }

    // MARK: Browser area

    private var browserArea: some View {
        VStack(spacing: 0) {
            // Back button (if not at the top)
            if mode != .tree, let up = FileBrowser.parent(of: location, roots: roots) { backRow(up) }
            if let note = searchNote { noteBar(note) }

            ScrollView {
                content
            }
            .focusable()
            .focused($listFocused)
            .onDeleteCommand { trash(selectedItems) }
            .onChange(of: currentDirectory) { _ in selection.clear(); cachedDirectoryEntries = [] }
            .onChange(of: atWorkspace) { _ in selection.clear(); cachedDirectoryEntries = [] }
            .onChange(of: searchText) { _ in selection.keep(only: selectableURLs) }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let here = destination else { return false }
                return drop(providers, into: here)
            }
            // Right-click on empty space: create in the folder being browsed.
            .contextMenu {
                if let here = destination {
                    Button("New File...") { createNewFile(in: here) }
                    if git.isGitRepo { Button("New File (Ignored by Git)...") { createNewFile(in: here, ignored: true) } }
                    Button("New Folder...") { createNewFolder(in: here) }
                    Button("New Graph Diagram...") { workspaceManager.presentGraphCreator(in: here) }
                    Divider()
                }
                Button("Link Folder…") { workspaceManager.chooseFoldersToLink() }
                if let here = destination {
                    Button { workspaceManager.presentPDFBook([here]) } label: { Label("Export This Folder as PDF Book…", systemImage: "book.closed") }
                }
            }
            .background(palette.bgSidebar)
            if selection.count > 1 { selectionBar }
            if let archiveBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    Text(archiveBusy).uiFont(size: 10).foregroundColor(palette.text)
                    Spacer()
                }.padding(.horizontal, 10).padding(.vertical, 4).background(palette.bgActive)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .list:
            let entries = directoryEntries
            if entries.isEmpty {
                emptyNote
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        if entry.isDirectory { folderRow(entry) } else { fileRow(entry) }
                    }
                }
            }
        case .icon:
            let entries = directoryEntries
            if entries.isEmpty {
                emptyNote
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74, maximum: 120), spacing: 4, alignment: .top)], spacing: 6) {
                    ForEach(entries) { entry in iconCell(entry) }
                }
                .padding(8)
            }
        case .tree:
            let rows = treeRows
            if rows.isEmpty && !isSearching {
                emptyNote
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if row.entry.isDirectory { folderRow(row.entry, tree: row) } else { fileRow(row.entry, tree: row) }
                    }
                }
            }
        }
    }

    private var emptyNote: some View {
        Text(filter.isActive ? "Nothing matches the filters" : "This folder is empty")
            .uiFont(size: 11)
            .foregroundColor(palette.textDim)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }

    private func noteBar(_ text: String) -> some View {
        HStack(spacing: 6) {
            if isSearching { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12) }
            Text(text).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(palette.bgSidebar)
    }

    /// ".." row: the parent folder, or the Workspace level from the root of a place.
    private func backRow(_ up: FileBrowserLocation) -> some View {
        var upFolder: URL?
        if case .folder(let url) = up { upFolder = url }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left")
                    .uiFont(size: 10, weight: .semibold)
                    .foregroundColor(palette.blue)
                Text(upFolder == nil ? "Workspace" : "..")
                    .uiFont(size: 12, weight: .medium)
                    .foregroundColor(palette.blue)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture { go(up) }
            .background(upFolder.map { dropTarget == $0 } == true ? palette.blue.opacity(0.25) : palette.bgSidebar)
            .onDrop(of: upFolder == nil ? [] : [.fileURL], isTargeted: upFolder.map(dropBinding)) { providers in
                guard let upFolder else { return false }
                return drop(providers, into: upFolder)
            }
            .accessibilityLabel(upFolder == nil ? "Up to the Workspace level" : "Up to the parent folder")
            .accessibilityAddTraits(.isButton)
            Divider().background(palette.border).opacity(0.5)
        }
    }

    /// "Reveal in File Tree": show the item's folder (Tree: open its ancestors), clear the name query, switch
    /// off only the filter choices that would hide it (DEC-008), scroll to the item and highlight it. An item
    /// not on disk (a terminal or X-Ray tab) shows its nearest existing folder.
    private func reveal(with proxy: ScrollViewProxy) {
        guard let request = workspaceManager.fileTreeRevealRequest,
              let projectRoot = projectRootURL?.standardizedFileURL else { return }
        workspaceManager.fileTreeRevealRequest = nil
        var target = request.standardizedFileURL
        // The project, or the linked folder, the item is in (Task 59).
        guard let root = workspaceManager.containerRoot(for: target)?.standardizedFileURL else { return }
        while target.path != root.path, !FileManager.default.fileExists(atPath: target.path) {
            target = target.deletingLastPathComponent()
        }
        let relaxed = FileBrowser.relaxing(filter, toShow: target, source: source)
        preferences.showHidden = relaxed.showHidden
        preferences.hideIgnored = relaxed.hideIgnored
        preferences.category = relaxed.category
        searchText = ""
        let isPlace = roots.contains { $0.key == FileBrowser.key(target) }
        revealedURL = target.path == projectRoot.path ? nil : target
        switch mode {
        case .tree:
            expanded.formUnion(FileBrowser.ancestors(of: target, roots: roots).map(FileBrowser.key))
            treeAnchor = isPlace ? target : target.deletingLastPathComponent()
        case .icon, .list:
            if target.path == projectRoot.path {
                go(.folder(projectRoot))
            } else if isPlace {
                // A linked folder's root is a row of the Workspace level.
                go(.workspace)
            } else {
                go(.folder(target.deletingLastPathComponent()))
            }
        }
        guard target.path != projectRoot.path else { return }
        // After the list of the new folder is laid out.
        let id = FileBrowser.key(target)
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
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

    // MARK: - Formatting

    /// "now", "5m", "3h", "2d", "4w", "2025-03-01".
    private func shortDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 14): return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 60): return "\(Int(seconds / (86_400 * 7)))w"
        default:
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            return f.string(from: date)
        }
    }

    /// "512 B", "14 KB", "2.3 MB".
    private func sizeLabel(_ bytes: Int) -> some View {
        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            .uiFont(size: 9, design: .monospaced)
            .foregroundColor(palette.textDim)
            .lineLimit(1)
            .help("\(bytes.formatted()) bytes")
    }

    private func dateLabel(_ date: Date?) -> some View {
        Text(shortDate(date))
            .uiFont(size: 9, design: .monospaced)
            .foregroundColor(palette.textDim)
            .help(date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "")
    }


    // MARK: - Row Views

    /// Background of a row or cell: drop target, selection, or the item "Reveal in File Tree" showed.
    private func rowBackground(_ url: URL, isFolder: Bool) -> Color {
        if isFolder && dropTarget == url { return palette.blue.opacity(0.25) }
        if selection.contains(url) { return selectedBackground }
        if revealedURL == url { return palette.blue.opacity(0.18) }
        return Color.clear
    }

    /// The arrow in front of a Tree folder.
    private func disclosure(_ row: FileBrowserRow) -> some View {
        Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
            .uiFont(size: 8, weight: .semibold)
            .foregroundColor(palette.textDim)
            .frame(width: 10)
            .opacity(row.isExpandable ? 1 : 0)
    }

    /// A folder row; `linked` marks a folder linked to the project (Task 59): shown with its
    /// location, unlinked from its menu, outside the project's own X-Ray, git and exclusions.
    /// `tree` is set in Tree view: the row is indented and has a disclosure arrow instead of the date.
    private func folderRow(_ entry: FileBrowserEntry, tree: FileBrowserRow? = nil) -> some View {
        let url = entry.url
        let linked = linkedFolder(of: entry)
        let inProject = linked == nil && workspaceManager.linkedFolder(containing: url) == nil
        let deco = inProject ? gitDecoration(url, isDirectory: true) : GitDecoration()
        return HStack(spacing: 6) {
            if let tree { disclosure(tree) }
            Image(systemName: linked == nil ? "folder.fill" : "folder.fill.badge.gearshape")
                .uiFont(size: 11)
                .foregroundColor(entry.isHidden ? palette.textDim : (entry.root?.isProject == true ? palette.blue : palette.yellow))
            Text(entry.name)
                .uiFont(size: 11)
                .foregroundColor(palette.text)
                .lineLimit(1)
            if let linked {
                Image(systemName: "link").uiFont(size: 8).foregroundColor(palette.cyan)
                Text(linked.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .uiFont(size: 9).foregroundColor(palette.textDim).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if tree == nil { dateLabel(entry.modified) }
            if deco.inside > 0, let state = deco.state {
                HStack(spacing: 2) {
                    Circle().fill(gitColor(state)).frame(width: 6, height: 6)
                    Text("\(deco.inside)").uiFont(size: 8, weight: .medium).foregroundColor(gitColor(state))
                }
                .help(deco.detail)
            }
            if tree == nil {
                Image(systemName: "chevron.right")
                    .uiFont(size: 9)
                    .foregroundColor(palette.textDim)
            }
        }
        .padding(.leading, CGFloat(tree?.depth ?? 0) * 14)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(linked.map { "Linked folder: \($0.path)" } ?? "")
        .onTapGesture { click(entry) }
        .modifier(PlaceAwareDrag(isPlace: entry.root != nil, item: { dragItem(url) }))
        .background(rowBackground(url, isFolder: true))
        .onDrop(of: [.fileURL], isTargeted: dropBinding(url)) { providers in drop(providers, into: url) }
        .opacity(workspaceManager.isExcluded(url) ? 0.4 : deco.state == .ignored ? 0.5 : (tree?.isMatch == false ? 0.6 : 1.0))
        .contextMenu { folderMenu(entry) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(entry.name)")
        .accessibilityValue(tree.map { $0.isExpanded ? "expanded" : "collapsed" } ?? "")
        .accessibilityAddTraits(.isButton)
    }

    private func fileRow(_ entry: FileBrowserEntry, tree: FileBrowserRow? = nil) -> some View {
        let url = entry.url
        let inProject = workspaceManager.linkedFolder(containing: url) == nil
        let gitStatus = inProject ? fileGitStatus(url) : nil
        let deco = inProject ? gitDecoration(url, isDirectory: false) : GitDecoration()
        let (icon, color) = fileIcon(for: entry)
        return HStack(spacing: 4) {
            if tree != nil { Color.clear.frame(width: 10 + 6, height: 1) }
            Image(systemName: icon).uiFont(size: 11).foregroundColor(color).frame(width: 16)
            Text(url.lastPathComponent).uiFont(size: 11).foregroundColor(deco.state.map(gitColor) ?? palette.text).lineLimit(1)
            Spacer()
            if tree == nil {
                if let size = entry.size { sizeLabel(size) }
                dateLabel(entry.modified)
            }
            if let state = deco.state, state != .ignored {
                Text(state.letter)
                    .uiFont(size: 9, weight: deco.staged ? .heavy : .bold, design: .monospaced)
                    .foregroundColor(gitColor(state))
                    .frame(width: 12)
                    .help(deco.detail)
            }
        }
        .opacity(deco.state == .ignored ? 0.5 : entry.isUnsupported ? 0.7 : (tree?.isMatch == false ? 0.6 : 1))
        .padding(.leading, CGFloat(tree?.depth ?? 0) * 14)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(rowBackground(url, isFolder: false))
        .contentShape(Rectangle())
        .onTapGesture { click(entry) }
        .onDrag { dragItem(url) }
        .contextMenu { fileMenu(entry, gitStatus: gitStatus, inProject: inProject) }
        .help(entry.isUnsupported ? "MarkView has no viewer for this file. Right-click for Open with Default App." : "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.isUnsupported ? "File \(entry.name), no viewer" : "File \(entry.name)")
        .accessibilityAddTraits(.isButton)
    }

    /// One cell of the Icons view.
    private func iconCell(_ entry: FileBrowserEntry) -> some View {
        let url = entry.url
        let linked = linkedFolder(of: entry)
        let inProject = linked == nil && workspaceManager.linkedFolder(containing: url) == nil
        let deco = inProject ? gitDecoration(url, isDirectory: entry.isDirectory) : GitDecoration()
        let (icon, color): (String, Color) = entry.isDirectory
            ? (linked == nil ? "folder.fill" : "folder.fill.badge.gearshape",
               entry.isHidden ? palette.textDim : (entry.root?.isProject == true ? palette.blue : palette.yellow))
            : fileIcon(for: entry)
        return VStack(spacing: 3) {
            Image(systemName: icon).uiFont(size: 26).foregroundColor(color).frame(height: 32)
            Text(entry.name)
                .uiFont(size: 10)
                .foregroundColor(deco.state.map(gitColor) ?? palette.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6).padding(.horizontal, 3)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(rowBackground(url, isFolder: entry.isDirectory)))
        .contentShape(Rectangle())
        .opacity(workspaceManager.isExcluded(url) ? 0.4 : deco.state == .ignored ? 0.5 : entry.isUnsupported ? 0.7 : 1)
        .help(linked.map { "Linked folder: \($0.path)" } ?? (entry.isUnsupported ? "\(entry.name) — no viewer in MarkView" : entry.name))
        .onTapGesture { click(entry) }
        .modifier(PlaceAwareDrag(isPlace: entry.root != nil, item: { dragItem(url) }))
        .onDrop(of: entry.isDirectory ? [.fileURL] : [], isTargeted: dropBinding(url)) { providers in drop(providers, into: url) }
        .contextMenu {
            if entry.isDirectory { folderMenu(entry) }
            else { fileMenu(entry, gitStatus: inProject ? fileGitStatus(url) : nil, inProject: inProject) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.isDirectory ? "Folder \(entry.name)" : "File \(entry.name)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Context menus

    @ViewBuilder private func folderMenu(_ entry: FileBrowserEntry) -> some View {
        let url = entry.url
        let linked = linkedFolder(of: entry)
        let inProject = linked == nil && workspaceManager.linkedFolder(containing: url) == nil
        // The project folder and the linked folders are places: they are not renamed, moved or excluded from here.
        let isPlace = entry.root != nil
        if isPartOfSelection(url) {
            selectionMenu
        } else {
            if let linked {
                Button("Unlink Folder") { workspaceManager.unlinkFolder(linked.id) }
                Divider()
            } else if inProject {
                if !isPlace {
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
                }
                Button { workspaceManager.openXRay(for: url) } label: { Label("X-Ray", systemImage: "viewfinder") }
                Button { workspaceManager.startRecursiveInsight(at: url) } label: { Label("Recursive Insight", systemImage: "sparkles") }
                Button { workspaceManager.openDiscussion(about: url) } label: { Label("Discuss…", systemImage: "bubble.left.and.text.bubble.right") }
                Button { workspaceManager.startResearch(fromFolder: url) } label: { Label("New Research from This Folder…", systemImage: "books.vertical") }
                Divider()
            }
            Button("New File...") { createNewFile(in: url) }
            Button { workspaceManager.presentPDFBook([url]) } label: { Label("Export PDF Book…", systemImage: "book.closed") }
            if git.isGitRepo { Button("New File (Ignored by Git)...") { createNewFile(in: url, ignored: true) } }
            Button("New Folder...") { createNewFolder(in: url) }
            Button("New Graph Diagram...") { workspaceManager.presentGraphCreator(in: url) }
            if git.isGitRepo && inProject && !isPlace {
                Divider()
                Button("Stage All in Folder") { stageAllInFolder(url) }
                Button("Add to .gitignore") { addToGitignore(url, isDirectory: true) }
            }
            Divider()
            Button("Compress to .zip") { compress([url]) }
            Divider()
            Button { workspaceManager.openTerminal(in: url) } label: { Label("Open Terminal Here", systemImage: "terminal") }
            Button("Show in Finder") { NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "") }
            Button("Open in Terminal.app") { openTerminal(at: url) }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
            if linked == nil && !isPlace {
                Divider()
                Button("Rename…") { rename(url) }
                Button("Move to…") { moveAsking([url]) }
                Button("Move to Trash", role: .destructive) { trash([url]) }
            }
        }
    }

    /// A file without a viewer (DEC-005) gets Open with Default App and the actions that fit any file; the
    /// ones that read the file as a document (X-Ray, Discuss, Implement, PDF book) are left out.
    @ViewBuilder private func fileMenu(_ entry: FileBrowserEntry, gitStatus gs: GitClient.GitFileStatus?, inProject: Bool) -> some View {
        let url = entry.url
        if isPartOfSelection(url) {
            selectionMenu
        } else {
            if let gs {
                if gs.isStaged {
                    Button("Unstage") { workspaceManager.gitClient.unstageFile(gs.file) }
                } else {
                    Button("Stage") { workspaceManager.gitClient.stageFile(gs.file) }
                }
                Button("Discard Changes") { workspaceManager.gitClient.discardChanges(gs.file) }
                Divider()
            }
            if git.isGitRepo && inProject { Button("Add to .gitignore") { addToGitignore(url, isDirectory: false) } }
            if entry.isUnsupported {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open with Default App", systemImage: "arrow.up.forward.app") }
            } else {
                if inProject { Button { workspaceManager.openXRay(for: url) } label: { Label("X-Ray", systemImage: "viewfinder") } }
                if FileType.isHTML(url) {
                    Button { workspaceManager.openHTMLInBrowser(url) } label: { Label("Open in Browser", systemImage: "safari") }
                }
                Button { workspaceManager.openDiscussion(about: url) } label: { Label("Discuss This File…", systemImage: "bubble.left.and.text.bubble.right") }
                if FileType.markdownExtensions.contains(url.pathExtension.lowercased()) {
                    Button { workspaceManager.startRecursiveInsight(at: url) } label: { Label("Recursive Insight on This File", systemImage: "sparkles") }
                }
                Menu("New from This Document") {
                    ForEach(IntakeKind.allCases) { kind in
                        Button(kind.title + "…") { workspaceManager.startIntake(kind, fromDocument: url) }
                    }
                }
                Button { workspaceManager.implementWithAI(url) } label: { Label("Implement with AI", systemImage: "hammer") }
                Button { workspaceManager.presentPDFBook([url]) } label: { Label("Export PDF Book…", systemImage: "book.closed") }
            }
            Divider()
            if Archive.isArchive(url) {
                Button("Extract Here") { extractArchive(url, askFolder: false) }
                Button("Extract to…") { extractArchive(url, askFolder: true) }
            }
            Button("Compress to .zip") { compress([url]) }
            Divider()
            Button { workspaceManager.openTerminal(in: url.deletingLastPathComponent()) } label: {
                Label("Open Terminal Here", systemImage: "terminal")
            }
            Button("Show in Finder") { NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "") }
            Button("Open in Terminal.app") { openTerminal(at: url.deletingLastPathComponent()) }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
            Divider()
            Button("Rename…") { rename(url) }
            Button("Move to…") { moveAsking([url]) }
            Button("Move to Trash", role: .destructive) { trash([url]) }
        }
    }

    // MARK: - Helpers

    // MARK: - Selection (several rows at once)

    private var selectedBackground: Color { palette.accent.opacity(0.3) }

    /// The selected rows in list order; the project folder and the linked folders are never moved or trashed from here.
    private var selectedItems: [URL] {
        let entries = selectableEntries
        let places = Set(entries.filter { $0.root != nil }.map(\.url))
        return withoutNested(selection.ordered(entries.map(\.url)).filter { !places.contains($0) })
    }

    /// In Tree view a folder and rows under it can both be selected; trashing, moving or zipping both would act on
    /// the descendants twice (and fail on paths that no longer exist), so only the outermost items stay.
    private func withoutNested(_ urls: [URL]) -> [URL] {
        let keys = urls.map(FileBrowser.key)
        return zip(urls, keys).filter { _, key in !keys.contains { $0 != key && key.hasPrefix($0 + "/") } }.map(\.0)
    }

    /// A right-click on a row of a multiple selection acts on the whole selection.
    private func isPartOfSelection(_ url: URL) -> Bool { selection.count > 1 && selection.contains(url) }

    /// Click: select it, then act: a folder is entered (Icons, List) or opened/closed (Tree), a file with a viewer
    /// opens, a file without one only stays selected (DEC-005). ⌘-click adds or removes the row, ⇧-click selects
    /// the range from the last click; neither opens anything.
    private func click(_ entry: FileBrowserEntry) {
        // The modifiers of the click itself.
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        let kind: ListSelection<URL>.Click = flags.contains(.command) ? .toggle : flags.contains(.shift) ? .range : .plain
        selection.click(entry.url, kind, in: selectableURLs)
        listFocused = true
        guard kind == .plain else { return }
        switch mode {
        case .icon, .list:
            if entry.isDirectory { go(.folder(entry.url)) } else { openFile(entry) }
        case .tree:
            if entry.isDirectory {
                treeAnchor = entry.url
                // The folders of a search result stay open: the search shows the way to the matches.
                guard !isTreeSearch else { return }
                if expanded.contains(entry.key) { expanded.remove(entry.key) } else { expanded.insert(entry.key) }
            } else {
                treeAnchor = entry.url.deletingLastPathComponent()
                openFile(entry)
            }
        }
    }

    private func openFile(_ entry: FileBrowserEntry) {
        if entry.hasViewer { workspaceManager.openFile(entry.url) }
    }

    /// Bottom bar while several rows are selected.
    private var selectionBar: some View {
        HStack(spacing: 8) {
            Text("\(selection.count) selected").uiFont(size: 10, weight: .semibold).foregroundColor(palette.text)
            Spacer()
            Button { workspaceManager.presentPDFBook(withoutNested(selection.ordered(selectableURLs))) } label: { Image(systemName: "book.closed").uiFont(size: 11) }
                .buttonStyle(.plain).foregroundColor(palette.textDim).help("Export selected files and folders as a PDF book")
            Button { moveAsking(selectedItems) } label: { Image(systemName: "folder").uiFont(size: 11) }
                .buttonStyle(.plain).foregroundColor(palette.textDim).help("Move to…").disabled(selectedItems.isEmpty)
            Button { trash(selectedItems) } label: { Image(systemName: "trash").uiFont(size: 11) }
                .buttonStyle(.plain).foregroundColor(palette.red).help("Move to Trash (⌫)").disabled(selectedItems.isEmpty)
            Menu { selectionMenu } label: { Image(systemName: "ellipsis.circle").uiFont(size: 11) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More actions")
            Button { selection.clear() } label: { Image(systemName: "xmark").uiFont(size: 9, weight: .semibold) }
                .buttonStyle(.plain).foregroundColor(palette.textDim).help("Clear the selection")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(palette.bgActive)
    }

    /// Actions on the whole selection (context menu of a selected row, the bar's menu).
    @ViewBuilder private var selectionMenu: some View {
        let items = selectedItems
        let changed = items.compactMap { fileGitStatus($0) }
        Button { workspaceManager.presentPDFBook(withoutNested(selection.ordered(selectableURLs))) } label: { Label("Export PDF Book…", systemImage: "book.closed") }
        if !items.isEmpty { Button("Move \(items.count) Items to…") { moveAsking(items) } }
        if !changed.isEmpty {
            Divider()
            if changed.contains(where: { !$0.isStaged }) {
                Button("Stage \(changed.filter { !$0.isStaged }.count)") { changed.filter { !$0.isStaged }.forEach { git.stageFile($0.file) } }
            }
            if changed.contains(where: \.isStaged) {
                Button("Unstage \(changed.filter(\.isStaged).count)") { changed.filter(\.isStaged).forEach { git.unstageFile($0.file) } }
            }
            Button("Discard Changes in \(changed.count)…") { discard(changed) }
        }
        if !items.isEmpty {
            Divider()
            Button("Compress \(items.count) Items to .zip") { compress(items) }
            Divider()
            Button("Copy \(items.count) Paths") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Move \(items.count) Items to Trash", role: .destructive) { trash(items) }
        }
    }

    /// Move files and folders to the macOS Trash after one confirmation; their open tabs close
    /// without saving, and the tree refreshes. Recoverable from the Trash, unlike a plain delete.
    private func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        if urls.count == 1, let url = urls.first {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
            alert.informativeText = isDirectory
                ? "The folder and everything in it move to the Trash. Open documents from it close without saving."
                : "The file moves to the Trash. If it is open, its tab closes without saving."
        } else {
            alert.messageText = "Move \(urls.count) items to the Trash?"
            let names = urls.prefix(6).map { "• " + $0.lastPathComponent }.joined(separator: "\n")
            alert.informativeText = names + (urls.count > 6 ? "\n…and \(urls.count - 6) more" : "")
                + "\n\nFolders move with everything in them. Open documents from them close without saving."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var errors: [String] = []
        for url in urls {
            workspaceManager.closeTabs(under: url)
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch {
                errors.append("Couldn't move “\(url.lastPathComponent)” to the Trash: \(error.localizedDescription)")
            }
        }
        selection.clear()
        listVersion += 1
        workspaceManager.refreshFileTree()
        if !errors.isEmpty { showError(errors.joined(separator: "\n")) }
    }

    /// Choose a folder and move the items there; open tabs follow them.
    private func moveAsking(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination ?? projectRootURL
        panel.prompt = "Move Here"
        panel.message = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to:" : "Move \(urls.count) items to:"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let errors = workspaceManager.transfer(urls, into: folder, copy: false)
        selection.clear()
        listVersion += 1
        if !errors.isEmpty { showError(errors.joined(separator: "\n")) }
    }

    private func rename(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Rename “\(url.lastPathComponent)”"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = url.lastPathComponent
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let error = workspaceManager.rename(url, to: input.stringValue) { return showError(error) }
        selection.clear()
        listVersion += 1
    }

    private func discard(_ files: [GitClient.GitFileStatus]) {
        let alert = NSAlert()
        alert.messageText = "Discard changes in \(files.count) file\(files.count == 1 ? "" : "s")?"
        alert.informativeText = "Uncommitted changes are lost; this cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        files.forEach { git.discardChanges($0.file) }
    }

    private func fileIcon(for entry: FileBrowserEntry) -> (String, Color) {
        let url = entry.url
        // No viewer (DEC-005): a plain document, not one of the typed icons.
        if entry.isUnsupported { return ("doc", palette.textDim) }
        if Archive.isArchive(url) { return ("archivebox", palette.yellow) }
        switch FileType.from(url: url) {
        case .json: return ("curlybraces", palette.green)
        case .xml:  return ("chevron.left.forwardslash.chevron.right", palette.orange)
        case .yaml: return ("list.bullet.indent", palette.purple)
        case .canvas: return ("rectangle.3.group", palette.yellow)
        case .pdf: return ("doc.richtext", palette.orange)
        case .markdown: return ("doc.text", palette.blue)
        case .code: return ("curlybraces.square", palette.cyan)
        case .table: return ("tablecells", palette.green)
        case .parquet: return ("square.stack.3d.up", palette.purple)
        case .sqlite: return ("cylinder", palette.yellow)
        case .log: return ("list.bullet.rectangle", palette.textDim)
        }
    }

    /// What Git says about a path of the project, for the icon, colour and count in its row.
    private func gitDecoration(_ url: URL, isDirectory: Bool) -> GitDecoration {
        guard git.isGitRepo, let root = git.workingDirectory else { return GitDecoration() }
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return GitDecoration() }
        return git.repoStatus.decoration(of: String(path.dropFirst(prefix.count)), isDirectory: isDirectory)
    }

    private func gitColor(_ state: GitFileState) -> Color {
        switch state {
        case .modified, .typeChanged: return palette.orange
        case .added, .copied, .untracked: return palette.green
        case .deleted, .conflicted: return palette.red
        case .renamed: return palette.blue
        case .ignored, .tracked: return palette.textDim
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

    /// Add a file or folder to the repository's .gitignore (as an anchored path), once.
    private func addToGitignore(_ url: URL, isDirectory: Bool) {
        guard let root = git.workingDirectory ?? workspaceManager.rootNode?.url else { return }
        Task {
            let top = await GitHubClient.execute(["rev-parse", "--show-toplevel"], in: root, git: true)
            let repo = URL(fileURLWithPath: top.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                           ? root.path : top.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            let base = repo.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { return showError("“\(url.lastPathComponent)” is outside the repository.") }
            await git.ignore(String(path.dropFirst(base.count)), isDirectory: isDirectory)
            listVersion += 1
        }
    }

    private func createNewFile(in folderURL: URL, ignored: Bool = false) {
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
            if ignored { addToGitignore(fileURL, isDirectory: false) }
            if mode == .tree { expanded.insert(FileBrowser.key(folderURL)) }
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
        let roots = ([workspaceManager.rootNode?.url] + workspaceManager.linkedFolders.map(\.url))
            .compactMap { $0?.standardizedFileURL.path }
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
            let inside = urls.allSatisfy { url in roots.contains { url.standardizedFileURL.path.hasPrefix($0 + "/") } }
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

    /// What an archive action in progress is doing ("Extracting photos.zip…").
    @State private var archiveBusy: String?

    /// Unpack into a new folder next to the archive, or inside a folder the person picks.
    private func extractArchive(_ url: URL, askFolder: Bool) {
        var parent: URL?
        if askFolder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Extract Here"
            panel.message = "A new folder named after the archive is made inside the folder you choose."
            panel.directoryURL = url.deletingLastPathComponent()
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            parent = chosen
        }
        guard archiveBusy == nil else { return }
        archiveBusy = "Extracting \(url.lastPathComponent)…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                let folder = Archive.uniqueFolder(for: url, in: parent)
                return Result { try Archive.extractAll(url, to: folder); return folder }
            }.value
            archiveBusy = nil
            switch result {
            case .success(let folder):
                workspaceManager.refreshFileTree()
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            case .failure(let error): showError("Could not extract \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Zip files and folders into a new .zip next to them.
    private func compress(_ urls: [URL]) {
        guard archiveBusy == nil, !urls.isEmpty else { return }
        archiveBusy = "Compressing \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try Archive.compress(urls) } }.value
            archiveBusy = nil
            switch result {
            case .success(let zip):
                workspaceManager.refreshFileTree()
                NSWorkspace.shared.activateFileViewerSelecting([zip])
            case .failure(let error): showError("Could not compress: \(error.localizedDescription)")
            }
        }
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
            if mode == .tree { expanded.insert(FileBrowser.key(parentURL)) }
            listVersion += 1
            workspaceManager.refreshFileTree()
        }
    }
}

#Preview {
    FileTreeView().environmentObject(WorkspaceManager())
}


/// `onDrag` for everything except the places of the Workspace level: dragging the project folder or a linked folder
/// onto another place would copy the whole folder tree.
private struct PlaceAwareDrag: ViewModifier {
    let isPlace: Bool
    let item: () -> NSItemProvider

    @ViewBuilder func body(content: Content) -> some View {
        if isPlace { content } else { content.onDrag(item) }
    }
}
