import AppKit
import PDFKit
import SwiftUI
import XCTest
import MarkViewCore
@testable import MarkView

private enum PDFReaderTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    /// The native copy action uses the general pasteboard. Restore its representations
    /// immediately after each synchronous check rather than leaving test data there.
    @MainActor static func preservingPasteboard(_ body: () -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        body()
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
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
        try TabClosingStoreTests.run()
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
        let ingested = await FeatureAssistant.readableText(of: url)
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

        var opened: [URL] = []
        let view = PDFReaderPDFView(frame: NSRect(x: 170, y: 0, width: 750, height: 560), openExternal: { opened.append($0) })
        view.document = pdf
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(view)
        reader.attach(view)
        let requestsBeforeFind = reader.findRequest
        view.perform(PDFActionNamed(name: .find))
        check(reader.findRequest == requestsBeforeFind + 1, "PDF Find action reaches the attached reader")
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
        preservingPasteboard {
            NSPasteboard.general.clearContents()
            view.copy(nil)
            check(NSPasteboard.general.string(forType: .string)?.lowercased() == "needle", "embedded selection copies through native PDFView")
        }
        reader.search("not present in scan")
        try await waitUntil { !reader.searching }
        check(reader.matches.isEmpty, "no OCR text is invented for scanned pages")
        reader.search("FIRST")
        reader.search("LAST")
        try await waitUntil { !reader.searching }
        check(reader.matches.count == 1 && reader.matches[0].string == "LAST", "replacing a search cannot retain stale results")
        reader.search("")
        check(reader.matches.isEmpty && !reader.searching, "empty query clears search")

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
        // Retry and the password field start a load: a second one asked at once replaces the first, so the later password wins.
        let started = PDFReaderController()
        started.startLoad(protectedURL, password: "wrong")
        started.startLoad(protectedURL, password: "fixture-reader")
        try await waitUntil { !started.loading && started.document != nil }
        check(!started.locked && started.pageCount == 3 && started.error == nil, "two loads started at once end with the later one shown")
        let restricted = PDFReaderPDFView(frame: view.frame)
        restricted.document = protectedReader.document
        restricted.setCurrentSelection(protectedReader.document!.findString("needle", withOptions: []).first, animate: false)
        preservingPasteboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("copy-protected", forType: .string)
            restricted.copy(nil)
            check(NSPasteboard.general.string(forType: .string) == "copy-protected", "restricted document cannot copy to pasteboard")
        }
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
        let scannedIngest = await FeatureAssistant.readableText(of: scanURL)
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

/// The person is never asked anything while a PDF opens: any question is a failure of the check.
@MainActor
private struct NeverAsked: UserPrompts {
    func ask(_ prompt: UserPrompt) -> Int? { preconditionFailure("A PDF tab asks nothing, but it asked: \(prompt.title)") }
}

/// A PDF opens in a tab of its own on the shipping `TabsController`: no text, no save, no watcher, one tab per file.
private enum PDFReaderRoutingTests {
    @MainActor static func run() {
        let file = URL(fileURLWithPath: "/tmp/Read only.PDF")
        let tabs = TabsController(prompts: NeverAsked())
        tabs.openDocument(file)
        precondition(FileType.from(url: file) == .pdf && !FileType.hasTextSource(file))
        precondition(tabs.openTabs.count == 1 && tabs.activeTabIndex == 0)
        precondition(!tabs.openTabs[0].isFileBacked && tabs.openTabs[0].content.isEmpty)
        guard case .pdf = tabs.openTabs[0].kind else { preconditionFailure("Not a PDF reader tab") }
        let originalID = tabs.openTabs[0].id
        tabs.saveActiveFile()
        precondition(!FileManager.default.fileExists(atPath: file.path) && tabs.lastSaveError == nil, "saving a PDF tab writes nothing")
        tabs.openDocument(URL(fileURLWithPath: "/tmp/Another.pdf"))
        precondition(tabs.openTabs.count == 2 && tabs.activeTabIndex == 1)
        tabs.openDocument(file)
        precondition(tabs.openTabs.count == 2 && tabs.activeTabIndex == 0)
        precondition(tabs.openTabs[0].id == originalID)
        tabs.shutdown()
        print("PDF workspace routing: dedicated tabs, duplicate reuse, no text/save path passed")
    }
}

/// "Close Documents" on the shipping `OpenTab` and `TabsController`: which tabs are documents, and what stays open and active.
private enum TabClosingStoreTests {
    @MainActor static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markview-pdf-tabs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceManager(prompts: NoPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { workspace.windowWillClose() }
        let cache = try InsightCache(workspaceURL: root, sessionId: UUID(), pagePolicy: "test")
        let cockpitHost = CockpitHost(window: workspace, tabs: workspace.tabs, tools: workspace.toolTabs,
                                      qa: workspace.toolTabs.qa, features: workspace.flow.features, assistants: workspace.terminals)
        func tab(_ name: String, _ kind: TabKind) -> OpenTab {
            OpenTab(url: URL(fileURLWithPath: "/tmp/\(name)"), content: "", originalContent: "", kind: kind)
        }
        let pdfTabs = TabsController(prompts: NoPrompts())
        pdfTabs.openDocument(URL(fileURLWithPath: "/tmp/doc.pdf"))
        let documents = [tab("a.md", .file), tab("b.png", .image), pdfTabs.openTabs[0], tab("c.zip", .archive), tab("d.csv", .data)]
        let tools = [tab("t", .terminal(UUID())), tab("x", .architecture(scope: "")), tab("pr", .architecture(scope: XRayScope.pullRequest)),
                     tab("i", .insight(InsightSession(folderURL: root, mdFiles: [], graphRAG: nil, cache: cache))), tab("dep", .tool(.deployments)), tab("dis", .tool(.discussions)), tab("wf", .tool(.workflow)), tab("g", .tool(.git)),
                     tab("rev", .tool(.changeReview)), tab("gh", .github(.run(id: 1, repo: "o/r", title: "Run"))), tab("br", .browser(BrowserSession(url: nil, prompts: NoPrompts()))),
                     tab("p", .prototype(PrototypeSession(root: root, title: "p", brief: "", sources: []))), tab("ui", .uiStudio(StudioSession(root: root))), tab("ck", .cockpit(CockpitSession(root: root, workspace: cockpitHost))),
                     tab("qa", .tool(.qa))]
        precondition(documents.allSatisfy(\.isDocument), "file, image, PDF, archive and data tabs are documents")
        precondition(tools.allSatisfy { !$0.isDocument }, "every tool tab stays when documents close")

        func store(_ list: [OpenTab], active: Int) -> TabsController {
            let store = TabsController(prompts: NoPrompts())
            list.forEach { store.appendTab($0, activate: false) }
            store.activeTabIndex = active
            return store
        }
        let doc1 = documents[0], git = tools[7], doc2 = documents[1], doc3 = documents[3], workflow = tools[6], doc4 = documents[4]
        let mixed = [doc1, git, doc2, doc3, workflow, doc4]

        var s = store(mixed, active: 1)
        s.keepTabs { !$0.isDocument }
        precondition(s.openTabs.map(\.id) == [git.id, workflow.id], "only the tool tabs stay, in their order")
        precondition(s.activeTabIndex == 0, "an active tool tab stays active")

        s = store(mixed, active: 4)
        s.keepTabs { !$0.isDocument }
        precondition(s.activeTabIndex == 1 && s.openTabs[1].id == workflow.id, "the second tool tab stays active at its new index")

        s = store(mixed, active: 3)
        s.keepTabs { !$0.isDocument }
        precondition(s.activeTabIndex == 0 && s.openTabs[0].id == git.id, "a closed active document hands over to the nearest tool tab on its left")

        s = store(mixed, active: 0)
        s.keepTabs { !$0.isDocument }
        precondition(s.activeTabIndex == 0 && s.openTabs[0].id == git.id, "with no tool tab on its left the first one on its right takes over")

        s = store(documents, active: 2)
        s.keepTabs { !$0.isDocument }
        precondition(s.openTabs.isEmpty && s.activeTabIndex == -1, "with only documents open every tab closes and the Welcome tab is active")

        s = store(tools, active: 3)
        let before = s.openTabs.map(\.id)
        s.keepTabs { !$0.isDocument }
        precondition(s.openTabs.map(\.id) == before && s.activeTabIndex == 3, "with no document open nothing changes")

        s = store(mixed, active: -1)
        s.keepTabs { !$0.isDocument }
        precondition(s.activeTabIndex == -1 && s.openTabs.count == 2, "the Welcome tab stays active")
        print("Close Documents: every tab kind classified, tool tabs kept in order, active tab handed over correctly")
    }
}

private enum PDFReaderViewTests {
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

final class PDFReaderHostTests: XCTestCase {
    @MainActor func testPDFReaderAndWindowRouting() async throws {
        try await PDFReaderTests.run()
        print("PDF reader hosted checks: \(PDFReaderTests.checks)")
    }
}
