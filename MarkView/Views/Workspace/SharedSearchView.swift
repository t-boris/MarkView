import SwiftUI
import AppKit
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What a search result opens into, decided by the model and shown by the window (`SearchOpening.show`).
enum SearchOpening {
    /// A document the model handed to its default application (a Word file): nothing is left to show.
    case external
    /// A file in a tab; a PDF at `page`, a note scrolled to `scrollText` once it is open.
    case file(URL, page: Int?, scrollText: String?)
    /// A code file at a line.
    case code(URL, line: Int)

    /// Shows the result in the window the person searched from. The scroll waits for the page to load.
    @MainActor func show(in window: any WindowCommands) {
        switch self {
        case .external:
            break
        case .code(let url, let line):
            window.openFile(url, line: line)
        case .file(let url, let page, let scrollText):
            if let page { window.openPDF(url, page: page) } else { window.openFile(url) }
            if let scrollText {
                // task: posts one notification 0.4 s after the file opened; it owns nothing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(.scrollToText, for: window, object: scrollText)
                }
            }
        }
    }
}

@MainActor
final class SharedSearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [ProjectSearchResult] = []
    @Published var indexedDocuments: [ProjectSearchResult] = []
    @Published var indexing = false
    @Published var scanned = 0
    @Published var indexedAt: Date?
    @Published var error: String?
    /// The searches, rebuilds and openings the panel started: they end with the panel, and a new one replaces its own kind (`AR-19`).
    private let tasks = TaskBag()
    private var documentDatabasePath: String?

    private let index = ProjectSearchIndex()
    /// The roots of the last rebuild: results are resolved against them.
    private(set) var roots: [ProjectSearchRoot] = []

    func rebuild(root: URL?, linked: [LinkedFolder] = []) async {
        guard let root else { results = []; indexedDocuments = []; roots = []; return }
        indexing = true
        scanned = 0
        error = nil
        roots = ProjectSearchRoot.all(project: root, linked: linked)
        do {
            try await index.rebuild(roots: roots) { [weak self] count in
                Task { @MainActor in self?.scanned = count }
            }
            indexedAt = await index.indexedAt
            await search()
        } catch is CancellationError {
            indexing = false
            return
        } catch {
            self.error = "Search indexing failed: \(error.localizedDescription)"
        }
        indexing = false
    }

    /// Reads the index again for `root` and its linked folders; a newer rebuild replaces the running one.
    func startRebuild(root: URL?, linked: [LinkedFolder]) {
        tasks.store(Task { [weak self] in await self?.rebuild(root: root, linked: linked) }, for: "rebuild")
    }

    /// What `result` opens into: a file (at its line, or at the text found), or a file from inside an archive (its temporary copy).
    /// Nil, with `error` set, when it cannot be opened. The window shows the answer (`SearchOpening.show`).
    private func resolve(_ result: ProjectSearchResult, root: URL, linked: [LinkedFolder]) async -> SearchOpening? {
        guard let path = result.path else { return nil }
        let roots = self.roots
        if let range = path.range(of: ProjectSearchIndex.archiveSeparator) {
            let entryPath = String(path[range.upperBound...])
            guard let archiveURL = ProjectSearchRoot.url(for: String(path[..<range.lowerBound]), in: roots) else { return nil }
            let opened = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    guard let entry = try Archive.list(archiveURL).first(where: { $0.path == entryPath }) else { throw ArchiveError.notFound(entryPath) }
                    return try Archive.extractEntry(entry, from: archiveURL)
                }
            }.value
            switch opened {
            case .success(let copy): return .file(copy, page: nil, scrollText: nil)
            case .failure(let failure): error = failure.localizedDescription; return nil
            }
        }
        guard let url = ProjectSearchRoot.url(for: path, in: roots) else { return nil }
        // The result must still be under a root of the search (the project or a linked folder).
        let valid = await Task.detached { () -> Bool in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let bases = roots.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
            return bases.contains { resolved.path.hasPrefix($0) } && FileManager.default.fileExists(atPath: resolved.path)
        }.value
        guard valid else {
            error = "This result is missing or no longer inside the project. Refreshing search."
            await rebuild(root: root, linked: linked)
            return nil
        }
        if url.pathExtension.lowercased() == "docx" {
            guard NSWorkspace.shared.open(url) else {
                error = "Could not open this Word document in its default application."
                return nil
            }
            return .external
        } else if url.pathExtension.lowercased() == "pdf" {
            return .file(url, page: result.page, scrollText: nil)
        } else if result.scope == .content, let line = result.line, !FileType.markdownExtensions.contains(url.pathExtension.lowercased()) {
            return .code(url, line: line)
        } else if result.scope == .content {
            // An FTS match may contain separated query terms; the first term still locates the passage.
            let text = result.line == nil ? String(query.split(whereSeparator: { $0.isWhitespace }).first ?? "") : query
            return .file(url, page: nil, scrollText: text)
        }
        return .file(url, page: nil, scrollText: nil)
    }

    /// Opens a result: `shown` gets what it opens into once that is known (never when it cannot be opened).
    func startOpen(_ result: ProjectSearchResult, root: URL?, linked: [LinkedFolder], shown: @escaping (SearchOpening) -> Void) {
        guard let root else { return }
        tasks.store(Task { [weak self] in
            guard let opening = await self?.resolve(result, root: root, linked: linked), !Task.isCancelled else { return }
            shown(opening)
        }, for: "open")
    }

    func scheduleSearch(documentDatabasePath: String? = nil) {
        self.documentDatabasePath = documentDatabasePath
        tasks.store(Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            await self?.search()
        }, for: "search")
    }

    /// Searches at once (the query was cleared), without the pause of `scheduleSearch`.
    func startSearch() {
        tasks.store(Task { [weak self] in await self?.search() }, for: "search-now")
    }

    func search() async {
        let searched = query
        let databasePath = documentDatabasePath
        async let found = index.search(searched)
        let indexed = await Task.detached(priority: .userInitiated) {
            guard let databasePath else { return [ProjectSearchResult]() }
            return ProjectDocumentSearch.search(databasePath: databasePath, query: searched)
        }.value
        let files = await found
        if !Task.isCancelled && query == searched {
            results = files
            let matchedPaths = Set(files.compactMap { $0.scope == .content ? $0.path : nil })
            indexedDocuments = indexed.filter { $0.path.map { !matchedPaths.contains($0) } ?? false }
        }
    }
}

struct SharedSearchView: View {
    @Environment(\.palette) private var palette
    @Environment(\.windowCommands) private var window
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tabs: TabsController
    @EnvironmentObject private var fileTree: WorkspaceFileTreeStore
    @EnvironmentObject private var git: GitClient
    @EnvironmentObject private var project: ProjectContext
    @EnvironmentObject private var layout: PanelLayout
    @EnvironmentObject private var chrome: WindowChrome
    @EnvironmentObject private var requests: WindowRequests
    @EnvironmentObject private var codeXRay: CodeAndXRayCoordinator
    @EnvironmentObject private var theme: WindowTheme
    @StateObject private var model = SharedSearchModel()
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(palette.textDim)
                TextField("Search files, documents, code, and commands", text: $model.query)
                    .textFieldStyle(.plain)
                    .uiFont(size: 16)
                    .focused($searchFocused)
                    .onChange(of: model.query) { _ in model.scheduleSearch(documentDatabasePath: project.database?.dbPath) }
                if model.indexing { ProgressView().controlSize(.small) }
                Button { model.startRebuild(root: fileTree.rootNode?.url, linked: project.linkedFolders) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh project search index")
                .accessibilityLabel("Refresh project search index")
                Button("Done") { dismiss() }
            }
            .padding(14)
            Divider()
            HStack {
                if model.indexing {
                    Text("Indexing · \(model.scanned) files scanned")
                } else if let date = model.indexedAt {
                    Text("Project index updated \(date.formatted(date: .omitted, time: .shortened)) · Refresh for external changes")
                } else {
                    Text("Open a project to search its files")
                }
                Spacer()
                Text("Files · Documents · Code · Commands")
                Image(systemName: "info.circle")
                    .help("Searches project and linked-folder names and text, PDF and Word text, the document index, and archive entry names. Locked or scanned PDFs, binary data, caches, very large files, and archive contents are not indexed. Results are limited; refine the query if needed.")
                    .accessibilityLabel("Search scope: project and linked-folder names and text, PDF and Word text, the document index, and archive entry names. Some large, binary, locked and scanned files are not indexed.")
            }
            .uiFont(size: 10)
            .foregroundColor(palette.textDim)
            .padding(.horizontal, 14).padding(.vertical, 6)
            if let error = model.error {
                Text(error).uiFont(size: 11).foregroundColor(palette.orange).padding(8)
            }
            if model.results.filter({ $0.scope == .file }).count >= 75 || model.results.filter({ $0.scope == .content }).count >= 150 {
                Text("Results are limited. Refine the search to see other matches.")
                    .uiFont(size: 10).foregroundColor(palette.orange).padding(.horizontal, 14).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.results.contains(where: { $0.scope == .file }) {
                        sectionTitle("Files")
                        ForEach(model.results.filter { $0.scope == .file }) { result in
                            searchResult(result)
                        }
                    }
                    if model.results.contains(where: { $0.scope == .content }) {
                        sectionTitle("Content")
                        ForEach(model.results.filter { $0.scope == .content }) { result in
                            searchResult(result)
                        }
                    }
                    if !model.indexedDocuments.isEmpty {
                        sectionTitle("Indexed documents")
                        ForEach(model.indexedDocuments) { result in searchResult(result) }
                    }
                    if !matchingCommands.isEmpty {
                        sectionTitle("Commands")
                        ForEach(matchingCommands) { command in
                            Button {
                                dismiss()
                                DispatchQueue.main.async { command.run() }
                            } label: {
                                resultRow(symbol: command.symbol, scope: "Command",
                                          title: command.title, detail: command.detail)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !model.query.isEmpty && matchingCommands.isEmpty && model.results.isEmpty && model.indexedDocuments.isEmpty && !model.indexing {
                        Text("No matches in searchable project files or available commands. Some binary or very large files may not be indexed.")
                            .foregroundColor(palette.textDim).padding(16)
                    }
                }
            }
            .background(palette.bg)
        }
        .frame(minWidth: 620, minHeight: 420)
        .task(id: project.searchRootsKey) {
            await model.rebuild(root: fileTree.rootNode?.url, linked: project.linkedFolders)
        }
        .onAppear { searchFocused = true }
        .onReceive(project.$database) { database in
            if !model.query.isEmpty { model.scheduleSearch(documentDatabasePath: database?.dbPath) }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .uiFont(size: 10, weight: .semibold)
            .foregroundColor(palette.textDim)
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
    }

    private func searchResult(_ result: ProjectSearchResult) -> some View {
        Button { open(result) } label: {
            resultRow(symbol: result.scope == .file ? "doc" : "text.magnifyingglass",
                      scope: result.scope.rawValue, title: result.title,
                      detail: (result.path ?? "") + (result.page.map { " · page \($0)" } ?? result.line.map { ":\($0)" } ?? "") +
                          (result.snippet.map { " · \($0)" } ?? ""))
        }
        .buttonStyle(.plain)
    }

    private func resultRow(symbol: String, scope: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundColor(palette.blue)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).uiFont(size: 12, weight: .medium)
                    Spacer()
                    Text(scope).uiFont(size: 10).foregroundColor(palette.textDim)
                }
                Text(detail).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func open(_ result: ProjectSearchResult) {
        model.startOpen(result, root: fileTree.rootNode?.url, linked: project.linkedFolders) { opening in
            if let window { opening.show(in: window) }
            dismiss()
        }
    }

    private struct SearchCommand: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let detail: String
        let run: () -> Void
    }

    private var matchingCommands: [SearchCommand] {
        var commands = [
            SearchCommand(id: "files", title: "Show Files", symbol: "folder", detail: "Workspace", run: {
                layout.workspaceArea = .files
            }),
            SearchCommand(id: "open-folder", title: "Open Folder…", symbol: "folder.badge.plus", detail: "File menu", run: {
                NotificationCenter.default.post(name: .showFolderPicker, object: nil)
            }),
            SearchCommand(id: "new-project", title: "New Project…", symbol: "plus.square", detail: "File menu", run: {
                requests.newProject = NewProjectRequest()
            }),
            SearchCommand(id: "theme", title: "Theme…", symbol: "paintpalette", detail: "⌘⇧T", run: {
                theme.showsPicker = true
            }),
            SearchCommand(id: "settings", title: "DDE Settings…", symbol: "gearshape", detail: "⌘⇧,", run: {
                window?.showSettings()
            })
        ]
        if fileTree.rootNode != nil {
            commands += [
                SearchCommand(id: "map", title: "Show Project Map", symbol: "viewfinder", detail: "⌘4", run: {
                    codeXRay.openArchitecture()
                }),
                SearchCommand(id: "work", title: "Show Work", symbol: "checklist", detail: "Workspace", run: {
                    layout.workspaceArea = .work
                }),
                SearchCommand(id: "terminal", title: "Open Terminal", symbol: "terminal", detail: "⌘3", run: {
                    chrome.agentsVisible = true
                }),
                SearchCommand(id: "new-feature", title: "New Feature…", symbol: "plus.square", detail: "Work", run: {
                    requests.intake = IntakeRequest(kind: .feature)
                }),
                SearchCommand(id: "new-bug", title: "New Bug…", symbol: "ladybug", detail: "Work", run: {
                    requests.intake = IntakeRequest(kind: .bug)
                }),
                SearchCommand(id: "deployments", title: "Show Build & Deployment", symbol: "server.rack", detail: "Where the project runs", run: {
                    window?.openTool(.deployments)
                }),
                SearchCommand(id: "git", title: "Show Git", symbol: "arrow.triangle.branch", detail: "Work", run: {
                    window?.openTool(.git)
                })
            ]
            if git.isGitRepo {
                commands += [
                    SearchCommand(id: "pull", title: "Git Pull", symbol: "arrow.down", detail: "Work · Git", run: {
                        git.startPull()
                    }),
                    SearchCommand(id: "push", title: "Git Push", symbol: "arrow.up", detail: "Work · Git", run: {
                        git.startPush()
                    })
                ]
            }
        }
        if tabs.activeTab?.isFileBacked == true {
            commands += [
                SearchCommand(id: "save", title: "Save", symbol: "square.and.arrow.down", detail: "⌘S", run: {
                    tabs.saveActiveFile()
                }),
                SearchCommand(id: "pdf", title: "Export PDF…", symbol: "doc.richtext", detail: "⌘E", run: {
                    if let window { NotificationCenter.default.post(.exportPDFRequested, for: window) }
                })
            ]
        }
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? commands : commands.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
}
