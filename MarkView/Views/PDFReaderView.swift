import SwiftUI
import PDFKit

struct PDFReaderView: View {
    let url: URL
    @ObservedObject var reader: PDFReaderController
    @State private var sidebar = true
    @State private var navigation = "Pages"
    @State private var pageInput = ""
    @State private var query = ""
    @State private var password = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if reader.document != nil, !reader.locked {
                controls
                Divider()
                search
                Divider()
                HSplitView {
                    if sidebar {
                        navigationPanel.frame(minWidth: 130, idealWidth: 180, maxWidth: 280)
                    }
                    PDFReaderCanvas(reader: reader)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                status
            }
        }
        .background(VSDark.bg)
        .task(id: url) { await reader.load(url) }
        .task(id: query) {
            if !query.isEmpty {
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
            if !Task.isCancelled { reader.search(query) }
        }
        .onChange(of: reader.pageNumber) { pageInput = String($0) }
        .onChange(of: reader.findRequest) { _ in searchFocused = true }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            icon("sidebar.left", "Show thumbnails and outline") { sidebar.toggle() }
            icon("chevron.left", "Previous page") { reader.go(to: reader.pageNumber - 1) }
                .disabled(reader.pageNumber <= 1)
            TextField("Page", text: $pageInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
                .accessibilityLabel("Go to page")
                .onSubmit {
                    if let number = Int(pageInput) { reader.go(to: number) }
                    pageInput = String(reader.pageNumber)
                }
                .onAppear { pageInput = String(reader.pageNumber) }
            Text("of \(reader.pageCount)").uiFont(size: 11)
            icon("chevron.right", "Next page") { reader.go(to: reader.pageNumber + 1) }
                .disabled(reader.pageNumber >= reader.pageCount)
            Spacer(minLength: 4)
            icon("minus.magnifyingglass", "Zoom out") { reader.zoom(by: 1 / 1.25) }
            Text("\(Int((reader.zoom * 100).rounded()))%")
                .uiFont(size: 10, design: .monospaced).frame(minWidth: 40)
            icon("plus.magnifyingglass", "Zoom in") { reader.zoom(by: 1.25) }
            Button("Fit Page") { reader.setFit(.page) }
            Button("Fit Width") { reader.setFit(.width) }
        }
        .buttonStyle(.borderless)
        .foregroundColor(VSDark.text)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(VSDark.bgSidebar)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .help("Find in PDF")
            TextField("Find in PDF", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { reader.nextMatch(1) }
            if !query.isEmpty {
                if reader.searching { ProgressView().controlSize(.small) }
                Text(reader.matches.isEmpty ? "No matches" : "\(reader.matchIndex + 1) of \(reader.matches.count)")
                    .uiFont(size: 10).fixedSize()
                icon("chevron.up", "Previous match") { reader.nextMatch(-1) }
                    .disabled(reader.matches.isEmpty)
                icon("chevron.down", "Next match") { reader.nextMatch(1) }
                    .disabled(reader.matches.isEmpty)
                icon("xmark", "Clear search") { query = "" }
            }
            if !reader.canCopy {
                Text("Copying restricted").uiFont(size: 10).help("The PDF's permissions do not allow copying.")
            }
        }
        .foregroundColor(VSDark.textDim)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(VSDark.bgSidebar)
    }

    private var navigationPanel: some View {
        VStack(spacing: 0) {
            Picker("Navigation", selection: $navigation) {
                Text("Pages").tag("Pages")
                Text("Outline").tag("Outline")
            }
            .pickerStyle(.segmented).labelsHidden().padding(6)
            if navigation == "Pages" {
                PDFReaderThumbnails(reader: reader)
            } else if reader.outline.isEmpty {
                Text("No document outline").uiFont(size: 11).foregroundColor(VSDark.textDim)
                    .padding()
                Spacer()
            } else {
                List {
                    OutlineGroup(reader.outline, children: \.children) { item in
                        Button { reader.go(to: item.destination) } label: {
                            Text(item.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(item.destination == nil)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(VSDark.bgSidebar)
    }

    private var status: some View {
        VStack(spacing: 12) {
            Spacer()
            if reader.loading {
                ProgressView("Opening PDF...")
            } else if reader.locked {
                Image(systemName: "lock.doc").font(.system(size: 30))
                Text("This PDF is password-protected.")
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder).frame(width: 240)
                    .onSubmit { unlock() }
                if let error = reader.error { Text(error).font(.caption) }
                Button("Unlock PDF") { unlock() }.disabled(password.isEmpty)
            } else if let error = reader.error {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                Text(error).multilineTextAlignment(.center).frame(maxWidth: 450)
                Button("Retry") { Task { await reader.load(url) } }
            } else {
                ProgressView("Opening PDF...")
            }
            Spacer()
        }
        .foregroundColor(VSDark.textDim)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func unlock() {
        let value = password
        password = ""
        Task { await reader.load(url, password: value) }
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).uiFont(size: 11) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }
}

private struct PDFReaderCanvas: NSViewRepresentable {
    @ObservedObject var reader: PDFReaderController

    func makeNSView(context: Context) -> PDFReaderPDFView {
        let view = PDFReaderPDFView(frame: .zero)
        view.document = reader.document
        reader.attach(view)
        return view
    }

    func updateNSView(_ view: PDFReaderPDFView, context: Context) {
        if view.document !== reader.document { view.document = reader.document }
        reader.attach(view)
    }
}

private struct PDFReaderThumbnails: NSViewRepresentable {
    @ObservedObject var reader: PDFReaderController

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView(frame: .zero)
        view.thumbnailSize = NSSize(width: 105, height: 140)
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        // Both views are created in the same update; the deferred binding also handles
        // the sidebar being mounted before the canvas.
        DispatchQueue.main.async { [weak view, weak reader] in
            guard let view, let reader else { return }
            reader.bindThumbnails(view)
        }
    }
}
