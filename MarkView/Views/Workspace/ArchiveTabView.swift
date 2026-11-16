import AppKit
import SwiftUI
#if canImport(MarkViewCore)
import MarkViewCore
#endif

struct ArchiveTabView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var fileTree: WorkspaceFileTreeStore
    @StateObject private var model: ArchiveModel

    init(url: URL) { _model = StateObject(wrappedValue: ArchiveModel(url: url)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(palette.border)
            switch model.phase {
            case .loading:
                centered { ProgressView().controlSize(.small); Text("Reading the archive…").uiFont(size: 11).foregroundColor(palette.textDim) }
            case .failed(let message):
                centered {
                    Image(systemName: "exclamationmark.triangle").uiFont(size: 22).foregroundColor(palette.orange)
                    Text(message).uiFont(size: 11).foregroundColor(palette.text).multilineTextAlignment(.center).textSelection(.enabled)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
                }
            case .loaded:
                banner
                list
            }
        }
        .background(palette.bg)
        .task(id: model.url) { await model.load() }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity).padding(24)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "archivebox").uiFont(size: 11).foregroundColor(palette.yellow)
                Text(model.url.lastPathComponent).uiFont(size: 11, weight: .semibold).foregroundColor(palette.text).lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let busy = model.busy {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    Text(busy).uiFont(size: 10).foregroundColor(palette.textDim)
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
                    .uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").uiFont(size: 9).foregroundColor(palette.textDim)
                    TextField("Filter files", text: $model.filter).textFieldStyle(.plain).uiFont(size: 11)
                    if !model.filter.isEmpty {
                        Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill").uiFont(size: 10) }
                            .buttonStyle(.plain).foregroundColor(palette.textDim)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4).background(palette.bgInput).cornerRadius(5)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(palette.bgSidebar)
    }

    @ViewBuilder private var banner: some View {
        if let error = model.error {
            bannerRow(error, icon: "exclamationmark.triangle.fill", color: palette.red) { model.error = nil }
        } else if let notice = model.notice {
            bannerRow(notice, icon: "checkmark.circle.fill", color: palette.green, action: { model.notice = nil }, show: model.showExtracted)
        } else if model.unsafeCount > 0 {
            bannerRow("\(model.unsafeCount) entries have paths that leave the folder (../ or absolute). They cannot be opened, and the archive cannot be extracted.",
                      icon: "exclamationmark.shield.fill", color: palette.orange, action: nil)
        }
    }

    private func bannerRow(_ text: String, icon: String, color: Color, action: (() -> Void)?, show: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).uiFont(size: 10).foregroundColor(color)
            Text(text).uiFont(size: 10).foregroundColor(palette.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let show { Button("Show") { show() }.buttonStyle(.plain).foregroundColor(palette.blue).uiFont(size: 10) }
            if let action {
                Button(action: action) { Image(systemName: "xmark").uiFont(size: 8) }.buttonStyle(.plain).foregroundColor(palette.textDim)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5).background(color.opacity(0.12))
    }

    private var list: some View { ArchiveEntriesList(model: model) }

    private func extract(into parent: URL?) {
        model.extract(into: parent) { _ in fileTree.refresh() }
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
    @Environment(\.palette) private var palette
    @Environment(\.windowCommands) private var window
    @ObservedObject var model: ArchiveModel
    var compact = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in rowView(row) }
                if model.rows.isEmpty {
                    Text(model.filter.isEmpty ? "The archive is empty." : "No file matches.")
                        .uiFont(size: 11).foregroundColor(palette.textDim).padding(16)
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
                Image(systemName: row.expanded ? "chevron.down" : "chevron.right").uiFont(size: 8).foregroundColor(palette.textDim).frame(width: 10)
                Image(systemName: "folder.fill").uiFont(size: 11).foregroundColor(palette.yellow)
            } else {
                Color.clear.frame(width: 10, height: 1)
                Image(systemName: entry.isSymlink ? "link" : "doc").uiFont(size: 11).foregroundColor(palette.textDim)
            }
            Text(row.title).uiFont(size: 11).foregroundColor(entry.isSafe ? palette.text : palette.orange)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12) }
            if !row.isDirectory {
                Text(byteString(entry.size)).uiFont(size: 10).foregroundColor(palette.textDim)
            }
            if !compact {
                Text(entry.modified).uiFont(size: 10).foregroundColor(palette.textDim).frame(width: 96, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.isDirectory { model.toggle(entry.path) }
            else if !entry.isSymlink { model.open(entry) { window?.openFile($0) } }
        }
        .help(entry.isSafe ? entry.path : "\(entry.path) — leaves the folder, never read or written")
    }


    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
