import SwiftUI
import AppKit

@MainActor
final class SharedSearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [ProjectSearchResult] = []
    @Published var indexing = false
    @Published var scanned = 0
    @Published var indexedAt: Date?
    @Published var error: String?

    private let index = ProjectSearchIndex()
    /// The roots of the last rebuild: results are resolved against them.
    private(set) var roots: [ProjectSearchRoot] = []

    func rebuild(root: URL?, linked: [LinkedFolder] = []) async {
        guard let root else { results = []; roots = []; return }
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

    /// Open a result: a file (at its line, or at the text found), or a file from inside an archive
    /// (its temporary copy). False, with `error` set, when it cannot be opened.
    func open(_ result: ProjectSearchResult, in workspaceManager: WorkspaceManager) async -> Bool {
        guard let root = workspaceManager.rootNode?.url, let path = result.path else { return false }
        let roots = self.roots
        if let range = path.range(of: ProjectSearchIndex.archiveSeparator) {
            let entryPath = String(path[range.upperBound...])
            guard let archiveURL = ProjectSearchRoot.url(for: String(path[..<range.lowerBound]), in: roots) else { return false }
            let opened = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    guard let entry = try Archive.list(archiveURL).first(where: { $0.path == entryPath }) else { throw ArchiveError.notFound(entryPath) }
                    return try Archive.extractEntry(entry, from: archiveURL)
                }
            }.value
            switch opened {
            case .success(let copy): workspaceManager.openFile(copy); return true
            case .failure(let failure): error = failure.localizedDescription; return false
            }
        }
        guard let url = ProjectSearchRoot.url(for: path, in: roots) else { return false }
        let linked = workspaceManager.linkedFolders
        // The result must still be under a root of the search (the project or a linked folder).
        let valid = await Task.detached { () -> Bool in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let bases = roots.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
            return bases.contains { resolved.path.hasPrefix($0) } && FileManager.default.fileExists(atPath: resolved.path)
        }.value
        guard valid else {
            error = "This result is missing or no longer inside the project. Refreshing search."
            await rebuild(root: root, linked: linked)
            return false
        }
        if result.scope == .content, let line = result.line, !FileType.markdownExtensions.contains(url.pathExtension.lowercased()) {
            workspaceManager.openFile(url, line: line)
        } else {
            workspaceManager.openFile(url)
            if result.scope == .content {
                let text = query
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(name: .scrollToText, object: text)
                }
            }
        }
        return true
    }

    func search() async {
        let searched = query
        let found = await index.search(searched)
        if query == searched { results = found }
    }
}

struct SharedSearchView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SharedSearchModel()
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(VSDark.textDim)
                TextField("Find files, text, or commands", text: $model.query)
                    .textFieldStyle(.plain)
                    .uiFont(size: 16)
                    .focused($searchFocused)
                    .onChange(of: model.query) { _ in Task { await model.search() } }
                if model.indexing { ProgressView().controlSize(.small) }
                Button { Task { await model.rebuild(root: workspaceManager.rootNode?.url, linked: workspaceManager.linkedFolders) } } label: {
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
                Text("File · Content · Command")
            }
            .uiFont(size: 10)
            .foregroundColor(VSDark.textDim)
            .padding(.horizontal, 14).padding(.vertical, 6)
            if let error = model.error {
                Text(error).uiFont(size: 11).foregroundColor(VSDark.orange).padding(8)
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
                    if !model.query.isEmpty && matchingCommands.isEmpty && model.results.isEmpty && !model.indexing {
                        Text("No matches in supported project files or available commands.")
                            .foregroundColor(VSDark.textDim).padding(16)
                    }
                }
            }
            .background(VSDark.bg)
        }
        .frame(minWidth: 620, minHeight: 420)
        .task(id: workspaceManager.searchRootsKey) {
            await model.rebuild(root: workspaceManager.rootNode?.url, linked: workspaceManager.linkedFolders)
        }
        .onAppear { searchFocused = true }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .uiFont(size: 10, weight: .semibold)
            .foregroundColor(VSDark.textDim)
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
    }

    private func searchResult(_ result: ProjectSearchResult) -> some View {
        Button { open(result) } label: {
            resultRow(symbol: result.scope == .file ? "doc" : "text.magnifyingglass",
                      scope: result.scope.rawValue, title: result.title,
                      detail: (result.path ?? "") + (result.line.map { ":\($0)" } ?? "") +
                          (result.snippet.map { " · \($0)" } ?? ""))
        }
        .buttonStyle(.plain)
    }

    private func resultRow(symbol: String, scope: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundColor(VSDark.blue)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).uiFont(size: 12, weight: .medium)
                    Spacer()
                    Text(scope).uiFont(size: 10).foregroundColor(VSDark.textDim)
                }
                Text(detail).uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func open(_ result: ProjectSearchResult) {
        Task { if await model.open(result, in: workspaceManager) { dismiss() } }
    }

    private struct SearchCommand: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let detail: String
        let run: () -> Void
    }

    private var matchingCommands: [SearchCommand] {
        let manager = workspaceManager
        var commands = [
            SearchCommand(id: "files", title: "Show Files", symbol: "folder", detail: "Workspace", run: {
                manager.layout.workspaceArea = .files
            }),
            SearchCommand(id: "open-folder", title: "Open Folder…", symbol: "folder.badge.plus", detail: "File menu", run: {
                NotificationCenter.default.post(name: .showFolderPicker, object: nil)
            }),
            SearchCommand(id: "new-project", title: "New Project…", symbol: "plus.square", detail: "File menu", run: {
                manager.newProject = NewProjectRequest()
            }),
            SearchCommand(id: "theme", title: "Toggle Theme", symbol: "circle.lefthalf.filled", detail: "⌘⇧T", run: {
                themeManager.toggleTheme()
            }),
            SearchCommand(id: "settings", title: "DDE Settings…", symbol: "gearshape", detail: "⌘⇧,", run: {
                DDESettingsWindow.show(workspace: manager)
            })
        ]
        if manager.rootNode != nil {
            commands += [
                SearchCommand(id: "map", title: "Show Project Map", symbol: "viewfinder", detail: "⌘4", run: {
                    manager.openArchitecture()
                }),
                SearchCommand(id: "work", title: "Show Work", symbol: "checklist", detail: "Workspace", run: {
                    manager.layout.workspaceArea = .work
                }),
                SearchCommand(id: "terminal", title: "Open Terminal", symbol: "terminal", detail: "⌘3", run: {
                    manager.showAIConsole()
                }),
                SearchCommand(id: "new-feature", title: "New Feature…", symbol: "plus.square", detail: "Work", run: {
                    manager.intake = IntakeRequest(kind: .feature)
                }),
                SearchCommand(id: "new-bug", title: "New Bug…", symbol: "ladybug", detail: "Work", run: {
                    manager.intake = IntakeRequest(kind: .bug)
                }),
                SearchCommand(id: "deployments", title: "Show Deployments", symbol: "server.rack", detail: "Where the project runs", run: {
                    manager.openDeployments()
                }),
                SearchCommand(id: "git", title: "Show Git", symbol: "arrow.triangle.branch", detail: "Work", run: {
                    manager.layout.workspaceArea = .work
                    manager.layout.workSection = .git
                })
            ]
            if manager.gitClient.isGitRepo {
                commands += [
                    SearchCommand(id: "pull", title: "Git Pull", symbol: "arrow.down", detail: "Work · Git", run: {
                        Task { await manager.gitClient.pull() }
                    }),
                    SearchCommand(id: "push", title: "Git Push", symbol: "arrow.up", detail: "Work · Git", run: {
                        Task { await manager.gitClient.push() }
                    })
                ]
            }
        }
        if manager.activeTab?.isFileBacked == true {
            commands += [
                SearchCommand(id: "save", title: "Save", symbol: "square.and.arrow.down", detail: "⌘S", run: {
                    manager.saveActiveFile()
                }),
                SearchCommand(id: "pdf", title: "Export PDF…", symbol: "doc.richtext", detail: "⌘E", run: {
                    NotificationCenter.default.post(name: .exportPDFRequested, object: nil)
                })
            ]
        }
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? commands : commands.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
}
