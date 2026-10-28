import AppKit
import WebKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Owns one isolated renderer per export, including its navigation lifetime. JavaScript
/// typesets real pages; PDFKit assembles them and adds portable links and a bookmark tree.
@MainActor
final class BookPDFRenderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let entry: URL
    private var navigation: CheckedContinuation<Void, Error>?
    private var navigationTimeout: Task<Void, Never>?
    private var operations: [UUID: () -> Void] = [:]

    init(entry: URL? = nil) throws {
        guard let entry = entry ?? Bundle.main.url(forResource: "book", withExtension: "html", subdirectory: "Editor") else {
            throw BookPDFError.invalid("The book renderer is missing from the application. Reinstall MarkView.")
        }
        self.entry = entry
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 595, height: 842), configuration: config)
        super.init(); webView.navigationDelegate = self
    }

    struct Prepared {
        var html: [(id: String, text: String)]
    }

    func prepare(_ chapters: [BookPDFChapter], options: BookPDFOptions) async throws -> Prepared {
        try await load()
        let values = chapters.map { ["id": $0.id, "url": $0.url.absoluteString, "path": $0.path,
                                     "title": $0.title, "format": $0.format, "text": $0.text] }
        let settings: [String: Any] = ["title": options.title, "author": options.author, "paper": options.paper, "theme": options.theme]
        let result = try await call("return await BookPDF.prepare(chapters, options)", ["chapters": values, "options": settings]) as? [String: Any]
        let requests = result?["assets"] as? [[String: String]] ?? []
        var images: [String: String] = [:]
        var bytes = 0
        for request in requests {
            try Task.checkCancellation()
            guard let id = request["id"], let raw = request["url"], let url = URL(string: raw) else { throw BookPDFError.invalid("An illustration has an invalid URL.") }
            let reading = Task.detached { try await Self.image(url) }
            let value = try await withTaskCancellationHandler { try await reading.value } onCancel: { reading.cancel() }
            bytes += value.utf8.count
            guard bytes <= 96 * 1024 * 1024 else { throw BookPDFError.invalid("Illustrations exceed the book's 96 MB image limit. Use smaller originals.") }
            images[id] = value
        }
        let rows = try await call("return await BookPDF.assets(images)", ["images": images]) as? [[String: String]] ?? []
        guard rows.count == chapters.count else { throw BookPDFError.invalid("Some selected documents were not rendered.") }
        return Prepared(html: try rows.map {
            guard let id = $0["id"], let html = $0["html"] else { throw BookPDFError.invalid("Invalid rendered chapter.") }
            return (id, html)
        })
    }

    func setChapter(_ id: String, html: String) async throws {
        _ = try await call("BookPDF.setChapter(id, html); return true", ["id": id, "html": html])
    }

    func proseWords() async throws -> Int { (try await call("return BookPDF.proseWords()") as? NSNumber)?.intValue ?? 0 }

    func prosePassages(_ id: String) async throws -> [(id: String, html: String)] {
        let values = try await call("return BookPDF.prosePassages(id)", ["id": id]) as? [[String: String]] ?? []
        return try values.map {
            guard let id = $0["id"], let html = $0["html"] else { throw BookPDFError.invalid("Invalid prose passage.") }
            return (id, html)
        }
    }

    func setPassage(chapter: String, id: String, html: String) async throws {
        _ = try await call("BookPDF.setPassage(chapter, id, html); return true", ["chapter": chapter, "id": id, "html": html])
    }

    struct Result {
        var data: Data
        var pages: Int
        var warnings: [String]
    }

    func render(options: BookPDFOptions, labels: [String: String], progress: (Int, Int) -> Void) async throws -> Result {
        _ = try await call("BookPDF.title(title); return true", ["title": options.title])
        guard let layout = try await call("return await BookPDF.layout(labels)", ["labels": labels]) as? [String: Any],
              let width = layout["width"] as? Double, let height = layout["height"] as? Double,
              let count = layout["count"] as? Int, (1...2000).contains(count) else {
            throw BookPDFError.invalid("The book could not be paginated.")
        }
        webView.setFrameSize(CGSize(width: width, height: height))
        let pdf = PDFDocument()
        for index in 0..<count {
            try Task.checkCancellation()
            progress(index + 1, count)
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: Double(index) * height, width: width, height: height)
            let data: Data = try await perform { completion in webView.createPDF(configuration: configuration, completionHandler: completion) }
            guard let page = PDFDocument(data: data)?.page(at: 0) else { throw BookPDFError.invalid("Page \(index + 1) could not be rendered.") }
            // WebKit's internal file:// links are not portable after assembling separate pages.
            for annotation in page.annotations { page.removeAnnotation(annotation) }
            pdf.insert(page, at: pdf.pageCount)
        }
        var destinations: [String: PDFDestination] = [:]
        for value in layout["destinations"] as? [[String: Any]] ?? [] {
            guard let id = value["id"] as? String, let index = value["page"] as? Int,
                  let x = value["x"] as? Double, let y = value["y"] as? Double, let page = pdf.page(at: index) else { continue }
            destinations[id] = PDFDestination(page: page, at: NSPoint(x: x, y: height - y))
        }
        for link in layout["links"] as? [[String: Any]] ?? [] {
            guard let index = link["page"] as? Int, let page = pdf.page(at: index),
                  let x = link["x"] as? Double, let y = link["y"] as? Double,
                  let w = link["w"] as? Double, let h = link["h"] as? Double else { continue }
            let annotation = PDFAnnotation(bounds: NSRect(x: x, y: height - y - h, width: w, height: h), forType: .link, withProperties: nil)
            if let id = link["target"] as? String, let destination = destinations[id] { annotation.action = PDFActionGoTo(destination: destination) }
            else if let raw = link["url"] as? String, let url = URL(string: raw), ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                annotation.action = PDFActionURL(url: url)
            } else { continue }
            annotation.border = PDFBorder(); annotation.border?.lineWidth = 0
            page.addAnnotation(annotation)
        }
        let root = PDFOutline()
        var stack: [(Int, PDFOutline)] = [(0, root)]
        for entry in layout["outline"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? String, let title = entry["title"] as? String,
                  let level = entry["level"] as? Int, let destination = destinations[id] else { continue }
            while let last = stack.last, last.0 >= level { stack.removeLast() }
            let item = PDFOutline(); item.label = title; item.destination = destination
            let parent = stack.last?.1 ?? root; parent.insertChild(item, at: parent.numberOfChildren); stack.append((level, item))
        }
        pdf.outlineRoot = root
        pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: options.title,
                                  PDFDocumentAttribute.authorAttribute: options.author,
                                  PDFDocumentAttribute.creatorAttribute: "MarkView",
                                  PDFDocumentAttribute.subjectAttribute: "Book · \(options.language)"]
        guard let data = pdf.dataRepresentation() else { throw BookPDFError.invalid("The PDF could not be assembled.") }
        return Result(data: data, pages: count, warnings: layout["warnings"] as? [String] ?? [])
    }

    func cancel() {
        let waiting = Array(operations.values); operations.removeAll()
        waiting.forEach { $0() }
        webView.stopLoading()
        finishNavigation(.failure(CancellationError()))
        webView.loadHTMLString("", baseURL: nil)
    }

    private func call(_ script: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try Task.checkCancellation()
        do {
            let value: Any = try await perform { completion in
                webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page, completionHandler: completion)
            }
            return value
        } catch {
            let failure = error as NSError
            if failure.domain == WKError.errorDomain,
               failure.code == WKError.javaScriptExceptionOccurred.rawValue,
               let detail = failure.userInfo["WKJavaScriptExceptionMessage"] as? String, !detail.isEmpty {
                throw BookPDFError.invalid("The book could not be rendered: \(detail)")
            }
            throw error
        }
    }

    /// WebKit does not reliably resume its async-JavaScript completion when navigation destroys
    /// a pending Promise. Own each continuation and retire it exactly once on cancellation.
    private func perform<T>(_ start: (@escaping @Sendable (Swift.Result<T, Error>) -> Void) -> Void) async throws -> T {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                operations[id] = { continuation.resume(throwing: CancellationError()) }
                start { [weak self] result in
                    Task { @MainActor in
                        guard self?.operations.removeValue(forKey: id) != nil else { return }
                        continuation.resume(with: result)
                    }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.operations.removeValue(forKey: id)?() } }
    }

    private func load() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                navigation = continuation
                navigationTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finishNavigation(.failure(BookPDFError.invalid("The book renderer did not load within 30 seconds.")))
                }
                webView.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    private func finishNavigation(_ result: Swift.Result<Void, Error>) {
        let waiting = navigation; navigation = nil
        navigationTimeout?.cancel(); navigationTimeout = nil
        waiting?.resume(with: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishNavigation(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishNavigation(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishNavigation(.failure(error)) }

    nonisolated private static func image(_ url: URL) async throws -> String {
        let data: Data
        if url.scheme == "data" {
            guard url.absoluteString.hasPrefix("data:image/"), let comma = url.absoluteString.firstIndex(of: ",") else { throw BookPDFError.invalid("Only image data URLs can be embedded.") }
            let payload = String(url.absoluteString[url.absoluteString.index(after: comma)...])
            guard let decoded = Data(base64Encoded: payload), decoded.count <= 24 * 1024 * 1024 else { throw BookPDFError.invalid("An inline illustration is invalid or too large.") }
            data = decoded
        } else if url.isFileURL {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 24 * 1024 * 1024 else { throw BookPDFError.invalid("Illustration \(url.lastPathComponent) exceeds 24 MB.") }
            data = try Data(contentsOf: url)
        } else {
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw BookPDFError.invalid("An illustration uses an unsupported URL scheme.") }
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 30; config.httpShouldSetCookies = false
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            let (temporary, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 24 * 1024 * 1024 else { throw BookPDFError.invalid("Illustration \(url.lastPathComponent) could not be downloaded or exceeds 24 MB.") }
            data = try Data(contentsOf: temporary)
        }
        if let text = String(data: data, encoding: .utf8), text.range(of: "<svg", options: .caseInsensitive) != nil {
            return "data:image/svg+xml;base64," + data.base64EncodedString()
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 4000, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw BookPDFError.invalid("Illustration \(url.lastPathComponent) is not a decodable image.")
        }
        let encoded = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { throw BookPDFError.invalid("An illustration could not be encoded.") }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw BookPDFError.invalid("An illustration could not be encoded.") }
        return "data:image/png;base64," + (encoded as Data).base64EncodedString()
    }
}
