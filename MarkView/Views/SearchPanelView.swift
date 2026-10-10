import SwiftUI

/// The Search tab of the right panel: the whole project (file names and the text of any file, plus the
/// names inside archives), or the meaning search of the Markdown documents.
struct WorkspaceSearchView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @AppStorage("search.panelMode") private var mode = Mode.project.rawValue

    enum Mode: String, CaseIterable, Identifiable {
        case project = "Project"
        case documents = "Documents"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .help("Project: file names and text of any file. Documents: meaning search of Markdown.")
            Divider().background(VSDark.border)
            if mode == Mode.documents.rawValue {
                DocumentSearchView().environmentObject(workspaceManager)
            } else {
                ProjectSearchPanel().environmentObject(workspaceManager)
            }
        }
        .background(VSDark.bgSidebar)
    }
}

/// File names and contents of the project, found as you type (the index is the one ⌘⇧K uses).
struct ProjectSearchPanel: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @StateObject private var model = SharedSearchModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").uiFont(size: 11).foregroundColor(VSDark.textDim)
                TextField("Search files and text…", text: $model.query)
                    .textFieldStyle(.plain).uiFont(size: 11).foregroundColor(VSDark.text)
                    .onChange(of: model.query) { _ in Task { await model.search() } }
                if model.indexing { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12) }
                if !model.query.isEmpty {
                    Button { model.query = ""; Task { await model.search() } } label: {
                        Image(systemName: "xmark.circle.fill").uiFont(size: 10).foregroundColor(VSDark.textDim)
                    }.buttonStyle(.plain)
                }
                Button { Task { await model.rebuild(root: workspaceManager.rootNode?.url, linked: workspaceManager.linkedFolders) } } label: {
                    Image(systemName: "arrow.clockwise").uiFont(size: 10).foregroundColor(VSDark.textDim)
                }.buttonStyle(.plain).help("Refresh the search index")
            }
            .padding(8).background(VSDark.bgInput)
            status
            if let error = model.error {
                Text(error).uiFont(size: 10).foregroundColor(VSDark.orange).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            results
        }
        .task(id: workspaceManager.searchRootsKey) {
            await model.rebuild(root: workspaceManager.rootNode?.url, linked: workspaceManager.linkedFolders)
        }
    }

    private var status: some View {
        HStack {
            if model.indexing {
                Text("Indexing · \(model.scanned) files scanned")
            } else if let date = model.indexedAt {
                Text("Index updated \(date.formatted(date: .omitted, time: .shortened)) · refresh for outside changes")
            } else {
                Text("Open a project to search it")
            }
            Spacer()
        }
        .uiFont(size: 9).foregroundColor(VSDark.textDim).padding(.horizontal, 8).padding(.vertical, 3)
    }

    @ViewBuilder private var results: some View {
        let files = model.results.filter { $0.scope == .file }
        let content = model.results.filter { $0.scope == .content }
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            placeholder("Type to search file names and the text of every file in the project, and file names inside zip archives.")
        } else if files.isEmpty && content.isEmpty && !model.indexing {
            placeholder("No results")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !files.isEmpty {
                        header("Files (\(files.count))")
                        ForEach(files) { row($0) }
                    }
                    if !content.isEmpty {
                        header("Text (\(content.count))")
                        ForEach(content) { row($0) }
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack { Spacer(); Text(text).uiFont(size: 11).foregroundColor(VSDark.textDim).multilineTextAlignment(.center).padding(16); Spacer() }
            .frame(maxWidth: .infinity)
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }

    private func row(_ result: ProjectSearchResult) -> some View {
        let inArchive = result.path?.contains(ProjectSearchIndex.archiveSeparator) == true
        return Button { Task { _ = await model.open(result, in: workspaceManager) } } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: inArchive ? "archivebox" : result.scope == .file ? "doc" : "text.magnifyingglass")
                        .uiFont(size: 9).foregroundColor(VSDark.blue)
                    Text(result.title).uiFont(size: 11, weight: .medium).foregroundColor(VSDark.blue).lineLimit(1)
                    if let line = result.line { Text(":\(line)").uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim) }
                }
                if let snippet = result.snippet {
                    Text(snippet).uiFont(size: 10).foregroundColor(VSDark.text).lineLimit(2)
                }
                Text(result.path ?? "").uiFont(size: 9).foregroundColor(VSDark.textDim).lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, 10).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
