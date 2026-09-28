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

    func rebuild(root: URL?) async {
        guard let root else { results = []; return }
        indexing = true
        scanned = 0
        error = nil
        do {
            try await index.rebuild(root: root) { [weak self] count in
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
                Button { Task { await model.rebuild(root: workspaceManager.rootNode?.url) } } label: {
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
        .task(id: workspaceManager.rootNode?.url) {
            await model.rebuild(root: workspaceManager.rootNode?.url)
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
        guard let root = workspaceManager.rootNode?.url, let path = result.path else { return }
        Task {
            let url = root.appendingPathComponent(path)
            let valid = await Task.detached { () -> Bool in
                let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                return resolved.path.hasPrefix(base) && FileManager.default.fileExists(atPath: resolved.path)
            }.value
            guard valid else {
                model.error = "This result is missing or no longer inside the project. Refreshing search."
                await model.rebuild(root: root)
                return
            }
            workspaceManager.openFile(url)
            if result.scope == .content {
                let query = model.query
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(name: .scrollToText, object: query)
                }
            }
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
