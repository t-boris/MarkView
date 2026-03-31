import Foundation
import WebKit
import SwiftUI
import UniformTypeIdentifiers
import CoreGraphics

/// Handles PDF export by rendering in an off-screen A4-width WebView,
/// capturing a single tall page, then splitting into A4 pages via Core Graphics.
class PDFExporter {

    private static let a4Width: CGFloat = 595
    private static let a4Height: CGFloat = 842
    private static let margin: CGFloat = 40

    private static var pdfWebView: WKWebView?
    private static var pdfDelegate: PDFNavigationDelegate?

    @MainActor
    static func exportPDF(
        from webView: WKWebView,
        fileName: String = "document.pdf",
        bridge: WebViewBridge
    ) {
        // Get the rendered HTML directly — no need to change the main view's layout
        // since we render PDF in a separate off-screen WebView
        webView.evaluateJavaScript("document.querySelector('.editor-rendered').innerHTML") { result, error in
            guard let renderedHTML = result as? String, !renderedHTML.isEmpty else {
                showError("No rendered content available.")
                return
            }

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.pdf]
            savePanel.nameFieldStringValue = fileName
            savePanel.canCreateDirectories = true

            savePanel.begin { response in
                guard response == .OK, let url = savePanel.url else { return }
                generatePDF(html: renderedHTML, to: url, baseURL: webView.url)
            }
        }
    }

    @MainActor
    private static func generatePDF(html: String, to url: URL, baseURL: URL?) {
        let fullHTML = buildPrintDocument(body: html)

        let config = WKWebViewConfiguration()
        let offscreen = WKWebView(
            frame: CGRect(x: -9999, y: -9999, width: a4Width, height: a4Height),
            configuration: config
        )

        let delegate = PDFNavigationDelegate { [weak offscreen] in
            guard let offscreen = offscreen else { return }

            // Get full content height, then expand WebView to show ALL content
            offscreen.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                let contentHeight = max(
                    (result as? CGFloat) ?? a4Height,
                    (result as? Int).map({ CGFloat($0) }) ?? a4Height,
                    a4Height
                )

                // Expand to full content height so everything is rendered
                offscreen.frame = CGRect(x: -9999, y: -9999, width: a4Width, height: contentHeight + 100)

                // Wait for layout at the expanded height
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    Task {
                        do {
                            // Capture the ENTIRE content as one tall page (rect = .zero)
                            let tallConfig = WKPDFConfiguration()
                            let tallData = try await offscreen.pdf(configuration: tallConfig)

                            // Split the tall page into A4-sized pages
                            let a4Data = splitIntoA4Pages(tallPDFData: tallData)
                            try a4Data.write(to: url)
                            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                        } catch {
                            showError(error.localizedDescription)
                        }

                        pdfWebView = nil
                        pdfDelegate = nil
                    }
                }
            }
        }

        pdfWebView = offscreen
        pdfDelegate = delegate
        offscreen.navigationDelegate = delegate
        offscreen.loadHTMLString(fullHTML, baseURL: baseURL)
    }

    // MARK: - Split tall PDF into A4 pages

    /// Takes a single-page tall PDF and splits it into multiple A4-sized pages
    private static func splitIntoA4Pages(tallPDFData: Data) -> Data {
        guard let provider = CGDataProvider(data: tallPDFData as CFData),
              let document = CGPDFDocument(provider),
              let tallPage = document.page(at: 1) else {
            return tallPDFData
        }

        let mediaBox = tallPage.getBoxRect(.mediaBox)
        let totalHeight = mediaBox.height
        let totalWidth = mediaBox.width

        // If content fits on one page, return as-is but with proper A4 dimensions
        if totalHeight <= a4Height + 10 {
            return tallPDFData
        }

        let pageCount = Int(ceil(totalHeight / a4Height))

        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            return tallPDFData
        }

        var firstPageRect = CGRect(x: 0, y: 0, width: totalWidth, height: a4Height)
        guard let context = CGContext(consumer: consumer, mediaBox: &firstPageRect, nil) else {
            return tallPDFData
        }

        for i in 0..<pageCount {
            var pageRect = CGRect(x: 0, y: 0, width: totalWidth, height: a4Height)
            context.beginPage(mediaBox: &pageRect)

            // Clip to page bounds
            context.clip(to: pageRect)

            // Calculate translation:
            // PDF origin is bottom-left. The "top" of the document is at y = totalHeight.
            // For page i (0 = top of document), show content from:
            //   y_bottom = totalHeight - (i+1)*a4Height
            //   y_top    = totalHeight - i*a4Height
            // We translate so context y=0 maps to y_bottom in the tall page.
            let yTranslate = CGFloat(i + 1) * a4Height - totalHeight
            context.translateBy(x: 0, y: yTranslate)

            context.drawPDFPage(tallPage)
            context.endPage()
        }

        context.closePDF()
        return mutableData as Data
    }

    // MARK: - Print HTML template

    private static func buildPrintDocument(body: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>
            * { box-sizing: border-box; }
            html, body {
                margin: 0; padding: 0;
                width: \(Int(a4Width))px;
                font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
                font-size: 9px; line-height: 1.5; color: #1a1a1a; background: #fff;
            }
            body { padding: \(Int(margin))px; }

            h1 { font-size: 1.8em; border-bottom: 2px solid #ddd; padding-bottom: 0.3em; margin-top: 1.5em; }
            h2 { font-size: 1.5em; border-bottom: 1px solid #ddd; padding-bottom: 0.3em; margin-top: 1.5em; }
            h3 { font-size: 1.3em; margin-top: 1.3em; }
            h4 { font-size: 1.1em; margin-top: 1.2em; }

            p { margin: 0.8em 0; }
            a { color: #0066cc; text-decoration: none; }
            strong { font-weight: 600; }
            hr { border: none; border-top: 1px solid #ddd; margin: 1.5em 0; }

            ul, ol { padding-left: 2em; margin: 0.8em 0; }
            li { margin: 0.3em 0; }

            code {
                background: #f0f0f0; padding: 2px 5px; border-radius: 3px;
                font-family: Menlo, Monaco, monospace; font-size: 0.9em;
            }
            pre {
                background: #282c34; color: #abb2bf; border-radius: 6px;
                padding: 14px; overflow: hidden;
                white-space: pre-wrap; word-break: break-word;
                font-size: 8px; line-height: 1.4;
            }
            pre code { background: transparent; color: inherit; padding: 0; }

            table {
                border-collapse: collapse; width: 100%; table-layout: fixed;
                word-break: break-word; margin: 1em 0; font-size: 8px;
            }
            th, td { border: 1px solid #ddd; padding: 8px 10px; text-align: left; }
            th { background: #f5f5f5; font-weight: 600; }

            blockquote {
                margin: 1em 0; padding: 0.5em 1em;
                border-left: 4px solid #0066cc; color: #555;
            }

            img { max-width: 100%; height: auto; }

            .mermaid, .mermaid svg { max-width: 100%; overflow: visible; }

            ul.task-list { list-style: none; padding-left: 1.5em; }
            .task-list-item { display: flex; align-items: center; gap: 6px; }

            .admonition {
                margin: 1em 0; padding: 10px 14px;
                border-left: 4px solid #0066cc; border-radius: 4px; background: #f8f8f8;
            }
            .admonition-title { font-weight: 600; margin-bottom: 6px; font-size: 0.85em; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func showError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "PDF Export Failed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

// MARK: - Navigation delegate for the off-screen PDF WebView

private class PDFNavigationDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
}
