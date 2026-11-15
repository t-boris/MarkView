import Foundation

/// The themes of a prototype made from code (feature "Themes in a prototype made from code", DEC-001).
///
/// Many applications switch themes with an attribute of the root element: `[data-theme="dark"] { --bg: … }`. The stylesheets of
/// every theme are copied into the prototype unchanged, but nothing sets the attribute, so the preview has one fixed look. Studio
/// finds the themes by reading the copied stylesheets (no assistant run), offers them in its toolbar and sets the attribute of the
/// preview's root element itself, so the picker works even when the generated Appearance screen is a stub.
enum PrototypeThemes {
    /// What the stylesheets select: the attribute and its values in order of first appearance, or nil when no attribute
    /// selects at least two values (one value is a state, not a theme switch).
    static func scan(stylesheets: [String]) -> (attribute: String, ids: [String])? {
        var order: [String] = []
        var values: [String: [String]] = [:]
        for sheet in stylesheets {
            let css = withoutComments(sheet)
            let range = NSRange(css.startIndex..., in: css)
            for match in selector.matches(in: css, range: range) {
                guard let all = Range(match.range, in: css), startsSelector(css, at: all.lowerBound),
                      let nameRange = Range(match.range(at: 1), in: css), let valueRange = Range(match.range(at: 2), in: css) else { continue }
                let name = String(css[nameRange]), value = String(css[valueRange])
                guard name.range(of: attributeName, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                if values[name] == nil { order.append(name); values[name] = [] }
                if !values[name]!.contains(value) { values[name]!.append(value) }
            }
        }
        // The attribute with the most values is the theme switch; the first seen wins a tie.
        var best: String?
        for name in order where (values[name]?.count ?? 0) > (best.flatMap { values[$0]?.count } ?? 0) { best = name }
        guard let best, let ids = values[best], ids.count >= 2 else { return nil }
        return (best, ids)
    }

    /// The record after a build or a sync. `found` is what the stylesheets select; `planned` the ids the planner read from the
    /// original, which add the base theme that has no selector of its own (StrikeDesk's `dark` is `:root`) and give the order;
    /// `defaultID` the theme the original starts with (kept from before when the build recorded none); the reviewer's earlier
    /// choice stays while it is still a theme (the empty choice, "original look", always). nil when the stylesheets hold no themes.
    static func record(found: (attribute: String, ids: [String])?, planned: [String] = [], defaultID: String?,
                       previous: PrototypeFiles.ThemeRecord?) -> PrototypeFiles.ThemeRecord? {
        guard let found else { return nil }
        var ids: [String] = []
        for id in planned + found.ids where !ids.contains(id) { ids.append(id) }
        let recorded = defaultID.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { ids.contains($0) ? $0 : nil }
        let kept = previous.flatMap { $0.attribute == found.attribute ? $0 : nil }
        let chosen = kept?.chosen.flatMap { $0.isEmpty || ids.contains($0) ? $0 : nil }
        let fallback = kept?.defaultID.flatMap { ids.contains($0) ? $0 : nil }
        return PrototypeFiles.ThemeRecord(attribute: found.attribute, ids: ids, defaultID: recorded ?? fallback, chosen: chosen)
    }

    /// The stylesheets copied into `site/original/`, as text, in the order `index.html` links them and then the rest by path.
    /// Reads the file system; the caller keeps it off the main thread.
    static func copiedStylesheets(site: URL, fileManager fm: FileManager = .default) -> [String] {
        let original = site.appendingPathComponent("original", isDirectory: true)
        guard let walker = fm.enumerator(at: original, includingPropertiesForKeys: nil) else { return [] }
        var all: [String] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "css" {
            all.append(String(url.standardizedFileURL.path.dropFirst(site.standardizedFileURL.path.count + 1)))
        }
        all.sort()
        var linked: [String] = []
        if let index = try? String(contentsOf: site.appendingPathComponent("index.html"), encoding: .utf8) {
            let range = NSRange(index.startIndex..., in: index)
            for match in link.matches(in: index, range: range) {
                if let r = Range(match.range(at: 1), in: index), all.contains(String(index[r])), !linked.contains(String(index[r])) { linked.append(String(index[r])) }
            }
        }
        let ordered = linked + all.filter { !linked.contains($0) }
        return ordered.compactMap { try? String(contentsOf: site.appendingPathComponent($0), encoding: .utf8) }
    }

    /// Scans the site's copied stylesheets. Reads the file system.
    static func scan(site: URL) -> (attribute: String, ids: [String])? { scan(stylesheets: copiedStylesheets(site: site)) }

    // MARK: - The preview

    /// Runs at the start of every page of the preview so the first paint already has the theme.
    static func startScript(attribute: String, id: String) -> String {
        "(function () { try { document.documentElement.setAttribute(\(literal(attribute)), \(literal(id))); } catch (e) {} })();"
    }

    /// Sets or removes the attribute of the page that is open.
    static func applyScript(attribute: String, id: String?) -> String {
        guard let id else { return "document.documentElement.removeAttribute(\(literal(attribute)));" }
        return "document.documentElement.setAttribute(\(literal(attribute)), \(literal(id)));"
    }

    /// A JSON string literal: ids and attribute names come from stylesheets and are never pasted raw into a script.
    static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Private

    /// `[attr="value"]`, optionally on `html`, `:root` or `body`; the attribute name is checked afterwards.
    private static let selector = try! NSRegularExpression(
        pattern: #"(?:html|:root|body)?\[\s*([A-Za-z_][\w:-]*)\s*=\s*["']?([\w-]+)["']?\s*(?:[iIsS])?\s*\]"#)
    private static let attributeName = #"^(data-)?([\w-]*-)?(theme|scheme|skin|mode)(-[\w-]*)?$"#
    private static let link = try! NSRegularExpression(pattern: #"<link[^>]*href=["']([^"']+\.css)["']"#, options: .caseInsensitive)

    /// Only a selector that starts here can be a root selector: `.card[data-theme=x]` and `main [data-theme=x]` are not.
    private static func startsSelector(_ css: String, at index: String.Index) -> Bool {
        var i = index
        while i > css.startIndex {
            i = css.index(before: i)
            let c = css[i]
            if c.isWhitespace { continue }
            return "{},;".contains(c)
        }
        return true
    }

    private static func withoutComments(_ css: String) -> String {
        css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
    }
}
