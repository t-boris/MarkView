import Foundation

/// BUG-059: a screen that one assistant call writes for a large widget can be a look-alike of it. OptionDesk.tsx of the
/// StrikeDesk app is 84 KB with 36 files in its folder; its screen came out at 9 KB with a generic table. The preview audit only
/// sees that a screen renders. This module compares what the source shows, its visible labels, with the screen's script,
/// so the build can name what is absent and send it into one repair pass. It makes no assistant call and
/// reads no file itself: the caller passes `read`, which keeps it testable and off the main thread.
///
/// A label is text a person would read on the screen: JSX text, and `label`, `header`, `text`, `heading`, `caption`, `placeholder`,
/// `name`, `title` properties. Class names, ids, key names, tooltips and aria texts are not. The check is a heuristic: it
/// finds a screen that shows a small part of its source, not one that merely differs in layout. Measured on the 22 screens of the
/// StrikeDesk prototype: the option desk showed 32% of the labels of its source set and the settings window 9%; the other 20
/// screens showed 60% to 100%. The shared sample data (`data.js`) does not count: it holds the labels of every screen and made
/// the option desk look 51% complete. The threshold was chosen on those same screens.
enum PrototypeFidelity {
    /// A screen is thin when its source files have at least this many labels and fewer than `thinBelow` of them are in the screen.
    static let minLabels = 12
    static let thinBelow = 0.4
    /// The source set of one screen: at most this many files and bytes (entries first, then their imports).
    static let maxFiles = 40
    static let maxBytes = 600_000
    /// One build or sync repairs at most this many screens, the thinnest first.
    static let maxRepairs = 3
    /// A repair request lists at most this many missing labels.
    static let listLimit = 40

    struct Missing: Equatable, Sendable {
        var label: String
        /// The source file that defines it, relative to the project root.
        var file: String
    }

    struct Report: Equatable, Sendable {
        var id: String
        var name: String
        /// The source files that were read, relative to the project root.
        var files: [String]
        var total: Int
        var present: Int
        var missing: [Missing]

        var coverage: Double { total == 0 ? 1 : Double(present) / Double(total) }
        var percent: Int { Int((coverage * 100).rounded(.down)) }
        var isThin: Bool { total >= PrototypeFidelity.minLabels && coverage < PrototypeFidelity.thinBelow }
    }

    // MARK: - Labels

    private static func expression(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants of this file; a typo is a programming error found by the first test run.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private static let importLine = expression(#"(?m)^[ \t]*(?:import|export)\b[^\n]*\bfrom\s*['"][^'"\n]+['"];?[ \t]*$"#)
    private static let lineComment = expression(#"(?m)(^|[ \t])//[^\n]*"#)
    private static let blockComment = expression(#"/\*[\s\S]*?\*/"#)
    private static let hiddenAttribute = expression(
        #"\b(?:className|class|data-testid|data-[\w-]+|key|id|type|role|htmlFor|testId|variant|size|kind|mode|side|align|direction|name|title|alt|aria-[\w-]+)=(?:"[^"\n]*"|'[^'\n]*'|\{[^}\n]*\})"#)
    private static let jsxText = expression(#">([^<>{}\n]{3,60})<"#)
    private static let labelProperty = expression(
        #"\b(?:label|header|text|heading|caption|placeholder|name|title)\s*[:=]\s*(['"`])((?:(?!\1)[^\\\n]){3,48})\1"#)
    private static let keyName = expression(#"^(?:Arrow\w+|Enter|Escape|Tab|Space|Bracket\w+|Backspace|Delete|Shift|Meta|Control|Alt|F\d+|Key\w|Digit\d)$"#)
    private static let keywords: Set<String> = ["px", "rem", "rgb", "rgba", "hsl", "var", "flex", "grid", "none", "auto", "true", "false",
                                                "null", "undefined", "function", "string", "number", "object", "boolean"]

    private static func full(_ text: String) -> NSRange { NSRange(text.startIndex..., in: text) }

    private static func removing(_ re: NSRegularExpression, from text: String, keeping template: String = "") -> String {
        re.stringByReplacingMatches(in: text, options: [], range: full(text), withTemplate: template)
    }

    private static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, options: [], range: full(text)) != nil
    }

    /// Whether a string reads like text on a screen and not like an identifier, a path, a style or a key name.
    static func looksLikeLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...48).contains(text.count), let first = text.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        guard text.range(of: "[A-Za-z]{3}", options: .regularExpression) != nil else { return false }
        if text.range(of: #"[\\_=;{}<>|@#$^*~\[\]]|=>|&&|\$\{|\d{4,}|\.\w|:(?!$)"#, options: .regularExpression) != nil { return false }
        if text.contains("/"), text.contains(".") || text.filter({ $0 == "/" }).count > 1 { return false }
        if matches(keyName, text) { return false }
        if !text.contains(" ") {
            // One word: a label is written in Title or UPPER case; camelCase, kebab-case and lower case are code.
            if text.range(of: #"^[a-z]+[A-Z]\w*$"#, options: .regularExpression) != nil { return false }
            if text.range(of: #"^[a-z]+$"#, options: .regularExpression) != nil { return false }
            if text.contains("-") || keywords.contains(text.lowercased()) { return false }
        }
        return true
    }

    /// The visible labels of one source file, in the order they appear, each once.
    static func labels(in source: String) -> [String] {
        var text = removing(importLine, from: source)
        text = removing(lineComment, from: text, keeping: "$1")
        text = removing(blockComment, from: text)
        text = removing(hiddenAttribute, from: text)
        var found: [String] = []
        var seen = Set<String>()
        func take(_ candidate: String) {
            let label = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard looksLikeLabel(label), seen.insert(label).inserted else { return }
            found.append(label)
        }
        var hits: [(Int, String)] = []
        for match in jsxText.matches(in: text, options: [], range: full(text)) {
            if let range = Range(match.range(at: 1), in: text) { hits.append((match.range.location, String(text[range]))) }
        }
        for match in labelProperty.matches(in: text, options: [], range: full(text)) {
            if let range = Range(match.range(at: 2), in: text) { hits.append((match.range.location, String(text[range]))) }
        }
        for hit in hits.sorted(by: { $0.0 < $1.0 }) { take(hit.1) }
        return found
    }

    /// Lowercase, one space between words: the same label in another case or spacing is the same label.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - The source set of a screen

    private static let sourceExtensions: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "vue", "svelte", "html"]
    private static let importPattern = expression(#"(?:\bfrom|\bimport|\brequire)\s*\(?\s*['"](\.{1,2}/[^'"\n]+)['"]"#)
    private static let secondaryName = expression(#"(?:Popup|Dialog|Modal|Menu|Editor|Preview|Tooltip|Popover|Drawer)"#)

    /// A source file that can show text: not a declaration, a test, a mock or a story.
    static func isSource(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard sourceExtensions.contains((name as NSString).pathExtension.lowercased()), !name.hasSuffix(".d.ts") else { return false }
        let lowered = path.lowercased()
        return !["/__tests__/", "/__mocks__/", ".test.", ".spec.", ".stories."].contains { lowered.contains($0) }
    }

    /// A dialog, menu, editor or preview: the original shows it on request, so its labels are not expected on the screen at start.
    static func isSecondary(_ path: String) -> Bool {
        let stem = (((path as NSString).lastPathComponent) as NSString).deletingPathExtension
        return matches(secondaryName, stem)
    }

    static func relativeImports(in source: String) -> [String] {
        importPattern.matches(in: source, options: [], range: full(source)).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    /// `specifier` as the file `from` imports it, as a path relative to the project root, or nil for a path above the root.
    static func resolve(_ specifier: String, from file: String, exists: (String) -> Bool) -> String? {
        var parts = file.split(separator: "/").dropLast().map(String.init)
        for piece in specifier.split(separator: "/") {
            if piece == "." { continue }
            if piece == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(String(piece))
            }
        }
        let base = parts.joined(separator: "/")
        for suffix in ["", ".tsx", ".ts", ".jsx", ".js", ".vue", "/index.tsx", "/index.ts", "/index.jsx", "/index.js"] {
            let candidate = base + suffix
            if isSource(candidate), exists(candidate) { return candidate }
        }
        return nil
    }

    /// The files whose labels the screen should show: its evidence files, then what each of them imports from inside its own
    /// folder (one level), without tests, secondary files and files that are the evidence of another screen.
    static func sourceSet(evidence: [String], otherEvidence: Set<String>, read: (String) -> String?) -> [(path: String, content: String)] {
        var out: [(path: String, content: String)] = []
        var bytes = 0
        var seen = Set<String>()
        func add(_ path: String) -> String? {
            guard out.count < maxFiles, seen.insert(path).inserted, let content = read(path), bytes + content.utf8.count <= maxBytes else { return nil }
            bytes += content.utf8.count
            out.append((path, content))
            return content
        }
        var entries: [(path: String, content: String)] = []
        for path in evidence where isSource(path) {
            if let content = add(path) { entries.append((path, content)) }
        }
        for entry in entries {
            let folder = (entry.path as NSString).deletingLastPathComponent
            for specifier in relativeImports(in: entry.content) {
                guard let path = resolve(specifier, from: entry.path, exists: { read($0) != nil }),
                      folder.isEmpty || path.hasPrefix(folder + "/"),
                      !seen.contains(path), !otherEvidence.contains(path), !isSecondary(path) else { continue }
                _ = add(path)
            }
        }
        return out
    }

    // MARK: - The report

    /// How much of the source's visible text the screen shows, or nil when no source file could be read.
    /// `screen` is the screen's script: a label counts only when it is in that script, not in the shared sample data.
    static func report(id: String, name: String, evidence: [String], otherEvidence: Set<String>, screen: String,
                       read: (String) -> String?) -> Report? {
        let set = sourceSet(evidence: evidence, otherEvidence: otherEvidence, read: read)
        guard !set.isEmpty else { return nil }
        let haystack = normalized(screen)
        var seen = Set<String>()
        var total = 0
        var present = 0
        var missing: [Missing] = []
        for file in set {
            for label in labels(in: file.content) {
                let key = normalized(label)
                guard seen.insert(key).inserted else { continue }
                total += 1
                if haystack.contains(key) { present += 1 } else { missing.append(Missing(label: label, file: file.path)) }
            }
        }
        return Report(id: id, name: name, files: set.map(\.path), total: total, present: present, missing: missing)
    }

    static func summary(_ report: Report) -> String {
        "\"\(report.name)\" shows \(report.present) of \(report.total) labels of its source files (\(report.percent)%)"
    }

    /// The request of the repair pass for a thin screen: what is absent, where the source defines it, and what not to do.
    static func repairInstruction(_ report: Report) -> String {
        var byFile: [(file: String, labels: [String])] = []
        for item in report.missing {
            if let index = byFile.firstIndex(where: { $0.file == item.file }) { byFile[index].labels.append(item.label) }
            else { byFile.append((item.file, [item.label])) }
        }
        byFile.sort { $0.labels.count > $1.labels.count }
        var out = "Source check: \(summary(report)), so it is thinner than the original. These labels are in the source and are not in " +
            "`screens/\(report.id).js`, grouped by the file that defines each:\n"
        var listed = 0
        for group in byFile where listed < listLimit {
            let take = Array(group.labels.prefix(listLimit - listed))
            listed += take.count
            out += "- `\(group.file)`: " + take.map { "\"\($0)\"" }.joined(separator: ", ")
            if take.count < group.labels.count { out += ", and \(group.labels.count - take.count) more" }
            out += "\n"
        }
        if report.missing.count > listed { out += "(\(report.missing.count - listed) more labels in other files are not listed.)\n" }
        out += "\nRead those files with your tools and find the parts of the interface that show these labels (toolbar controls, table " +
            "columns and headers, summary rows, panels, states). Add them to the screen, copying every label exactly as the source " +
            "writes it and following the source's markup, class names, number formats and behaviour. Keep what the screen already does " +
            "right. Some labels belong to dialogs, menus or tooltips that the original shows only on request: add those only when the " +
            "screen opens them, and skip them otherwise. Do not invent labels, columns or data that the source does not have. Change " +
            "this screen's script only, plus the sample data in `data.js` when the new parts need it."
        return out
    }
}
