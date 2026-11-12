import AppKit
import PDFKit

@main
enum PDFReaderTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
                print("PDF reader checks: \(checks), failures: 0")
                exit(0)
            } catch {
                fputs("PDF reader checks failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "PDFReaderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native operation timed out"])
    }

    @MainActor static func fixture(scanned: Bool, text: String = "") -> PDFPage {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var box = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(box)
        if scanned {
            let image = NSImage(size: box.size, flipped: false) { rect in
                NSColor.systemBlue.setFill()
                rect.fill()
                NSColor.white.setFill()
                NSRect(x: 40, y: 100, width: 280, height: 35).fill()
                NSRect(x: 40, y: 180, width: 230, height: 35).fill()
                return true
            }
            var rect = box
            context.draw(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!, in: box)
        } else {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: NSPoint(x: 35, y: 500),
                withAttributes: [.font: NSFont(name: "Helvetica", size: 16)!, .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
        }
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)!.page(at: 0)!
    }

    @MainActor static func run() async throws {
        PDFReaderRoutingTests.run()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MarkView PDF reader \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Mixed document.PDF")
        let fixtureDocument = PDFDocument()
        fixtureDocument.insert(fixture(scanned: false, text: "FIRST embedded needle"), at: 0)
        fixtureDocument.insert(fixture(scanned: true), at: 1)
        fixtureDocument.insert(fixture(scanned: false, text: "LAST embedded needle"), at: 2)
        let first = fixtureDocument.page(at: 0)!, last = fixtureDocument.page(at: 2)!
        let target = PDFDestination(page: last, at: NSPoint(x: 0, y: 600))
        let outline = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "First chapter"
        chapter.destination = PDFDestination(page: first, at: NSPoint(x: 0, y: 600))
        let section = PDFOutline()
        section.label = "Last section"
        section.destination = target
        chapter.insertChild(section, at: 0)
        outline.insertChild(chapter, at: 0)
        fixtureDocument.outlineRoot = outline
        let link = PDFAnnotation(bounds: NSRect(x: 30, y: 450, width: 120, height: 25), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: target)
        first.addAnnotation(link)
        let external = PDFAnnotation(bounds: NSRect(x: 30, y: 410, width: 120, height: 25), forType: .link, withProperties: nil)
        external.action = PDFActionURL(url: URL(string: "https://example.com/reference")!)
        first.addAnnotation(external)
        let form = PDFAnnotation(bounds: NSRect(x: 30, y: 350, width: 150, height: 30), forType: .widget, withProperties: nil)
        form.widgetFieldType = .text
        form.fieldName = "Read-only fixture"
        form.widgetStringValue = "Do not change"
        first.addAnnotation(form)
        check(fixtureDocument.write(to: url), "fixture can be written")
        let original = try Data(contentsOf: url)
        let ingested = await ExistingPDFIngest.readableText(of: url)
        check(ingested.contains("FIRST") && ingested.contains("LAST"), "existing feature-source ingestion still extracts embedded text")

        let reader = PDFReaderController()
        reader.openPageWhenReady(3)
        await reader.load(url)
        check(!reader.loading && reader.error == nil && !reader.locked, "mixed PDF loads")
        check(reader.pageNumber == 3, "search result opens its page after asynchronous PDF loading")
        reader.openPageWhenReady(1)
        check(reader.pageNumber == 1, "search result opens its page in an already loaded PDF")
        let pdf = reader.document!
        check(pdf.pageCount == 3, "all pages retain their order")
        check(pdf.page(at: 0)!.string!.contains("FIRST") && pdf.page(at: 2)!.string!.contains("LAST"), "first and last embedded text survive")
        check(pdf.page(at: 1)!.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false, "scanned page has no extracted text")
        check(pdf.page(at: 1)!.selection(for: pdf.page(at: 1)!.bounds(for: .mediaBox))?.string?.isEmpty != false,
              "scanned page provides no recognized selection")
        for index in 0..<pdf.pageCount {
            let image = pdf.page(at: index)!.thumbnail(of: NSSize(width: 120, height: 180), for: .mediaBox)
            check(image.size.width > 0 && image.size.height > 0 && image.tiffRepresentation != nil, "every page, including scan, renders")
        }
        let widgets = pdf.page(at: 0)!.annotations.filter { $0.type == "Widget" }
        check(widgets.count == 1 && widgets[0].isReadOnly, "form fields are read-only")
        check(reader.outline.count == 1 && reader.outline[0].children?.count == 1, "hierarchical outline is preserved")

        let view = PDFReaderPDFView(frame: NSRect(x: 170, y: 0, width: 750, height: 560))
        view.document = pdf
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(view)
        reader.attach(view)
        view.layoutSubtreeIfNeeded()
        reader.setFit(.page)
        let pageScale = view.scaleFactor
        reader.setFit(.width)
        check(view.scaleFactor > pageScale, "fit width and fit page have distinct, usable scales")
        reader.zoom(by: 1.25)
        check(view.fitMode == .manual && view.scaleFactor > pageScale, "manual zoom works")
        reader.go(to: 3)
        check(reader.pageNumber == 3, "direct last-page navigation")
        reader.go(to: 0)
        reader.go(to: 4)
        check(reader.pageNumber == 3, "invalid page numbers are ignored")
        reader.go(to: 1)
        check(reader.pageNumber == 1, "can return to first page")
        reader.go(to: reader.outline[0].children![0].destination)
        check(reader.pageNumber == 3, "outline destination navigation")
        reader.go(to: 1)
        view.perform(pdf.page(at: 0)!.annotations.first { $0.action is PDFActionGoTo }!.action!)
        check(reader.pageNumber == 3, "internal link action navigates within document")
        view.perform(PDFActionNamed(name: .firstPage))
        check(reader.pageNumber == 1, "named page links work")
        let foreign = PDFDocument()
        foreign.insert(fixture(scanned: false, text: "Foreign"), at: 0)
        view.perform(PDFActionGoTo(destination: PDFDestination(page: foreign.page(at: 0)!, at: .zero)))
        check(reader.pageNumber == 1, "cross-document actions cannot escape the current document")

        let thumbnails = PDFThumbnailView(frame: NSRect(x: 0, y: 0, width: 160, height: 560))
        window.contentView!.addSubview(thumbnails)
        reader.bindThumbnails(thumbnails)
        reader.go(to: 2)
        check(thumbnails.pdfView === view && thumbnails.selectedPages?.first === pdf.page(at: 1), "native thumbnail navigation is bound to the current PDF")

        reader.search("needle")
        try await waitUntil { !reader.searching }
        check(reader.matches.count == 2, "search spans embedded text on both text pages, not image-only pages")
        reader.nextMatch(1)
        check(reader.pageNumber == 3 && reader.matchIndex == 1, "next match reveals last-page text")
        reader.nextMatch(1)
        check(reader.pageNumber == 1 && reader.matchIndex == 0, "search results wrap")
        reader.nextMatch(-1)
        check(reader.pageNumber == 3, "previous match wraps backwards")
        NSPasteboard.general.clearContents()
        view.copy(nil)
        check(NSPasteboard.general.string(forType: .string)?.lowercased() == "needle", "embedded selection copies through native PDFView")
        reader.search("not present in scan")
        try await waitUntil { !reader.searching }
        check(reader.matches.isEmpty, "no OCR text is invented for scanned pages")
        reader.search("FIRST")
        reader.search("LAST")
        try await waitUntil { !reader.searching }
        check(reader.matches.count == 1 && reader.matches[0].string == "LAST", "replacing a search cannot retain stale results")
        reader.search("")
        check(reader.matches.isEmpty && !reader.searching, "empty query clears search")

        var opened: [URL] = []
        view.openExternal = { opened.append($0) }
        for address in ["https://example.com/reference", "http://localhost:8080/a", "mailto:reader@example.com"] {
            let addressURL = URL(string: address)!
            check(PDFReaderLinks.allows(addressURL), "normal external link is permitted")
            view.perform(PDFActionURL(url: addressURL))
        }
        for address in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,test", "markview:run",
                        "https://user:password@example.com", "https:/missing-host", "relative.pdf", "mailto:",
                        "https://example.com/%0Acommand", "mailto:reader@example.com?subject=%0D%0Ainjected"] {
            let addressURL = URL(string: address)!
            check(!PDFReaderLinks.allows(addressURL), "untrusted external link is blocked")
            view.perform(PDFActionURL(url: addressURL))
        }
        check(opened.count == 3, "only allowlisted link actions reach the external opener")
        reader.pdfViewWillClick(onLink: view, with: URL(string: "file:///etc/passwd")!)
        check(opened.count == 3, "native URL delegate cannot bypass the link policy")

        let protectedURL = root.appendingPathComponent("Protected.pdf")
        check(fixtureDocument.write(to: protectedURL, withOptions: [
            .ownerPasswordOption: "fixture-owner",
            .userPasswordOption: "fixture-reader",
            .accessPermissionsOption: NSNumber(value: 0)
        ]), "protected fixture can be written")
        let protectedOriginal = try Data(contentsOf: protectedURL)
        let protectedReader = PDFReaderController()
        await protectedReader.load(protectedURL)
        check(protectedReader.locked && !protectedReader.canCopy, "locked PDF gets an explicit password state")
        await protectedReader.load(protectedURL, password: "wrong")
        check(protectedReader.locked && protectedReader.error != nil, "incorrect password is reported")
        await protectedReader.load(protectedURL, password: "fixture-reader")
        check(!protectedReader.locked && protectedReader.pageCount == 3 && !protectedReader.canCopy, "user password unlocks reading without overriding copy restrictions")
        let restricted = PDFReaderPDFView(frame: view.frame)
        restricted.document = protectedReader.document
        restricted.setCurrentSelection(protectedReader.document!.findString("needle", withOptions: []).first, animate: false)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("copy-protected", forType: .string)
        restricted.copy(nil)
        check(NSPasteboard.general.string(forType: .string) == "copy-protected", "restricted document cannot copy to pasteboard")
        let protectedAfter = try Data(contentsOf: protectedURL)
        check(protectedAfter == protectedOriginal, "unlocking never rewrites the PDF")

        let scanURL = root.appendingPathComponent("Scan.pdf")
        let scan = PDFDocument()
        scan.insert(fixture(scanned: true), at: 0)
        scan.insert(fixture(scanned: true), at: 1)
        check(scan.write(to: scanURL), "scan fixture can be written")
        let scanReader = PDFReaderController()
        await scanReader.load(scanURL)
        check(scanReader.pageCount == 2 && scanReader.outline.isEmpty, "image-only PDF without outline loads completely")
        scanReader.search("needle")
        try await waitUntil { !scanReader.searching }
        check(scanReader.matches.isEmpty, "image-only PDF has no text-search matches")
        let scannedIngest = await ExistingPDFIngest.readableText(of: scanURL)
        check(scannedIngest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              "unchanged feature-source ingestion performs no OCR on scans")

        let malformed = root.appendingPathComponent("Broken.pdf")
        try Data("not a PDF".utf8).write(to: malformed)
        for invalid in [malformed, root.appendingPathComponent("Missing.pdf"), root, URL(string: "https://example.com/document.pdf")!] {
            let failed = PDFReaderController()
            await failed.load(invalid)
            check(failed.document == nil && failed.error != nil && !failed.loading, "invalid or unavailable PDF fails explicitly")
        }
        let unreadable = root.appendingPathComponent("Unreadable.pdf")
        try original.write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        let deniedReader = PDFReaderController()
        await deniedReader.load(unreadable)
        check(deniedReader.error != nil && deniedReader.document == nil, "file access denial is explicit")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        let empty = root.appendingPathComponent("Empty.pdf")
        var emptyPDF = "%PDF-1.4\n"
        var offsets = [0]
        for object in ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 0 /Kids [] >>"] {
            offsets.append(emptyPDF.utf8.count)
            emptyPDF += "\(offsets.count - 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = emptyPDF.utf8.count
        emptyPDF += "xref\n0 3\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { emptyPDF += String(format: "%010d 00000 n \n", offset) }
        emptyPDF += "trailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(emptyPDF.utf8).write(to: empty)
        let emptyReader = PDFReaderController()
        await emptyReader.load(empty)
        check(emptyReader.error != nil && emptyReader.document == nil, "zero-page document cannot silently display a blank reader")
        let after = try Data(contentsOf: url)
        check(after == original, "all reading, searching, copying and navigation preserve exact source bytes")
        reader.go(to: 3)
        let replacement = PDFReaderPDFView(frame: view.frame)
        replacement.document = reader.document
        window.contentView!.addSubview(replacement)
        reader.attach(replacement)
        check(reader.pageNumber == 3 && replacement.currentPage === pdf.page(at: 2), "switching tabs restores the PDF's current page")
        view.goToFirstPage(nil)
        check(reader.pageNumber == 3, "a detached view cannot update the tab's reading position")
        window.close()
        try await PDFReaderViewTests.run(url: url)
    }
}
