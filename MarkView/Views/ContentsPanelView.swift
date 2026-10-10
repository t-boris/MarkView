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
            case .file where StructureOutline.supports(tab.url):
                StructureOutlineList(url: tab.url, text: tab.content)
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
            case .browser(let session):
                BrowserContentsPanel(session: session).id(session.id)
            case .prototype(let session):
                PrototypeContentsPanel(session: session).id(session.id)
            default:
                TabFactsPanel(tab: tab)
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

/// The keys of a JSON or YAML file as a tree; a click jumps to the key in the file.
struct StructureOutlineList: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    let url: URL
    /// The text as edited, so the outline follows typing.
    let text: String
    @State private var items: [StructureOutline.Item] = []
    @State private var filter = ""
    @State private var computing = true

    var body: some View {
        VStack(spacing: 0) {
            if items.count > 12 || !filter.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").uiFont(size: 9).foregroundColor(VSDark.textDim)
                    TextField("Filter keys", text: $filter).textFieldStyle(.plain).uiFont(size: 10)
                }
                .padding(.horizontal, 6).padding(.vertical, 3).background(VSDark.bgInput).cornerRadius(4).padding(8)
            }
            if shown.isEmpty {
                Spacer()
                Text(computing ? "Reading the structure…" : items.isEmpty ? "No keys found" : "No key matches")
                    .uiFont(size: 11).foregroundColor(VSDark.textDim)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { item in
                            Button { workspaceManager.revealStructure(url, item: item) } label: {
                                HStack(spacing: 4) {
                                    Color.clear.frame(width: CGFloat(filter.isEmpty ? item.depth : 0) * 12, height: 1)
                                    Circle().fill(VSDark.textDim.opacity(0.4)).frame(width: 5, height: 5)
                                    Text(item.title).uiFont(size: 11, design: item.title.hasPrefix("[") ? .monospaced : .default)
                                        .foregroundColor(VSDark.text).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Text("\(item.line)").uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim)
                                }
                                .padding(.vertical, 2).padding(.horizontal, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task(id: text.hashValue) {
            computing = true
            let url = url, text = text
            items = await Task.detached(priority: .userInitiated) { StructureOutline.items(for: url, text: text) }.value
            computing = false
        }
    }

    private var shown: [StructureOutline.Item] {
        filter.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }
}

/// A label and a value, in the style of the file facts.
private struct FactRows: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.0).uiFont(size: 10).foregroundColor(VSDark.textDim).frame(width: 70, alignment: .leading)
                    Text(row.1).uiFont(size: 10).foregroundColor(VSDark.text).textSelection(.enabled)
                        .lineLimit(4).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a terminal, GitHub, X-Ray or Insight tab is: facts only (these tabs have no outline of their own).
struct TabFactsPanel: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    let tab: OpenTab

    var body: some View {
        ScrollView { FactRows(rows: rows).padding(10) }
    }

    private var rows: [(String, String)] {
        switch tab.kind {
        case .terminal(let id):
            var rows: [(String, String)] = [("Tab", "Terminal")]
            if let session = workspaceManager.terminalSession(id) {
                rows.append(("Runs", session.profile == .shell ? "Shell" : session.profile.rawValue.capitalized))
                rows.append(("Status", session.isRunning ? "Running" : "Exited" + (session.exitCode.map { " (code \($0))" } ?? "")))
                rows.append(("Folder", session.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
            }
            return rows
        case .github(let item):
            switch item {
            case .issue(let number, let repo, let title): return [("Tab", "GitHub issue"), ("Repository", repo), ("Number", "#\(number)"), ("Title", title)]
            case .run(let id, let repo, let title): return [("Tab", "GitHub Actions run"), ("Repository", repo), ("Run", String(id)), ("Title", title)]
            }
        case .architecture(let scope):
            return [("Tab", "X-Ray"), ("Scope", scope.isEmpty ? "Whole project" : scope == TabKind.pullRequestScope ? "Pull request" : scope)]
        default:
            return [("Tab", tab.displayName)]
        }
    }
}

/// A prototype: its facts and screens.
struct PrototypeContentsPanel: View {
    @ObservedObject var session: PrototypeSession

    var body: some View {
        let manifest = session.manifest
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                FactRows(rows: [("Tab", "Prototype"), ("Title", manifest.title), ("Version", "v\(manifest.version)"),
                                ("Approved", manifest.approved ? "Yes" : "Not yet"),
                                ("Screens", String(manifest.screens.count)), ("Sources", manifest.sources.joined(separator: ", "))])
                if !manifest.screens.isEmpty {
                    Text("SCREENS").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
                    ForEach(manifest.screens, id: \.self) { screen in
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.portrait").uiFont(size: 9).foregroundColor(VSDark.textDim)
                            Text(screen).uiFont(size: 11).foregroundColor(VSDark.text).lineLimit(1)
                        }
                    }
                }
                if !manifest.assumptions.isEmpty {
                    Text("ASSUMPTIONS").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
                    ForEach(manifest.assumptions, id: \.self) { Text("• " + $0).uiFont(size: 10).foregroundColor(VSDark.text) }
                }
            }
            .padding(10)
        }
    }
}

/// The headings of the page in a browser tab, and the page's facts; a click scrolls the page to the heading.
@MainActor
final class BrowserOutlineModel: ObservableObject {
    struct Heading: Identifiable { let id: Int; let level: Int; let text: String }
    @Published private(set) var headings: [Heading] = []
    @Published private(set) var links = 0
    let session: BrowserSession
    private static let selector = "h1,h2,h3,h4,h5,h6"

    init(session: BrowserSession) { self.session = session }

    func reload() {
        guard session.url != nil else { headings = []; links = 0; return }
        let script = "JSON.stringify({h:[...document.querySelectorAll('\(Self.selector)')].slice(0,300).map(function(h,i){return {i:i,l:+h.tagName[1],t:(h.innerText||'').trim().replace(/\\s+/g,' ').slice(0,140)}}),a:document.querySelectorAll('a[href]').length})"
        session.webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, let text = value as? String, let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let list = (object["h"] as? [[String: Any]] ?? []).compactMap { entry -> Heading? in
                guard let i = entry["i"] as? Int, let level = entry["l"] as? Int, let text = entry["t"] as? String, !text.isEmpty else { return nil }
                return Heading(id: i, level: level, text: text)
            }
            Task { @MainActor in self.headings = list; self.links = object["a"] as? Int ?? 0 }
        }
    }

    func scroll(to heading: Heading) {
        session.webView.evaluateJavaScript("(function(){var e=document.querySelectorAll('\(Self.selector)')[\(heading.id)]; if(e){e.scrollIntoView({block:'start',behavior:'smooth'});}})()")
    }
}

struct BrowserContentsPanel: View {
    @ObservedObject var session: BrowserSession
    @StateObject private var model: BrowserOutlineModel

    init(session: BrowserSession) {
        self.session = session
        _model = StateObject(wrappedValue: BrowserOutlineModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                FactRows(rows: [("Title", session.title.isEmpty ? "—" : session.title),
                                ("Address", session.url?.absoluteString ?? "—"),
                                ("Host", session.url?.host ?? "—"),
                                ("Status", session.isLoading ? "Loading…" : session.loadError ?? "Loaded"),
                                ("Links", String(model.links))]).padding(10)
            }
            .frame(maxHeight: 130)
            Divider().background(VSDark.border)
            HStack {
                Text("HEADINGS").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
                Spacer()
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise").uiFont(size: 9) }
                    .buttonStyle(.plain).foregroundColor(VSDark.textDim).help("Read the page's headings again")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            if model.headings.isEmpty {
                Spacer()
                Text(session.isLoading ? "Loading…" : "No headings on this page").uiFont(size: 11).foregroundColor(VSDark.textDim)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.headings) { heading in
                            Button { model.scroll(to: heading) } label: {
                                HStack(spacing: 4) {
                                    Color.clear.frame(width: CGFloat(heading.level - 1) * 12, height: 1)
                                    Circle().fill(VSDark.textDim.opacity(0.4)).frame(width: 5, height: 5)
                                    Text(heading.text).uiFont(size: 11).foregroundColor(VSDark.text).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 2).padding(.horizontal, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        // Read the page when it finishes loading, and when the address changes.
        .onReceive(session.$isLoading.removeDuplicates()) { loading in
            if !loading { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.reload() } }
        }
        .task(id: session.url) { model.reload() }
    }
}
