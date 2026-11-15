import Foundation

/// Tailwind for a prototype made from the code of a Tailwind v4 app (BUG-063).
///
/// The stylesheet of such an app is the Tailwind source: it starts with `@import "tailwindcss"` and holds `@theme`, `@utility` and
/// `@layer` rules. A browser does not process it, so the utility classes the screens keep from the source (`mt-sp10`, `rounded-lg`,
/// `border-dashed`, hundreds of them) have no rule and the prototype opens as raw HTML. MarkView therefore carries Tailwind's own browser
/// build with it (`Resources/Editor/vendor/js/tailwind-browser.js`, offline, nothing loaded from a CDN) and writes it, with the source, into
/// the prototype's `markview/` folder, which the assistants neither read nor write:
/// - `markview/tailwind-source.js` adds the source as a `<style type="text/tailwindcss">`: the entry stylesheet without the rules a browser
///   cannot resolve (`@source`, `@plugin`, `@config` and local `@import`s; the latter are plain stylesheets that index.html links itself);
/// - `markview/tailwind.js` is the browser build, which compiles the classes the page uses and keeps doing so as the page changes.
///
/// Both are linked from index.html and from every page under `components/`. Like the link to the page structure, the two lines are
/// MarkView's, not the author's: `authored` removes them, and the sync baseline fingerprints pages without them, so adding Tailwind to a
/// prototype is never mistaken for an edit. A site without a Tailwind entry among its copied stylesheets gets nothing. Only Tailwind v4
/// is covered (the browser build reads `@import "tailwindcss"` and `@theme`, not a v3 `tailwind.config.js`).
enum PrototypeTailwind {
    static let scriptPath = PrototypeFiles.ownedFolder + "/tailwind.js"
    static let sourcePath = PrototypeFiles.ownedFolder + "/tailwind-source.js"

    // MARK: - The source

    /// An `@import` of the Tailwind package: `@import "tailwindcss"`, `@import 'tailwindcss/theme.css' layer(theme)`.
    private static let tailwindImport = #"@import\s+(?:url\(\s*)?["']tailwindcss(?:/[^"']*)?["']"#

    /// True for a stylesheet that imports Tailwind: the entry of the application's styles.
    static func isEntry(_ css: String) -> Bool {
        css.range(of: tailwindImport, options: .regularExpression) != nil
    }

    /// `css` as the browser build can read it: without `@source`, `@plugin` and `@config` (they name files and JavaScript the page cannot
    /// reach) and without every `@import` but the Tailwind ones; the Tailwind imports stay only when `keepingTailwind` is true.
    static func browserReady(_ css: String, keepingTailwind: Bool) -> String {
        var text = css.replacingOccurrences(of: #"@(?:source|plugin|config)\b[^;]*;[ \t]*\n?"#, with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"@import\s+[^;]*;[ \t]*\n?"#) else { return text }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let statement = ns.substring(with: match.range)
            let ours = statement.range(of: tailwindImport, options: .regularExpression) != nil
            if ours && keepingTailwind { continue }
            text = (text as NSString).replacingCharacters(in: match.range, with: "")
        }
        return text
    }

    /// The text of the style: every Tailwind entry among `stylesheets`, the first with its Tailwind import and the others without it
    /// (one Tailwind is enough). Nil when none imports Tailwind.
    static func source(from stylesheets: [String]) -> String? {
        let entries = stylesheets.filter(isEntry)
        guard !entries.isEmpty else { return nil }
        return entries.enumerated().map { browserReady($1, keepingTailwind: $0 == 0) }.joined(separator: "\n")
    }

    /// The source of the site's copied stylesheets (`site/original/`), in the order index.html links them. Reads the file system.
    static func source(site: URL, fileManager fm: FileManager = .default) -> String? {
        source(from: PrototypeThemes.copiedStylesheets(site: site, fileManager: fm))
    }

    /// `markview/tailwind-source.js`: adds `css` as a style of type `text/tailwindcss` before the browser build starts.
    static func sourceScript(css: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [css], options: [])) ?? Data("[\"\"]".utf8)
        var literal = String(decoding: data, as: UTF8.self)
        literal.removeFirst(); literal.removeLast()
        literal = literal.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return """
        /* Written by MarkView, not by the assistant: the Tailwind source of this prototype (the application's stylesheet that imports
           "tailwindcss"), handed to markview/tailwind.js, which compiles the classes the page uses. */
        (function () {
          var style = document.createElement('style');
          style.setAttribute('type', 'text/tailwindcss');
          style.textContent = \(literal);
          document.head.appendChild(style);
        })();

        """
    }

    // MARK: - The lines of a page

    private static var linePattern: String {
        #"<script\b[^>]*\bsrc\s*=\s*["'](?:\.\./)*"# + NSRegularExpression.escapedPattern(for: PrototypeFiles.ownedFolder)
            + #"/tailwind(?:-source)?\.js["'][^>]*>\s*</script>[ \t]*\n?"#
    }

    private static func lines(prefix: String) -> String {
        "<script src=\"\(prefix)\(sourcePath)\"></script>\n<script src=\"\(prefix)\(scriptPath)\"></script>\n"
    }

    /// True when the page carries both lines.
    static func isLinked(_ html: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: linePattern, options: [.caseInsensitive]) else { return false }
        let found = regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { Range($0.range, in: html).map { String(html[$0]) } }
        return found.contains { $0.contains("tailwind-source.js") } && found.contains { !$0.contains("tailwind-source.js") }
    }

    /// `html` with the two lines, put before the `styles.css` link or, when there is none, before `</head>` (`prefix` is `../` for a page one
    /// folder below the site root); unchanged when they are there; nil when the page has neither place.
    static func linked(_ html: String, prefix: String) -> String? {
        if isLinked(html) { return html }
        let clean = authored(html)
        if let regex = try? NSRegularExpression(pattern: #"<link\b[^>]*href\s*=\s*["'](?:\.\./)*styles\.css["'][^>]*>"#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)), let r = Range(match.range, in: clean) {
            return clean.replacingCharacters(in: r.lowerBound..<r.lowerBound, with: lines(prefix: prefix))
        }
        if let r = clean.range(of: "</head>", options: .caseInsensitive) {
            return clean.replacingCharacters(in: r.lowerBound..<r.lowerBound, with: lines(prefix: prefix))
        }
        return nil
    }

    /// `html` as its author wrote it: without the lines MarkView added.
    static func authored(_ html: String) -> String {
        html.replacingOccurrences(of: linePattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    // MARK: - A site

    /// `index.html` and every page under `components/` (and any other page outside `original/` and `markview/`), with the prefix that
    /// reaches the site root from it.
    static func pages(site: URL, fileManager fm: FileManager = .default) -> [(url: URL, prefix: String)] {
        let root = site.standardizedFileURL
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [(URL, String)] = []
        for case let url as URL in walker {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if relative == PrototypeFiles.originalFolder || relative == PrototypeFiles.ownedFolder { walker.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "html" else { continue }
            out.append((url, String(repeating: "../", count: relative.split(separator: "/").count - 1)))
        }
        return out.sorted { $0.0.path < $1.0.path }
    }

    /// The browser build as the app carries it; nil outside the app bundle.
    static func bundledScript() -> Data? {
        guard let url = Bundle.main.url(forResource: "tailwind-browser", withExtension: "js", subdirectory: "Editor/vendor/js") else { return nil }
        return try? Data(contentsOf: url)
    }

    enum Outcome: Equatable {
        /// No stylesheet of the site imports Tailwind.
        case notNeeded
        /// The site had Tailwind as it should be.
        case current
        /// The files were written or a page was linked.
        case applied
        /// The browser build is not available (outside the app bundle), so nothing was written.
        case unavailable
    }

    /// True when `site` imports Tailwind but lacks it or has an out-of-date copy of it. Reads only.
    static func needsApplying(site: URL, vendor: () -> Data? = bundledScript, fileManager fm: FileManager = .default) -> Bool {
        guard let css = source(site: site, fileManager: fm), let script = vendor() else { return false }
        func current(_ path: String, _ data: Data) -> Bool { (try? Data(contentsOf: site.appendingPathComponent(path))) == data }
        if !current(scriptPath, script) || !current(sourcePath, Data(sourceScript(css: css).utf8)) { return true }
        for page in pages(site: site, fileManager: fm) {
            guard let html = try? String(contentsOf: page.url, encoding: .utf8), linked(html, prefix: page.prefix) != nil else { continue }
            if !isLinked(html) { return true }
        }
        return false
    }

    /// Makes `site` carry Tailwind: the two files are written and every page links them. Idempotent.
    @discardableResult
    static func ensure(site: URL, vendor: () -> Data? = bundledScript, fileManager fm: FileManager = .default) throws -> Outcome {
        guard let css = source(site: site, fileManager: fm) else { return .notNeeded }
        guard let script = vendor() else { return .unavailable }
        var changed = false
        func write(_ data: Data, to path: String) throws {
            let target = site.appendingPathComponent(path)
            if (try? Data(contentsOf: target)) == data { return }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            changed = true
        }
        try write(script, to: scriptPath)
        try write(Data(sourceScript(css: css).utf8), to: sourcePath)
        for page in pages(site: site, fileManager: fm) {
            guard let html = try? String(contentsOf: page.url, encoding: .utf8), let withLines = linked(html, prefix: page.prefix), withLines != html else { continue }
            try withLines.write(to: page.url, atomically: true, encoding: .utf8)
            changed = true
        }
        return changed ? .applied : .current
    }
}
