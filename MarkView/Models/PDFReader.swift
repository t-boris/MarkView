import AppKit
import PDFKit

struct PDFReaderOutline: Identifiable {
    let id = UUID()
    let title: String
    let destination: PDFDestination?
    let children: [PDFReaderOutline]?

    static func items(in root: PDFOutline?, depth: Int = 0) -> [PDFReaderOutline] {
        guard let root, depth < 64 else { return [] }
        return (0..<root.numberOfChildren).compactMap { index in
            guard let child = root.child(at: index) else { return nil }
            let children = items(in: child, depth: depth + 1)
            return PDFReaderOutline(title: child.label ?? "Untitled",
                destination: child.destination ?? (child.action as? PDFActionGoTo)?.destination,
                children: children.isEmpty ? nil : children)
        }
    }
}

enum PDFReaderLinks {
    static func allows(_ url: URL) -> Bool {
        guard url.baseURL == nil,
              !(url.absoluteString.removingPercentEncoding ?? url.absoluteString).unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil else { return false }
        switch parts.scheme?.lowercased() {
        case "http", "https":
            guard let host = parts.host, !host.isEmpty else { return false }
            return !host.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
        case "mailto":
            return !parts.path.isEmpty
        default:
            return false
        }
    }
}

enum PDFReaderLoading {
    struct Result {
        let document: PDFDocument
        let outline: [PDFReaderOutline]
    }

    static func load(_ url: URL, password: String? = nil) throws -> Result {
        guard url.isFileURL,
              (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw ReaderError.invalidFile
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ReaderError.unreadable }
        guard let document = PDFDocument(url: url) else { throw ReaderError.invalidPDF }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else {
                return Result(document: document, outline: [])
            }
        }
        guard document.pageCount > 0 else { throw ReaderError.empty }
        // The displayed form retains its appearance, but none of its fields can be edited.
        // Only this in-memory document changes; the reader has no PDF write path.
        if document.allowsFormFieldEntry {
            for index in 0..<document.pageCount {
                for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
                    annotation.isReadOnly = true
                }
            }
        }
        return Result(document: document, outline: PDFReaderOutline.items(in: document.outlineRoot))
    }

    enum ReaderError: LocalizedError {
        case invalidFile, unreadable, invalidPDF, empty
        var errorDescription: String? {
            switch self {
            case .invalidFile: return "Choose a local PDF file."
            case .unreadable: return "This PDF cannot be read. Check its file permissions."
            case .invalidPDF: return "This file is not a readable PDF, or it is damaged."
            case .empty: return "This PDF has no pages to display."
            }
        }
    }
}

@MainActor
final class PDFReaderController: NSObject, ObservableObject, @preconcurrency PDFDocumentDelegate, @preconcurrency PDFViewDelegate {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var outline: [PDFReaderOutline] = []
    @Published private(set) var loading = false
    @Published private(set) var locked = false
    @Published private(set) var error: String?
    @Published private(set) var pageNumber = 1
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var matches: [PDFSelection] = []
    @Published private(set) var matchIndex = -1
    @Published private(set) var searching = false
    @Published private(set) var findRequest = 0
    private(set) var loadedURL: URL?
    private var loadGeneration = UUID()
    private var observers: [NSObjectProtocol] = []
    private var fitMode: PDFReaderPDFView.FitMode = .page
    private weak var view: PDFReaderPDFView?
    private var query = ""

    var pageCount: Int { document?.pageCount ?? 0 }
    var canCopy: Bool { document?.allowsCopying == true && !locked }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func load(_ url: URL, password: String? = nil) async {
        if loadedURL == url, document != nil, !locked, error == nil { return }
        let generation = UUID()
        loadGeneration = generation
        loading = true
        error = nil
        cancelSearch()
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try PDFReaderLoading.load(url, password: password)
            }.value
            guard generation == loadGeneration, !Task.isCancelled else {
                if generation == loadGeneration { loading = false }
                return
            }
            document = result.document
            document?.delegate = self
            outline = result.outline
            locked = result.document.isLocked
            loadedURL = url
            pageNumber = 1
            if locked, password != nil { error = "The password is incorrect. Try again." }
        } catch {
            guard generation == loadGeneration else { return }
            if Task.isCancelled { loading = false; return }
            document = nil
            outline = []
            locked = false
            self.error = "Cannot open this PDF. \(error.localizedDescription)"
        }
        loading = false
    }

    func attach(_ view: PDFReaderPDFView) {
        if self.view === view { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        self.view = view
        view.delegate = self
        view.onFind = { [weak self] in self?.findRequest += 1 }
        view.fitMode = fitMode
        if let page = document?.page(at: pageNumber - 1) { view.go(to: page) }
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePosition() }
            })
        }
        view.applyFit()
        updatePosition()
        if matches.indices.contains(matchIndex) { revealMatch() }
    }

    func bindThumbnails(_ thumbnails: PDFThumbnailView) {
        if thumbnails.pdfView !== view { thumbnails.pdfView = view }
    }

    private func updatePosition() {
        guard let view else { return }
        if let page = view.currentPage, let document = view.document {
            let index = document.index(for: page)
            if index != NSNotFound, pageNumber != index + 1 { pageNumber = index + 1 }
        }
        if zoom != view.scaleFactor { zoom = view.scaleFactor }
        fitMode = view.fitMode
    }

    func go(to number: Int) {
        guard number > 0, number <= pageCount, let page = document?.page(at: number - 1) else { return }
        view?.go(to: page)
        pageNumber = number
        view?.applyFit()
    }

    func go(to destination: PDFDestination?) {
        guard let destination, let page = destination.page, page.document === document else { return }
        view?.go(to: destination)
        updatePosition()
    }

    func setFit(_ mode: PDFReaderPDFView.FitMode) {
        fitMode = mode
        view?.fitMode = mode
        view?.applyFit()
    }

    func zoom(by factor: CGFloat) {
        guard let view else { return }
        fitMode = .manual
        view.fitMode = .manual
        view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, view.scaleFactor * factor))
    }

    func search(_ text: String) {
        cancelSearch()
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let document, !document.isLocked else { return }
        searching = true
        document.beginFindString(query, withOptions: [.caseInsensitive])
    }

    func cancelSearch() {
        document?.cancelFindString()
        searching = false
        matches = []
        matchIndex = -1
        view?.highlightedSelections = nil
        view?.clearSelection()
    }

    func didMatchString(_ instance: PDFSelection) {
        guard searching else { return }
        matches.append(instance)
        if matchIndex == -1 {
            matchIndex = 0
            revealMatch()
        }
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        searching = false
    }

    func nextMatch(_ step: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + step + matches.count) % matches.count
        revealMatch()
    }

    private func revealMatch() {
        guard matches.indices.contains(matchIndex), let view else { return }
        view.setCurrentSelection(matches[matchIndex], animate: false)
        view.go(to: matches[matchIndex])
        updatePosition()
    }

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        guard PDFReaderLinks.allows(url) else { return }
        (sender as? PDFReaderPDFView)?.openExternal(url)
    }
}

/// PDFKit provides rendering and text selection, but not a route to edit or execute PDF actions.
final class PDFReaderPDFView: PDFView {
    enum FitMode { case page, width, manual }
    var fitMode: FitMode = .page
    var onFind: (() -> Void)?
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var fittedSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        autoScales = false
        minScaleFactor = 0.1
        maxScaleFactor = 10
        if #unavailable(macOS 15) { enableDataDetectors = false }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        if fittedSize != bounds.size {
            fittedSize = bounds.size
            applyFit()
        }
    }

    func applyFit() {
        guard fitMode != .manual, bounds.width > 40, bounds.height > 40,
              let page = currentPage ?? document?.page(at: 0) else { return }
        let box = page.bounds(for: displayBox)
        let rotated = page.rotation % 180 != 0
        let width = rotated ? box.height : box.width
        let height = rotated ? box.width : box.height
        guard width > 0, height > 0 else { return }
        let horizontal = (bounds.width - 24) / width
        let vertical = (bounds.height - 16) / height
        let target = fitMode == .width ? horizontal : min(horizontal, vertical)
        if abs(scaleFactor - target) > 0.001 {
            scaleFactor = min(maxScaleFactor, max(minScaleFactor, target))
        }
    }

    override func perform(_ action: PDFAction) {
        if let link = action as? PDFActionURL {
            if let url = link.url, PDFReaderLinks.allows(url) { openExternal(url) }
        } else if let go = action as? PDFActionGoTo {
            if go.destination.page?.document === document { super.perform(action) }
        } else if let named = action as? PDFActionNamed {
            switch named.name {
            case .firstPage, .lastPage, .nextPage, .previousPage, .goBack, .goForward:
                super.perform(action)
            case .zoomIn: scaleFactor *= 1.25; fitMode = .manual
            case .zoomOut: scaleFactor /= 1.25; fitMode = .manual
            case .find: onFind?()
            default: break
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: false),
           let annotation = page.annotation(at: convert(point, to: page)), annotation.type != "Link" {
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "f" {
            onFind?()
            return
        }
        super.keyDown(with: event)
    }

    override func magnify(with event: NSEvent) {
        fitMode = .manual
        super.magnify(with: event)
    }

    override func copy(_ sender: Any?) {
        guard document?.allowsCopying == true else { return }
        super.copy(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = document?.allowsCopying == true && currentSelection?.string?.isEmpty == false
        menu.autoenablesItems = false
        return menu
    }
}
