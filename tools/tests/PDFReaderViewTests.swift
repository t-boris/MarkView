import SwiftUI
import PDFKit

// Styling is incidental to the standalone native view integration check: the view draws with the default palette.

extension View {
    func uiFont(size: CGFloat, design: Font.Design = .default) -> some View {
        font(.system(size: size, design: design))
    }
}

enum PDFReaderViewTests {
    @MainActor static func run(url: URL) async throws {
        let reader = PDFReaderController()
        await reader.load(url)
        let hosting = NSHostingView(rootView: PDFReaderView(url: url, reader: reader))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        hosting.layoutSubtreeIfNeeded()
        try await PDFReaderTests.waitUntil {
            hosting.layoutSubtreeIfNeeded()
            let views = descendants(hosting)
            guard let canvas = views.compactMap({ $0 as? PDFReaderPDFView }).first,
                  let thumbnails = views.compactMap({ $0 as? PDFThumbnailView }).first else { return false }
            return canvas.document === reader.document && thumbnails.pdfView === canvas
        }
        PDFReaderTests.check(reader.pageCount == 3, "shipping SwiftUI reader mounts both the native document and thumbnails")
        reader.go(to: 3)
        PDFReaderTests.check(reader.pageNumber == 3, "mounted SwiftUI reader responds to controller navigation")
        print("PDF SwiftUI integration: document canvas, thumbnails and controls mounted successfully")
    }
}
