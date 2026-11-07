import AppKit
import PDFKit

// App types the exporter's entry points mention; the checks drive `PDFExporter.render` only.
enum TabKind { case file, insight(Int), other }
struct OpenTab { var url: URL; var content: String; var kind: TabKind }

/// Checks the PDF of a single document, made by the bundled PDF-book engine in its "document" mode, in real WebKit.
/// Run through tools/tests/pdf-export-tests.sh.
@main
enum PDFExportTests {
    @MainActor static var failures = 0

    @MainActor static func check(_ ok: Bool, _ message: String, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "ok  " : "FAIL") \(message)\(ok ? "" : " — " + String(detail().prefix(500)))")
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print(failures == 0 ? "PDF export checks passed." : "\(failures) PDF export check(s) failed."); exit(failures == 0 ? 0 : 1) }
            catch { print("PDF export check failed to run: \(error)"); exit(1) }
        }
        app.run()
    }

    // MARK: - Reading a PDF

    struct Pixel { var r: Double, g: Double, b: Double }

    static func raster(_ page: PDFPage) -> NSBitmapImageRep {
        let box = page.bounds(for: .mediaBox)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width), pixelsHigh: Int(box.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: box.width, height: box.height).fill()
        page.draw(with: .mediaBox, to: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Pixel {
        let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .black
        return Pixel(r: Double(color.redComponent * 255), g: Double(color.greenComponent * 255), b: Double(color.blueComponent * 255))
    }

    static func near(_ a: Pixel, _ r: Double, _ g: Double, _ b: Double, tolerance: Double = 6) -> Bool {
        abs(a.r - r) <= tolerance && abs(a.g - g) <= tolerance && abs(a.b - b) <= tolerance
    }

    /// Pixels in the outer strips of a page that differ from the page background: anything printed there was cut or ran past the margin.
    static func marginInk(_ rep: NSBitmapImageRep, background: Pixel, side: Int = 40, vertical: Int = 24) -> Int {
        var count = 0
        let w = rep.pixelsWide, h = rep.pixelsHigh
        for y in 0..<h {
            for x in 0..<w where x < side || x >= w - side || y < vertical || y >= h - vertical {
                if !near(pixel(rep, x, y), background.r, background.g, background.b, tolerance: 8) { count += 1 }
            }
        }
        return count
    }

    final class Counter { var count = 0 }

    /// The picture objects in the resources of a page (vector drawings and text are not counted).
    static func imageCount(_ page: PDFPage) -> Int {
        guard let cgPage = page.pageRef, let dictionary = cgPage.dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return 0 }
        let counter = Counter()
        CGPDFDictionaryApplyFunction(objects, { _, object, info in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let streamDictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" {
                Unmanaged<Counter>.fromOpaque(info!).takeUnretainedValue().count += 1
            }
        }, Unmanaged.passUnretained(counter).toOpaque())
        return counter.count
    }

    static func text(_ pdf: PDFDocument, page index: Int) -> String { pdf.page(at: index)?.string ?? "" }
    static func fullText(_ pdf: PDFDocument) -> String { (0..<pdf.pageCount).map { text(pdf, page: $0) }.joined(separator: "\n") }
    /// Text without any white space: a title or a long word wraps, and the extracted text then has a line break inside it. A word set with
    /// wide letter spacing (the kind of document on the title page) is extracted with spaces between its letters by some macOS versions.
    static func squashed(_ value: String) -> String { value.filter { !$0.isWhitespace } }
    static func has(_ haystack: String, _ needle: String) -> Bool { squashed(haystack).contains(squashed(needle)) }

    // MARK: - Documents

    static func chapter(_ markdown: String, in folder: URL, name: String = "document.md", format: String = "markdown") -> BookPDFChapter {
        let url = folder.appendingPathComponent(name)
        return BookPDFChapter(id: "c0", url: url, path: name, title: (name as NSString).deletingPathExtension, format: format, text: markdown, original: markdown)
    }

    static func make(_ chapter: BookPDFChapter, _ style: PDFExporter.Style = .init(), folder: URL, roots: [URL]) async throws -> (PDFDocument, BookPDFRenderer.Result) {
        let entry = URL(fileURLWithPath: CommandLine.arguments[1])
        let result = try await PDFExporter.render(chapter, style: style, entry: entry) { PDFExporter.allows($0, within: roots) }
        guard let pdf = PDFDocument(data: result.data) else { throw BookPDFError.invalid("The result is not a PDF.") }
        return (pdf, result)
    }

    @MainActor static func run() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // The fixture and its pictures are copied, so a picture outside the allowed folder can be placed next to it.
        let work = output.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        let docs = work.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        for name in ["wide.png", "tall.png", "small.png", "showcase.md"] {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: docs.appendingPathComponent(name))
        }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("small.png"), to: work.appendingPathComponent("outside.png"))
        let showcase = try String(contentsOf: docs.appendingPathComponent("showcase.md"), encoding: .utf8)

        // 1. The showcase document in the default style (paper, A4).
        let started = Date()
        let (pdf, result) = try await make(chapter(showcase, in: docs, name: "showcase.md"), folder: docs, roots: [docs])
        try result.data.write(to: output.appendingPathComponent("showcase-paper.pdf"))
        print("    showcase: \(pdf.pageCount) pages in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        let all = fullText(pdf)
        check(pdf.pageCount >= 10, "the showcase makes a document of several pages", "\(pdf.pageCount) pages")
        let sizes = Set((0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.bounds(for: .mediaBox).size }.map { "\(Int($0.width))x\(Int($0.height))" })
        check(sizes == ["595x842"], "every page is exactly A4, however wide a diagram or a table is", "\(sizes)")

        let cover = text(pdf, page: 0)
        check(has(cover, "Quarterly Platform Review") && cover.contains("Boris Tsekinovsky") && has(cover, "DOCUMENT"),
              "the title page has the title, the author and the kind of document from the front matter", cover)
        check(!cover.contains("Metadata") && !all.contains("title: Quarterly"), "the front matter is not printed as a table or as text", String(all.prefix(300)))
        check(text(pdf, page: 1).contains("Contents") && text(pdf, page: 1).contains("Summary"), "a long document has a contents page after the title page", text(pdf, page: 1))
        let titleCount = squashed(all).components(separatedBy: squashed("Quarterly Platform Review")).count - 1
        check(titleCount == pdf.pageCount, "the title is on the title page once and in the running head of every other page, never repeated as a heading",
              "\(titleCount) times on \(pdf.pageCount) pages")
        check(text(pdf, page: 2).contains("3 / \(pdf.pageCount)"), "the footer has the page number and the number of pages", text(pdf, page: 2))
        check((2..<pdf.pageCount).contains { text(pdf, page: $0).contains("Results") && text(pdf, page: $0).contains(" / ") },
              "the running head names the section of the page")

        // Nothing is lost and nothing is torn.
        for needle in ["gateway-public-edge", "billing-reconciliation-worker", "search-indexer", "Edge cache", "Object store", "handler_00", "handler_69",
                       "Paragraph 14.", "A footnote that explains", "The end.", "p99 latency"] {
            check(has(all, needle), "the text “\(needle)” is in the PDF")
        }
        check(all.components(separatedBy: "Paragraph ").count - 1 >= 14, "every long paragraph is printed")
        var imageTotal = 0
        for index in 0..<pdf.pageCount { imageTotal += imageCount(pdf.page(at: index)!) }
        check(imageTotal >= 3, "the three pictures are in the PDF as pictures", "\(imageTotal) image objects")
        check(result.warnings.allSatisfy { !$0.hasPrefix("A picture") && !$0.hasPrefix("A diagram") }, "no picture or diagram was lost", "\(result.warnings)")

        // The background, and margins that stay empty on every page but the title page.
        let paper = Pixel(r: 251, g: 248, b: 241)
        let coverRaster = raster(pdf.page(at: 0)!)
        check(near(pixel(coverRaster, 300, 40), 26, 100, 100, tolerance: 10), "the title page has a colour band at the top",
              "\(pixel(coverRaster, 300, 40))")
        check(near(pixel(coverRaster, 300, 760), paper.r, paper.g, paper.b), "the title page has the paper background below the band", "\(pixel(coverRaster, 300, 760))")
        var dirty: [String] = []
        for index in 1..<pdf.pageCount {
            let rep = raster(pdf.page(at: index)!)
            if !near(pixel(rep, 6, 420), paper.r, paper.g, paper.b) { dirty.append("page \(index + 1) background \(pixel(rep, 6, 420))") }
            let ink = marginInk(rep, background: paper)
            if ink > 0 { dirty.append("page \(index + 1): \(ink) pixels in the margins") }
        }
        check(dirty.isEmpty, "every page has the paper background and nothing is printed in its outer margins", dirty.joined(separator: "; "))

        // Bookmarks and links.
        let outline = pdf.outlineRoot
        check((outline?.numberOfChildren ?? 0) >= 6, "the PDF has bookmarks for the headings", "\(outline?.numberOfChildren ?? 0)")
        var links: [PDFAnnotation] = []
        for index in 0..<pdf.pageCount { links += pdf.page(at: index)!.annotations.filter { $0.type == "Link" } }
        check(links.contains { $0.action is PDFActionGoTo }, "the contents entries are links to their pages")
        check(links.contains { ($0.action as? PDFActionURL)?.url?.absoluteString == "https://example.com/platform" }, "an address in the text stays a working link")
        check(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Quarterly Platform Review", "the PDF's title is the document's title",
              "\(String(describing: pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute]))")

        // 2. The same document in the other styles and on other paper.
        let (white, _) = try await make(chapter(showcase, in: docs, name: "showcase.md"), .init(theme: "white", paper: "letter"), folder: docs, roots: [docs])
        try white.dataRepresentation()?.write(to: output.appendingPathComponent("showcase-white-letter.pdf"))
        check(white.page(at: 3)!.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792), "US Letter paper gives Letter pages")
        check(near(pixel(raster(white.page(at: 3)!), 6, 400), 255, 255, 255), "the white style has a white page")
        let (night, _) = try await make(chapter(showcase, in: docs, name: "showcase.md"), .init(theme: "midnight", paper: "a4Landscape"), folder: docs, roots: [docs])
        try night.dataRepresentation()?.write(to: output.appendingPathComponent("showcase-midnight-landscape.pdf"))
        check(night.page(at: 3)!.bounds(for: .mediaBox).size == CGSize(width: 842, height: 595), "A4 Landscape gives landscape pages")
        check(near(pixel(raster(night.page(at: 3)!), 6, 300), 23, 34, 43), "the midnight style has a dark page")
        let nightInk = marginInk(raster(night.page(at: 3)!), background: Pixel(r: 23, g: 34, b: 43))
        check(nightInk == 0, "nothing is printed in the margins of a landscape page", "\(nightInk) pixels")

        // 3. A short document has no contents page; a diagram or a picture that cannot be drawn does not stop it.
        let short = """
        # A short note

        Just two paragraphs.

        Second paragraph with a [link](https://example.com).

        ![gone](missing.png)

        ![outside](../outside.png)

        ```mermaid
        graph TD
          A --> ;;; broken [[[
        ```
        """
        let (note, noteResult) = try await make(chapter(short, in: docs, name: "note.md"), folder: docs, roots: [docs])
        try note.dataRepresentation()?.write(to: output.appendingPathComponent("note.pdf"))
        check(note.pageCount == 2, "a short document is the title page and one page, without a contents page", "\(note.pageCount) pages")
        check(!fullText(note).contains("Contents") && fullText(note).contains("A short note"), "…and its first heading is its title")
        check(has(fullText(note), "Picture not available: missing.png"), "a picture that does not exist is replaced by a note naming it", fullText(note))
        check(has(fullText(note), "Picture not available: outside.png"), "a picture outside the folders the document may use is not read", fullText(note))
        check(fullText(note).contains("A --> ;;; broken"), "a diagram that cannot be drawn stays as its source", fullText(note))
        check(noteResult.warnings.contains { $0.hasPrefix("A picture") } && noteResult.warnings.contains { $0.hasPrefix("A diagram") },
              "…and both are reported", "\(noteResult.warnings)")

        // A formula is laid out by the inline styles of KaTeX: a superscript stands higher than its base, a fraction has its bar.
        let formulas = "# Formulas\n\nPower: $ZW^{Q}$ and a fraction $\\frac{ZA}{ZB}$.\n\n$$\\sqrt{ZC} + ZD_{ZE}$$\n"
        let (math, _) = try await make(chapter(formulas, in: docs, name: "math.md"), folder: docs, roots: [docs])
        try math.dataRepresentation()?.write(to: output.appendingPathComponent("math.pdf"))
        check(has(fullText(math), "ZWQ") || has(fullText(math), "ZW"), "the letters of the formulas are in the PDF", fullText(math))
        // …and the sanitizer keeps what KaTeX lays a formula out with (the inline styles, the radical's path).
        var probeOptions = BookPDFOptions()
        probeOptions.mode = "document"
        probeOptions.title = "Formulas"
        let probe = try BookPDFRenderer(entry: URL(fileURLWithPath: CommandLine.arguments[1]))
        _ = try await probe.prepare([chapter(formulas, in: docs, name: "math.md")], options: probeOptions)
        let styled = try await probe.webView.callAsyncJavaScript("return document.querySelectorAll('#source .katex-html [style]').length", in: nil, contentWorld: .page) as? Int ?? 0
        let paths = try await probe.webView.callAsyncJavaScript("return document.querySelectorAll('#source .katex-html svg path[d]').length", in: nil, contentWorld: .page) as? Int ?? 0
        let handlers = try await probe.webView.callAsyncJavaScript("return document.querySelectorAll('#source [onerror], #source [onclick], #source [href^=javascript]').length", in: nil, contentWorld: .page) as? Int ?? -1
        check(styled >= 6 && paths >= 1, "a formula keeps its inline styles and the path of its radical", "\(styled) styled elements, \(paths) paths")
        check(handlers == 0, "no script attribute survives in a formula or anywhere else", "\(handlers)")
        let hostile = "# Hostile\n\n<span class=\"katex\" onclick=\"alert(1)\" style=\"background:url(http://example.com/x)\">x</span> <img class=\"katex\" src=\"x\" onerror=\"alert(2)\">\n\n"
            + "<span class=\"katex\" style=\"display:none\">HIDDEN</span> <span class=\"katex\" style=\"position:fixed;background:u\\72l(http://example.com/y)\">FIXED</span> <span class=\"katex\" style=\"background:image-set('http://example.com/z' 1x)\">SET</span> <span class=\"katex\" style=\"height:1em;vertical-align:-0.2em\">KEPT</span>\n"
        _ = try await probe.prepare([chapter(hostile, in: docs, name: "hostile.md")], options: probeOptions)
        let kept = try await probe.webView.callAsyncJavaScript("return document.querySelectorAll('#source [onerror], #source [onclick], #source [style*=\"url(\"]').length", in: nil, contentWorld: .page) as? Int ?? -1
        check(kept == 0, "a hostile element that wears the class of a formula keeps neither its handler nor a style that loads a resource", "\(kept)")
        let styles = try await probe.webView.callAsyncJavaScript("return Array.from(document.querySelectorAll('#source span.katex')).map(n => n.getAttribute('style') || '').join(' | ')", in: nil, contentWorld: .page) as? String ?? ""
        check(!styles.contains("display") && !styles.contains("position") && !styles.contains("image") && !styles.contains("72l") && styles.contains("height:1em"),
              "…and only the sizes, offsets and colours of a formula survive in a style, however the rest is written", styles)

        // The rule that decides which picture files may be read.
        let evil = docs.deletingLastPathComponent().appendingPathComponent(docs.lastPathComponent + "-evil/x.png")
        let escape = docs.appendingPathComponent("escape.png")
        try? FileManager.default.removeItem(at: escape)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let inside = docs.appendingPathComponent("wide.png")
        check(PDFExporter.allows(inside, within: [docs]) && PDFExporter.allows(inside, within: [docs.appendingPathComponent("../" + docs.lastPathComponent)]),
              "a picture inside an allowed folder is allowed (also when the folder is written with a detour)",
              "\(PDFExporter.allows(inside, within: [docs])) \(PDFExporter.allows(inside, within: [docs.appendingPathComponent("../" + docs.lastPathComponent)])) \(inside.path) in \(docs.path)")
        check(!PDFExporter.allows(evil, within: [docs]), "a folder whose name only begins like an allowed folder is not allowed")
        check(!PDFExporter.allows(escape, within: [docs]), "a link inside an allowed folder that leads out of it is not allowed")
        try? FileManager.default.removeItem(at: escape)

        // Documents of an unusual shape are still printed, never refused.
        let long = String(repeating: "A very long title that goes on and on ", count: 5)
        let shapes: [(String, String)] = [
            ("an empty file", ""),
            ("a file without headings", "Only a paragraph.\n\nAnother paragraph with **bold** text.\n"),
            ("a document that starts with a second-level heading", "## Part one\n\nText.\n\n## Part two\n\nMore text.\n"),
            ("a document with a very long title", "---\ntitle: \(long)\n---\n\nBody text.\n"),
            ("a title and nothing else", "# Only a title\n"),
            ("a document with a title of 700 characters", "# " + String(repeating: "Endless title ", count: 50) + "\n\nBody.\n"),
            ("a picture with an address that is not a URL", "# Pictures\n\n![broken](https://) and <img src=\"http://[::1\"> and ![none]()\n\nText after.\n"),
            ("a title in a folded front matter value", "---\ntitle: >-\n  A title written over\n  two lines\n---\n\nBody text.\n"),
            ("a table without a header row and a list of 80 items", "| a | b |\n|---|---|\n| 1 | 2 |\n\n" + (1...80).map { "- item \($0)" }.joined(separator: "\n") + "\n"),
        ]
        // A very long title is set smaller so that it stays on the colour band (white text on the paper would be invisible).
        let (longTitled, _) = try await make(chapter("---\ntitle: \(long)\nsubtitle: A subtitle that also has to stay on the band\n---\n\nBody text.\n", in: docs, name: "long.md"), folder: docs, roots: [docs])
        try longTitled.dataRepresentation()?.write(to: output.appendingPathComponent("long-title.pdf"))
        let longRaster = raster(longTitled.page(at: 0)!)
        var whiteOnPaper = 0
        for y in stride(from: 430, to: 600, by: 1) { for x in 40..<560 where near(pixel(longRaster, x, y), 255, 255, 255, tolerance: 4) { whiteOnPaper += 1 } }
        check(whiteOnPaper == 0, "a very long title does not run out of the colour band", "\(whiteOnPaper) white pixels below the band")
        check(has(text(longTitled, page: 0), "A subtitle that also has to stay on the band"), "…and the subtitle is on the title page")
        for (name, source) in shapes {
            do {
                let (shaped, _) = try await make(chapter(source, in: docs, name: "shape.md"), folder: docs, roots: [docs])
                check(shaped.pageCount >= 1 && shaped.page(at: 0)!.bounds(for: .mediaBox).size == CGSize(width: 595, height: 842), "\(name) is printed", "\(shaped.pageCount) pages")
            } catch { check(false, "\(name) is printed", "\(error)") }
        }

        let ruled = try await make(chapter("---\n\nIntro paragraph before the first rule.\n\n---\n\n# Next\n\nAfter.\n", in: docs, name: "ruled.md"), folder: docs, roots: [docs]).0
        check(fullText(ruled).contains("Intro paragraph before the first rule."), "a horizontal rule at the top of a file is not taken for front matter, and the text after it is printed", fullText(ruled))
        let folded = try await make(chapter("---\ntitle: >-\n  A title written over\n  two lines\n---\n\nBody text.\n", in: docs, name: "folded.md"), folder: docs, roots: [docs]).0
        check(text(folded, page: 0).contains("A title written over") && !text(folded, page: 0).contains(">-"), "a title written as a folded value is the title of the cover", text(folded, page: 0))
        let hiddenText = fullText(try await make(chapter(hostile, in: docs, name: "hostile2.md"), folder: docs, roots: [docs]).0)
        check(hiddenText.contains("HIDDEN") && hiddenText.contains("FIXED"), "text that only claims to be a formula is printed, not hidden", hiddenText)

        // 4. A document in another language gets its words, and an HTML page prints like a document.
        let russian = "---\ntitle: Квартальный обзор\ndate: 2026-11-07\n---\n\n" + (1...6).map { "## Раздел \($0)\n\nТекст раздела.\n\n" + String(repeating: "Длинный абзац о надёжности. ", count: 90) + "\n\n### Подраздел \($0)\n\n" + String(repeating: "Ещё текст. ", count: 150) + "\n" }.joined(separator: "\n")
        let (ru, _) = try await make(chapter(russian, in: docs, name: "ru.md"), folder: docs, roots: [docs])
        try ru.dataRepresentation()?.write(to: output.appendingPathComponent("russian.pdf"))
        check(has(text(ru, page: 0), "ДОКУМЕНТ") && text(ru, page: 0).contains("Квартальный обзор") && text(ru, page: 0).contains("2026"), "a Russian document has a Russian title page with its date", text(ru, page: 0))
        check(text(ru, page: 1).contains("Оглавление"), "…and a contents page in Russian", text(ru, page: 1))
        // The text layer of the PDF must hold the letters that were typed: the system sans-serif font of macOS makes the PDF text layer hold
        // U+0138 instead of the Russian letter "к" (copying or searching "рынок" then finds nothing).
        let search = "---\ntitle: Рынок и конкуренты\nauthor: Контроль качества\n---\n\n" + (1...4).map { "## Рынок \($0): рисунок, контроль, карта\n\n" + String(repeating: "Текст рынка и конкурентов. ", count: 70) + "\n" }.joined(separator: "\n")
        let (searchable, _) = try await make(chapter(search, in: docs, name: "search.md"), folder: docs, roots: [docs])
        let searchableText = fullText(searchable)
        check(!searchableText.contains("\u{0138}"), "no page of a Russian document holds a Latin letter in place of a Russian one", String(searchableText.prefix(300)))
        check(text(searchable, page: 1).contains("Рынок 1: рисунок, контроль, карта") && text(searchable, page: 2).contains("Рынок и конкуренты"), "the contents and the running head can be searched for Russian words", text(searchable, page: 1))
        // The caption of a table (a bold line of its own) is never left at the foot of a page with its table on the next one.
        let captions = (1...30).map { "## Part \($0)\n\n" + String(repeating: "Some text that fills the page a little. ", count: 12 + $0 * 3) + "\n\n**Table \($0) — Figures of part \($0)**\n\n| Item | Value |\n|---|---|\n" + (1...9).map { "| row \($0) | \($0 * 11) |" }.joined(separator: "\n") + "\n" }.joined(separator: "\n")
        let (captioned, _) = try await make(chapter(captions, in: docs, name: "captions.md"), folder: docs, roots: [docs])
        var stranded = 0
        for index in 1..<captioned.pageCount {
            let lines = text(captioned, page: index).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // The last line of the page body is followed by the running foot ("date n / N"); the caption is the line before it.
            if let caption = lines.dropLast().last, caption.hasPrefix("Table ") && caption.contains("Figures of part") { stranded += 1 }
        }
        check(stranded == 0, "the caption of a table is not left alone at the foot of a page", "\(stranded) pages end with a caption")
        // The language comes from the prose, not from English front matter, a table or the source of a diagram.
        let englishHeavy = "---\ntitle: Business Plan and Market Entry Strategy\nstatus: draft\n---\n\n| Item | Value |\n|---|---|\n| Document | Business plan version 1.0 |\n\n```mermaid\nflowchart LR\n  Revenue --> Margin --> Profit\n```\n\nРоссийский рынок праздников растёт быстрее, чем остальные сегменты услуг, и поставщики ищут новые каналы продаж.\n"
        check(BookPDFLabels.detectedLanguage(of: englishHeavy) == "ru", "the language of a Russian plan with English front matter, table and diagram is Russian", BookPDFLabels.detectedLanguage(of: englishHeavy))
        check(BookPDFLabels.detectedLanguage(of: "A short English sentence that is long enough to be detected as English text.") == "en", "…and English prose is English")
        let page = "<h1>Insight</h1><p>A page that came as HTML.</p><h2>One</h2><p>First.</p>"
        let (insight, _) = try await make(chapter(page, in: docs, name: "insight.html", format: "html"), folder: docs, roots: [docs])
        check(fullText(insight).contains("A page that came as HTML.") && fullText(insight).contains("Insight"), "an HTML page is printed with the same title page and pages", fullText(insight))
        // Opt-in (PDF_EXPORT_LARGE=1): a large document with many diagrams, as in the BUG-105 report, must still be printed in reasonable time.
        if ProcessInfo.processInfo.environment["PDF_EXPORT_LARGE"] == "1" {
            var large = "# A large document\n\n"
            for section in 0..<120 {
                large += "## Section \(section)\n\nParagraph \(section) of the market entry plan, long enough to be a realistic block of prose. " + String(repeating: "More prose. ", count: 40) + "\n\n"
                large += "| Item | Owner | Value |\n|---|---|---|\n" + (0..<6).map { "| row \(section).\($0) | team \($0) | \($0 * 7) |" }.joined(separator: "\n") + "\n\n"
                large += "```mermaid\ngraph TD\n  A[Start] --> B{Choice}\n  B -->|yes| C[Done]\n  B -->|no| D[Retry]\n  D --> B\n```\n\n"
            }
            let begun = Date()
            let (big, _) = try await make(chapter(large, in: docs, name: "large.md"), folder: docs, roots: [docs])
            let seconds = Date().timeIntervalSince(begun)
            print("    large document: \(big.pageCount) pages, 120 diagrams, \(String(format: "%.1f", seconds)) s")
            check(seconds < 120 && big.pageCount > 100, "a document with 120 diagrams is printed within two minutes", "\(seconds) s, \(big.pageCount) pages")
        }
        print("PDFs kept in \(output.path)")
    }
}
