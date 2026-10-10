import SwiftUI
import WebKit

/// The Contents tab of the right panel: what the open tab holds, whatever it is. A Markdown file shows
/// its headings, an HTML file its page, an archive its entries, and every file its facts (kind, size,
/// dates, text counts, image size).
struct ContentsPanelView<Headings: View>: View {
    let tab: OpenTab
    @ViewBuilder let headings: () -> Headings
    @AppStorage("contents.infoExpanded") private var infoExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            switch tab.kind {
            case .archive:
                ArchiveContentsPanel(url: tab.url).id(tab.url)
            case .file where FileType.isHTML(tab.url):
                HTMLPreviewView(url: tab.url, token: tab.originalContent.hashValue).id(tab.url)
                Divider().background(VSDark.border)
                info
            case .file where !tab.headings.isEmpty:
                headings()
                Divider().background(VSDark.border)
                info
            case .file, .image, .data:
                if case .image = tab.kind { ImageThumbnail(url: tab.url).id(tab.url) }
                else if case .file = tab.kind, tab.fileType == .markdown { placeholder("No headings") }
                ScrollView { FileInfoRows(url: tab.url, revision: tab.dataRevision).padding(10) }
            default:
                placeholder("Nothing to show for this tab")
            }
        }
        .background(VSDark.bgSidebar)
    }

    private var info: some View {
        VStack(spacing: 0) {
            Button { infoExpanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: infoExpanded ? "chevron.down" : "chevron.right").uiFont(size: 8).frame(width: 10)
                    Text("FILE").uiFont(size: 9, weight: .semibold)
                    Spacer()
                }.foregroundColor(VSDark.textDim).padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if infoExpanded {
                ScrollView { FileInfoRows(url: tab.url, revision: tab.originalContent.hashValue).padding(.horizontal, 10).padding(.bottom, 8) }
                    .frame(maxHeight: 170)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).uiFont(size: 11).foregroundColor(VSDark.textDim).frame(maxWidth: .infinity).padding(.vertical, 14)
    }
}

/// The facts of a file as label and value rows; read off the main thread, again when `revision` changes.
struct FileInfoRows: View {
    let url: URL
    var revision = 0
    @State private var info: FileInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let info {
                ForEach(info.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.label).uiFont(size: 10).foregroundColor(VSDark.textDim).frame(width: 70, alignment: .leading)
                        Text(row.value).uiFont(size: 10).foregroundColor(VSDark.text).textSelection(.enabled)
                            .lineLimit(row.label == "Path" ? 4 : 2).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(url.path)|\(revision)") {
            let url = url
            info = await Task.detached(priority: .utility) { FileInfo.load(url) }.value
        }
    }
}

/// A picture, scaled to the panel.
private struct ImageThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 220).padding(10)
            }
        }
        .task { image = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value }
    }
}

/// The page of an HTML file, without scripts (a preview: the browser tab runs it for real).
struct HTMLPreviewView: NSViewRepresentable {
    let url: URL
    /// Changes when the file is saved: the page loads again.
    let token: Int

    final class Coordinator { var loaded: (URL, Int)? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if let loaded = context.coordinator.loaded, loaded == (url, token) { return }
        context.coordinator.loaded = (url, token)
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}

/// An archive in the panel: facts, a filter and the entries (a click opens the file).
struct ArchiveContentsPanel: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @StateObject private var model: ArchiveModel

    init(url: URL) { _model = StateObject(wrappedValue: ArchiveModel(url: url)) }

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .loading:
                Spacer(); ProgressView().controlSize(.small); Spacer()
            case .failed(let message):
                Spacer(); Text(message).uiFont(size: 10).foregroundColor(VSDark.orange).padding(12); Spacer()
            case .loaded:
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.files) files · \(model.folders) folders")
                        .uiFont(size: 10, weight: .semibold).foregroundColor(VSDark.text)
                    Text("\(byteString(model.unpackedBytes)) unpacked · \(byteString(model.archiveBytes)) archive")
                        .uiFont(size: 10).foregroundColor(VSDark.textDim)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").uiFont(size: 9).foregroundColor(VSDark.textDim)
                        TextField("Filter files", text: $model.filter).textFieldStyle(.plain).uiFont(size: 10)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3).background(VSDark.bgInput).cornerRadius(4)
                    if let error = model.error {
                        Text(error).uiFont(size: 9).foregroundColor(VSDark.red).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                Divider().background(VSDark.border)
                ArchiveEntriesList(model: model, compact: true)
                Divider().background(VSDark.border)
                ScrollView { FileInfoRows(url: model.url).padding(10) }.frame(maxHeight: 130)
            }
        }
        .task(id: model.url) { await model.load() }
    }

    private func byteString(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
