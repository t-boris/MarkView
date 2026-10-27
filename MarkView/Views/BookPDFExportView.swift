import SwiftUI

struct BookPDFExportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: BookPDFExportModel
    private let initial: [URL]

    init(selection: BookPDFSelection, project: URL?, drafts: [String: String], database: SemanticDatabase?) {
        initial = selection.urls
        _model = StateObject(wrappedValue: BookPDFExportModel(project: project, drafts: drafts, database: database))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "book.closed").uiFont(.title)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Export PDF Book").uiFont(.title2, weight: .semibold)
                    Text("A cover, linked contents, chapters, page numbers and PDF bookmarks.").uiFont(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            settings
            HStack {
                Text("Chapters · \(model.chapters.count)").uiFont(.headline)
                Spacer()
                Button("Add Files or Folders…") { model.chooseSources() }.disabled(model.isBusy)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                        HStack(spacing: 9) {
                            Text(String(index + 1)).monospacedDigit().foregroundColor(.secondary).frame(width: 25)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title).lineLimit(1)
                                Text(chapter.path).uiFont(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button { model.move(chapter.id, by: -1) } label: { Image(systemName: "arrow.up") }.help("Move chapter up").disabled(model.isBusy || index == 0)
                            Button { model.move(chapter.id, by: 1) } label: { Image(systemName: "arrow.down") }.help("Move chapter down").disabled(model.isBusy || index == model.chapters.count - 1)
                            Button { model.remove(chapter.id) } label: { Image(systemName: "minus.circle") }.help("Remove from this book").disabled(model.isBusy)
                        }.padding(.vertical, 7)
                        Divider()
                    }
                    if model.chapters.isEmpty { Text("Add documents, images or folders. Folders are expanded recursively; overlapping selections appear once.").foregroundColor(.secondary).padding(20) }
                }
            }.frame(minHeight: 130, maxHeight: .infinity).padding(.horizontal, 8).background(.quaternary.opacity(0.3)).cornerRadius(6)
            if model.isBusy { ProgressView(value: model.progress).progressViewStyle(.linear) }
            Text(model.status).uiFont(.caption).foregroundColor(.secondary).textSelection(.enabled)
            if let error = model.error { Text(error).uiFont(.caption).foregroundColor(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if !model.warnings.isEmpty {
                DisclosureGroup("\(model.warnings.count) source or link notices") {
                    ScrollView { Text(model.warnings.joined(separator: "\n")).uiFont(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
                }
            }
            HStack {
                Button(model.isBusy ? "Stop Export" : "Close") { if model.isBusy { model.cancel() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                if let url = model.savedURL {
                    Button("Open PDF") { NSWorkspace.shared.open(url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Spacer()
                Button("Export Book…") { model.export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.chapters.isEmpty || model.options.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.options.language == "custom" && model.customLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(22).frame(width: 710, height: 700)
        .onAppear { model.add(initial) }
        .onDisappear { model.cancel() }
        .interactiveDismissDisabled(model.isBusy)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                TextField("Book title", text: $model.options.title)
                TextField("Author (optional)", text: $model.options.author).frame(width: 220)
            }.textFieldStyle(.roundedBorder)
            HStack {
                Picker("Language", selection: $model.options.language) {
                    ForEach(ActionOutputLanguage.options, id: \.value) { Text($0.label).tag($0.value) }
                    Text("Other…").tag("custom")
                }.frame(width: 240)
                if model.options.language == "custom" {
                    TextField("Language name", text: $model.customLanguage).textFieldStyle(.roundedBorder)
                }
                Spacer()
                Picker("Pages", selection: $model.options.paper) {
                    Text("A4").tag("a4"); Text("A4 Landscape").tag("a4Landscape"); Text("Letter").tag("letter")
                }.frame(width: 190)
            }
            HStack {
                Picker("Style", selection: $model.options.theme) {
                    Text("Warm paper").tag("paper"); Text("Classic white").tag("white"); Text("Midnight").tag("midnight")
                }.frame(width: 240)
                Spacer()
                Text("Shorten by \(model.options.reduction)%").monospacedDigit().frame(width: 118, alignment: .trailing)
                Slider(value: Binding(get: { Double(model.options.reduction) }, set: { model.options.reduction = Int($0) }), in: 0...90, step: 10).frame(width: 160)
            }
            Text(model.options.reduction == 0
                 ? "0% keeps the complete text. Choosing another language translates it without shortening."
                 : "Target: keep about \(100 - model.options.reduction)% of the prose. Tables, code, images and references stay complete. Page count and PDF file size depend on the layout.")
                .uiFont(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.options.needsAI ? "Translation and shortening use this project's assistant and model. Source files stay unchanged." : "Original text · no assistant required · includes unsaved editor text.")
                .uiFont(.caption).foregroundColor(.secondary)
        }
        .disabled(model.isBusy)
    }
}
