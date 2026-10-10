import AppKit
import SwiftUI

/// What an archive tab shows: its entries as a tree, searchable; a click opens a file from it in a
/// viewer (a temporary copy), and the archive can be unpacked next to itself or elsewhere.
@MainActor
final class ArchiveModel: ObservableObject {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    struct Row: Identifiable {
        let id: String
        let entry: ArchiveEntry
        let depth: Int
        /// The label: the name in the tree, the whole path in a search.
        let title: String
        let isDirectory: Bool
        let expanded: Bool
    }

    let url: URL
    @Published private(set) var phase = Phase.loading
    @Published private(set) var entries: [ArchiveEntry] = []
    @Published private(set) var rows: [Row] = []
    @Published var filter = "" { didSet { rebuild() } }
    @Published private(set) var expanded: Set<String> = []
    /// The entry being unpacked for a look, and a line about the last extraction.
    @Published private(set) var opening: String?
    @Published private(set) var busy: String?
    @Published var notice: String?
    @Published var error: String?
    private(set) var extractedTo: URL?

    init(url: URL) { self.url = url }

    var files: Int { entries.filter { !$0.isDirectory }.count }
    var folders: Int { entries.filter(\.isDirectory).count }
    var unpackedBytes: Int64 { entries.reduce(0) { $0 + $1.size } }
    var unsafeCount: Int { entries.filter { !$0.isSafe }.count }
    var archiveBytes: Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    func load() async {
        phase = .loading
        let url = url
        let result = await Task.detached(priority: .userInitiated) { Result { try Archive.list(url) } }.value
        switch result {
        case .success(let list):
            entries = list
            // Folders the archive does not list on their own still need a row.
            expanded = Set(topLevelFolders(list))
            phase = .loaded
            rebuild()
        case .failure(let failure):
            phase = .failed(failure.localizedDescription)
        }
    }

    private func topLevelFolders(_ list: [ArchiveEntry]) -> [String] {
        // A single top folder (most archives) opens at once; otherwise everything starts closed.
        let tops = Set(list.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        return tops.count == 1 && list.contains(where: { $0.path.contains("/") }) ? Array(tops) : []
    }

    func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        rebuild()
    }

    private func rebuild() {
        guard phase == .loaded else { return }
        let query = filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            rows = entries.filter { !$0.isDirectory && $0.path.localizedCaseInsensitiveContains(query) }.prefix(2000).map {
                Row(id: $0.path, entry: $0, depth: 0, title: $0.path, isDirectory: false, expanded: false)
            }
            return
        }
        // Directories, listed or implied, and files, in path order with folders before files at each level.
        var folders: [String: ArchiveEntry] = [:]
        var children: [String: [ArchiveEntry]] = [:]
        for entry in entries {
            let parts = entry.path.split(separator: "/").map(String.init)
            for depth in 1..<max(parts.count, 1) {
                let folder = parts[..<depth].joined(separator: "/")
                if folders[folder] == nil {
                    folders[folder] = ArchiveEntry(path: folder, isDirectory: true, isSymlink: false, size: 0, modified: "")
                    children[parent(of: folder), default: []].append(folders[folder]!)
                }
            }
            if entry.isDirectory {
                if folders[entry.path] == nil { folders[entry.path] = entry; children[parent(of: entry.path), default: []].append(entry) }
            } else {
                children[parent(of: entry.path), default: []].append(entry)
            }
        }
        var out: [Row] = []
        func walk(_ folder: String, depth: Int) {
            let list = (children[folder] ?? []).sorted {
                $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            for entry in list {
                let open = entry.isDirectory && expanded.contains(entry.path)
                out.append(Row(id: entry.path, entry: entry, depth: depth, title: entry.name, isDirectory: entry.isDirectory, expanded: open))
                if open { walk(entry.path, depth: depth + 1) }
            }
        }
        walk("", depth: 0)
        rows = out
    }

    private func parent(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// Unpack one file to the cache and hand it to `open` (a viewer).
    func open(_ entry: ArchiveEntry, _ open: @escaping (URL) -> Void) {
        guard opening == nil else { return }
        opening = entry.path
        error = nil
        let url = url
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try Archive.extractEntry(entry, from: url) } }.value
            opening = nil
            switch result {
            case .success(let copy): open(copy)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    /// Unpack everything into a new folder; `parent` nil = next to the archive.
    func extract(into parent: URL?, done: @escaping (URL) -> Void) {
        guard busy == nil else { return }
        busy = "Extracting \(files) files…"
        error = nil
        notice = nil
        let url = url, list = entries
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                let folder = Archive.uniqueFolder(for: url, in: parent)
                return Result { try Archive.extractAll(url, to: folder, entries: list); return folder }
            }.value
            busy = nil
            switch result {
            case .success(let folder):
                extractedTo = folder
                notice = "Extracted \(files) files to \(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
                done(folder)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    func showExtracted() {
        if let extractedTo { NSWorkspace.shared.activateFileViewerSelecting([extractedTo]) }
    }
}

struct ArchiveTabView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @StateObject private var model: ArchiveModel

    init(url: URL) { _model = StateObject(wrappedValue: ArchiveModel(url: url)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(VSDark.border)
            switch model.phase {
            case .loading:
                centered { ProgressView().controlSize(.small); Text("Reading the archive…").uiFont(size: 11).foregroundColor(VSDark.textDim) }
            case .failed(let message):
                centered {
                    Image(systemName: "exclamationmark.triangle").uiFont(size: 22).foregroundColor(VSDark.orange)
                    Text(message).uiFont(size: 11).foregroundColor(VSDark.text).multilineTextAlignment(.center).textSelection(.enabled)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
                }
            case .loaded:
                banner
                list
            }
        }
        .background(VSDark.bg)
        .task(id: model.url) { await model.load() }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity).padding(24)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "archivebox").uiFont(size: 11).foregroundColor(VSDark.yellow)
                Text(model.url.lastPathComponent).uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text).lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let busy = model.busy {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    Text(busy).uiFont(size: 10).foregroundColor(VSDark.textDim)
                }
                Button("Extract Here") { extract(into: nil) }
                    .help("Unpack into a new folder next to the archive")
                Button("Extract to…") { chooseAndExtract() }
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.url]) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
            }
            .controlSize(.small)
            if model.phase == .loaded {
                Text("\(model.files) files · \(model.folders) folders · \(byteString(model.unpackedBytes)) unpacked · \(byteString(model.archiveBytes)) archive")
                    .uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").uiFont(size: 9).foregroundColor(VSDark.textDim)
                    TextField("Filter files", text: $model.filter).textFieldStyle(.plain).uiFont(size: 11)
                    if !model.filter.isEmpty {
                        Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill").uiFont(size: 10) }
                            .buttonStyle(.plain).foregroundColor(VSDark.textDim)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4).background(VSDark.bgInput).cornerRadius(5)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(VSDark.bgSidebar)
    }

    @ViewBuilder private var banner: some View {
        if let error = model.error {
            bannerRow(error, icon: "exclamationmark.triangle.fill", color: VSDark.red) { model.error = nil }
        } else if let notice = model.notice {
            bannerRow(notice, icon: "checkmark.circle.fill", color: VSDark.green, action: { model.notice = nil }, show: model.showExtracted)
        } else if model.unsafeCount > 0 {
            bannerRow("\(model.unsafeCount) entries have paths that leave the folder (../ or absolute). They cannot be opened, and the archive cannot be extracted.",
                      icon: "exclamationmark.shield.fill", color: VSDark.orange, action: nil)
        }
    }

    private func bannerRow(_ text: String, icon: String, color: Color, action: (() -> Void)?, show: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).uiFont(size: 10).foregroundColor(color)
            Text(text).uiFont(size: 10).foregroundColor(VSDark.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let show { Button("Show") { show() }.buttonStyle(.plain).foregroundColor(VSDark.blue).uiFont(size: 10) }
            if let action {
                Button(action: action) { Image(systemName: "xmark").uiFont(size: 8) }.buttonStyle(.plain).foregroundColor(VSDark.textDim)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5).background(color.opacity(0.12))
    }

    private var list: some View { ArchiveEntriesList(model: model) }

    private func extract(into parent: URL?) {
        model.extract(into: parent) { _ in workspaceManager.refreshFileTree() }
    }

    private func chooseAndExtract() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Extract Here"
        panel.message = "A new folder named after the archive is made inside the folder you choose."
        panel.directoryURL = model.url.deletingLastPathComponent()
        if panel.runModal() == .OK, let folder = panel.url { extract(into: folder) }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The rows of an archive: folders open and close, a file opens in its viewer. `compact` drops the date column
/// (the Contents panel is narrow).
struct ArchiveEntriesList: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @ObservedObject var model: ArchiveModel
    var compact = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in rowView(row) }
                if model.rows.isEmpty {
                    Text(model.filter.isEmpty ? "The archive is empty." : "No file matches.")
                        .uiFont(size: 11).foregroundColor(VSDark.textDim).padding(16)
                }
            }
        }
    }

    private func rowView(_ row: ArchiveModel.Row) -> some View {
        let entry = row.entry
        let busy = model.opening == entry.path
        return HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            if row.isDirectory {
                Image(systemName: row.expanded ? "chevron.down" : "chevron.right").uiFont(size: 8).foregroundColor(VSDark.textDim).frame(width: 10)
                Image(systemName: "folder.fill").uiFont(size: 11).foregroundColor(VSDark.yellow)
            } else {
                Color.clear.frame(width: 10, height: 1)
                Image(systemName: entry.isSymlink ? "link" : "doc").uiFont(size: 11).foregroundColor(VSDark.textDim)
            }
            Text(row.title).uiFont(size: 11).foregroundColor(entry.isSafe ? VSDark.text : VSDark.orange)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12) }
            if !row.isDirectory {
                Text(byteString(entry.size)).uiFont(size: 10).foregroundColor(VSDark.textDim)
            }
            if !compact {
                Text(entry.modified).uiFont(size: 10).foregroundColor(VSDark.textDim).frame(width: 96, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.isDirectory { model.toggle(entry.path) }
            else if !entry.isSymlink { model.open(entry) { workspaceManager.openFile($0) } }
        }
        .help(entry.isSafe ? entry.path : "\(entry.path) — leaves the folder, never read or written")
    }


    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
