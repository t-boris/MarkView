import AppKit
import PDFKit
import WebKit

extension BrowserSession {
    enum PDFError: LocalizedError {
        case empty
        var errorDescription: String? { "The page has nothing to put into a PDF yet. Wait for it to load and try again." }
    }

    /// A4-proportioned pages of the whole page as it is shown (not only the visible part). WebKit
    /// draws any rectangle of the page, so each page is its own slice: no single huge canvas.
    func pagePDF(maxPages: Int = 300) async throws -> Data {
        let size = try await webView.callAsyncJavaScript(
            """
            const d = document.documentElement, b = document.body;
            return [Math.max(d.scrollWidth, b ? b.scrollWidth : 0), Math.max(d.scrollHeight, b ? b.scrollHeight : 0)];
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [Any]
        guard let size, size.count == 2, let width = (size[0] as? NSNumber)?.doubleValue,
              let height = (size[1] as? NSNumber)?.doubleValue, width > 0, height > 0 else { throw PDFError.empty }
        let pageHeight = (width * 842 / 595).rounded()
        let document = PDFDocument()
        var top = 0.0
        while top < height, document.pageCount < maxPages {
            // A sliver of the last page is not worth a page of its own.
            let slice = height - top < 24 ? 0 : min(pageHeight, height - top)
            if slice == 0 { break }
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: top, width: width, height: slice)
            let data = try await webView.pdf(configuration: configuration)
            if let page = PDFDocument(data: data)?.page(at: 0) { document.insert(page, at: document.pageCount) }
            top += pageHeight
        }
        guard document.pageCount > 0, let data = document.dataRepresentation() else { throw PDFError.empty }
        return data
    }
}
