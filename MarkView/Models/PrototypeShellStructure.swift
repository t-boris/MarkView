import Foundation

/// The page structure of a prototype made from code, owned by MarkView (BUG-060).
///
/// The shell of a prototype from code (index.html, app.js, styles.css) is written by assistants, and what they had to agree on here
/// was one sentence in their prompts: the page, `#app` and the box that holds a screen have a definite height. A styles.css that
/// left it out gave the StrikeDesk prototype a page as tall as its content, so every widget that sizes its body with `height:100%`
/// or `flex:1` collapsed to nothing and only its toolbar showed. A rule that never varies is not the assistant's to write. MarkView
/// writes it, in a folder of its own that the assistant neither reads nor writes (`markview/`, like `original/`), and links it from
/// index.html. Every rule has zero specificity (`:where`), so the application's own stylesheets and styles.css override it wherever
/// they say something.
///
/// The link line is MarkView's, not the author's: `authored` removes it, and the sync baseline fingerprints index.html without it, so
/// adding the structure to a prototype is never mistaken for an edit of the shell.
enum PrototypeShellStructure {
    /// Where the stylesheet lives, relative to `site/`, and what index.html links.
    static let href = PrototypeFiles.ownedFolder + "/structure.css"

    /// The rules, one per box of the shell: the page, `#app`, the main area, a single full-window screen, the box `App.renderScreen`
    /// returns and the box `App.load` puts around a screen.
    static let css = """
    /* Written by MarkView, not by the assistant: the page structure of a prototype from code.
       The page and #app have a definite height, and every box between them and a screen fills it, so a widget that sizes its body
       with height:100% or flex:1 has something to fill instead of collapsing. Zero specificity: any stylesheet overrides it. */
    :where(html, body) { height: 100%; margin: 0; }
    :where(body) { overflow: hidden; }
    :where(#app) { display: flex; flex-direction: column; height: 100%; min-height: 0; }
    :where(.app-main) { flex: 1 1 auto; min-height: 0; overflow: auto; }
    :where(.app-main-single) { display: flex; flex-direction: column; padding: 0; overflow: hidden; }
    :where(.app-screen-fill) { display: flex; flex-direction: column; flex: 1 1 auto; height: 100%; min-height: 0; }
    :where(.app-load) { display: flex; flex-direction: column; flex: 1 1 auto; min-height: 0; }

    """

    /// What the shell writers are told, so they neither write these rules nor depend on anything else for them.
    static let contract = """
    The page structure is not yours to write: MarkView links `\(href)` before styles.css. It gives `html`, `body` and `#app` a \
    definite height (`#app` is a flex column), `app-main` the rest of it (`flex:1; min-height:0; overflow:auto`), and \
    `app-main-single`, `app-screen-fill` and `app-load` flex columns that fill their parent. All of it has zero specificity, \
    so your own rules may refine it. Do not set a height on `html`, `body` or `#app`, and do not remove the link.
    """

    // MARK: - The link

    private static var linkPattern: String {
        "<link\\b[^>]*href\\s*=\\s*[\"']" + NSRegularExpression.escapedPattern(for: href) + "[\"'][^>]*>[ \\t]*\\n?"
    }

    static func isLinked(_ html: String) -> Bool {
        html.range(of: linkPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `html` with the link to the structure stylesheet, put where the other linked stylesheets go; unchanged when it is there
    /// already; nil when the page has no place for a stylesheet.
    static func linked(_ html: String) -> String? {
        isLinked(html) ? html : PrototypeStyles.insertLinks(into: html, hrefs: [href])
    }

    /// `html` as its author wrote it: without the link MarkView added.
    static func authored(_ html: String) -> String {
        html.replacingOccurrences(of: linkPattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    // MARK: - A site

    enum Outcome: Equatable {
        /// The site had the structure as it should be.
        case current
        /// The stylesheet was written or index.html was linked to it.
        case applied
        /// There is no index.html, or it has no place for a stylesheet, so the structure cannot be linked.
        case unlinkable
    }

    /// True when `site` has a shell that lacks the structure or has an out-of-date copy of it. Reads only.
    static func needsApplying(site: URL) -> Bool {
        guard let html = try? String(contentsOf: site.appendingPathComponent("index.html"), encoding: .utf8), linked(html) != nil else { return false }
        let current = try? String(contentsOf: site.appendingPathComponent(href), encoding: .utf8)
        return current != css || !isLinked(html)
    }

    /// Makes `site` carry the structure: the stylesheet is written, index.html links it. Idempotent.
    @discardableResult
    static func ensure(site: URL, fileManager fm: FileManager = .default) throws -> Outcome {
        let index = site.appendingPathComponent("index.html")
        guard let html = try? String(contentsOf: index, encoding: .utf8), let withLink = linked(html) else { return .unlinkable }
        var changed = false
        let target = site.appendingPathComponent(href)
        if (try? String(contentsOf: target, encoding: .utf8)) != css {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try css.write(to: target, atomically: true, encoding: .utf8)
            changed = true
        }
        if withLink != html {
            try withLink.write(to: index, atomically: true, encoding: .utf8)
            changed = true
        }
        return changed ? .applied : .current
    }
}
