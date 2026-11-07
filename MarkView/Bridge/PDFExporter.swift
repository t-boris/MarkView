import AppKit
import WebKit
import UniformTypeIdentifiers

/// Exports the active document as a PDF that is ready to be shared: a title page, running header and footer with page numbers,
/// contents when the document is long, bookmarks and working links, the colours of a chosen style as the page background, and
/// pages that are typeset one by one, so a table, a picture, a diagram or a code block is never cut by a page boundary.
///
/// The typesetting is the PDF-book engine in its `document` mode (`book.html`, `BookPDFRenderer`): one engine makes every PDF of
/// the app. This type only decides what is printed, asks where to save it and in which style, and saves the result.
@MainActor
enum PDFExporter {
    /// The look of the PDF, chosen in the save panel and remembered.
    struct Style: Equatable {
        var theme = "paper"
        var paper = "a4"

        static let themes: [(value: String, title: String)] = [("paper", "Paper"), ("white", "White"), ("midnight", "Midnight")]
        static let papers: [(value: String, title: String)] = [("a4", "A4"), ("letter", "US Letter"), ("a4Landscape", "A4 Landscape")]
        private static let themeKey = "pdfExport.theme", paperKey = "pdfExport.paper"

        static func remembered(_ defaults: UserDefaults = .standard) -> Style {
            var style = Style()
            if let theme = defaults.string(forKey: themeKey), themes.contains(where: { $0.value == theme }) { style.theme = theme }
            if let paper = defaults.string(forKey: paperKey), papers.contains(where: { $0.value == paper }) { style.paper = paper }
            return style
        }

        func remember(_ defaults: UserDefaults = .standard) {
            defaults.set(theme, forKey: Style.themeKey)
            defaults.set(paper, forKey: Style.paperKey)
        }
    }

    // MARK: - Entry points

    /// The active tab of the editor window. A file is printed from the text the tab holds (the unsaved text included), so the
    /// PDF shows what the person sees; an insight page is printed from the page that shows it.
    static func exportPDF(from webView: WKWebView, tab: OpenTab?, fileName: String, documentFiles: DocumentFileSchemeHandler) {
        guard let tab else { return showError("There is no document to export.") }
        let roots = documentFiles.allowedRoots()
        switch tab.kind {
        case .file:
            let url = tab.url, text = tab.content
            begin(fileName: fileName, roots: roots) {
                try await Task.detached {
                    guard let chapter = try BookPDFSource.collect([url], drafts: [url.path: text]).chapters.first else {
                        throw BookPDFError.invalid("This file has nothing to print.")
                    }
                    return chapter
                }.value
            }
        case .insight:
            webView.evaluateJavaScript(insightProbe) { result, _ in
                let html = (result as? String) ?? ""
                MainActor.assumeIsolated {
                    guard !html.isEmpty else {
                        return showError("The insight is not shown yet. Wait a moment for it to render and try again.")
                    }
                    let title = tab.url.deletingPathExtension().lastPathComponent
                    let chapter = BookPDFChapter(id: "c0", url: tab.url, path: tab.url.lastPathComponent, title: title, format: "html", text: html, original: html)
                    begin(fileName: fileName, roots: roots) { chapter }
                }
            }
        default:
            showError("This tab has no document to export as a PDF.")
        }
    }

    /// A document the page builds on request, such as the report of a research map: printed from its Markdown.
    static func exportPDF(markdown: String, title: String, fileName: String, baseURL: URL?, documentFiles: DocumentFileSchemeHandler) {
        let folder = baseURL ?? FileManager.default.temporaryDirectory
        let chapter = BookPDFChapter(id: "c0", url: folder.appendingPathComponent((fileName as NSString).deletingPathExtension + ".md"),
                                     path: fileName, title: title, format: "markdown", text: markdown, original: markdown)
        begin(fileName: fileName, roots: documentFiles.allowedRoots()) { chapter }
    }

    // MARK: - Making the PDF

    /// The PDF of one document. No panel and no file: the entry points above, and the checks (which pass the renderer page), use it.
    static func render(_ chapter: BookPDFChapter, style: Style, entry: URL? = nil,
                       allowFile: (@Sendable (URL) -> Bool)? = nil) async throws -> BookPDFRenderer.Result {
        var options = BookPDFOptions()
        options.mode = "document"
        options.title = chapter.title
        options.theme = style.theme
        options.paper = style.paper
        options.locale = BookPDFLabels.detectedLanguage(of: plainText(chapter))
        let words = BookPDFLabels.known[options.locale] ?? BookPDFLabels.known["en"]!
        let renderer = try BookPDFRenderer(entry: entry)
        _ = try await renderer.prepare([chapter], options: options, allowFile: allowFile)
        return try await renderer.render(options: options, labels: BookPDFLabels.dictionary(words)) { _, _ in }
    }

    /// Whether a picture file may be read for a document: it lies inside one of the folders the document may use (the project and the
    /// folders of open documents). Links are followed first, so a link inside a folder cannot lead out of it.
    nonisolated static func allows(_ file: URL, within roots: [URL]) -> Bool {
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { root in
            let base = root.resolvingSymlinksInPath().standardizedFileURL.path
            return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    private static func plainText(_ chapter: BookPDFChapter) -> String {
        guard chapter.format == "html" else { return chapter.text }
        return chapter.text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func begin(fileName: String, roots: [URL], load: @escaping @Sendable () async throws -> BookPDFChapter) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        let accessory = StyleAccessory(style: .remembered())
        panel.accessoryView = accessory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let style = accessory.style
            style.remember()
            Task { @MainActor in
                do {
                    let chapter = try await load()
                    // A picture is read only from the folders the document may use (the project and the folders of open documents).
                    let result = try await render(chapter, style: style) { allows($0, within: roots) }
                    try await Task.detached { try result.data.write(to: url, options: .atomic) }.value
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                    let notes = Set(result.warnings.filter { $0.hasPrefix("A picture") || $0.hasPrefix("A diagram") })
                    if !notes.isEmpty { showNotice("The PDF was saved, with notes in it:\n\n" + notes.sorted().prefix(6).joined(separator: "\n")) }
                } catch {
                    showError(error.localizedDescription)
                }
            }
        }
    }

    /// The body of the insight page shown in the editor, without its footer and progress banner (nil text when it is not shown).
    private static let insightProbe = """
        (function() {
            try {
                var frame = document.getElementById('insight-iframe');
                if (!(window.state && window.state.mode === 'insight' && frame && frame.contentDocument && frame.contentDocument.body)) return '';
                var clone = frame.contentDocument.body.cloneNode(true);
                clone.querySelectorAll('.iframe-footer, .insight-progress-banner').forEach(function(node) { node.remove(); });
                return clone.innerHTML;
            } catch (error) { return ''; }
        })()
        """

    private static func showError(_ message: String) {
        present(title: "PDF Export Failed", message: message, style: .warning)
    }

    private static func showNotice(_ message: String) {
        present(title: "PDF Saved", message: message, style: .informational)
    }

    private static func present(title: String, message: String, style: NSAlert.Style) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = style
            alert.runModal()
        }
    }
}

/// Paper size and page style, next to the name field of the save panel.
private final class StyleAccessory: NSView {
    private let theme = NSPopUpButton(frame: .zero, pullsDown: false)
    private let paper = NSPopUpButton(frame: .zero, pullsDown: false)

    init(style: PDFExporter.Style) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 70))
        for item in PDFExporter.Style.themes { theme.addItem(withTitle: item.title) }
        for item in PDFExporter.Style.papers { paper.addItem(withTitle: item.title) }
        theme.selectItem(at: PDFExporter.Style.themes.firstIndex { $0.value == style.theme } ?? 0)
        paper.selectItem(at: PDFExporter.Style.papers.firstIndex { $0.value == style.paper } ?? 0)
        func row(_ title: String, _ button: NSPopUpButton) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 50).isActive = true
            button.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let stack = NSStackView(views: [label, button])
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }
        let rows = NSStackView(views: [row("Style:", theme), row("Page:", paper)])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.centerXAnchor.constraint(equalTo: centerXAnchor),
            rows.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var style: PDFExporter.Style {
        PDFExporter.Style(theme: PDFExporter.Style.themes[max(0, theme.indexOfSelectedItem)].value,
                          paper: PDFExporter.Style.papers[max(0, paper.indexOfSelectedItem)].value)
    }
}
