import Foundation

/// The file work of exporting a Recursive Insight session as a standalone ZIP (Decision 7): the default file name, the staging
/// copy of the session's cache, and the rewriting that makes the copied pages navigate in a plain browser without the JS bridge.
/// Pure over files and values; the save panel and the `zip` run are in `InsightCoordinator` and `InsightArchiveExporter`.
enum InsightArchiveExport {
    /// `<folder>_insight_<ISO8601 with ":" as "-">.zip`: the timestamp keeps the name valid on Finder and case-insensitive volumes.
    static func defaultFilename(folderName: String, date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return "\(sanitizeFilename(folderName))_insight_\(timestamp).zip"
    }

    /// Strict ASCII `[A-Za-z0-9_]` (Decision 10 §7): anything else becomes `_`, runs of `_` collapse, the ends are trimmed, and an
    /// empty result falls back to `insight`. `Character.isLetter` is Unicode-aware, so Cyrillic letters, Arabic-Indic digits and
    /// RTL overrides would leak through; set membership matches the strict class exactly. The save panel lets the person
    /// override the suggestion; this is only the default.
    static func sanitizeFilename(_ title: String) -> String {
        let mapped = String(title.map { allowedFilenameCharacters.contains($0) ? $0 : "_" })
        let collapsed = mapped.split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
        return collapsed.isEmpty ? "insight" : collapsed
    }

    private static let allowedFilenameCharacters: Set<Character> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
    )

    /// For each parent node, the child that each (section id, topic index) deep dive produced. Built from the in-memory tree at
    /// export time because the pair is not stored on `InsightNode`: `expand(sectionId:topicIndex:)` titles the child with the
    /// topic's label, so the label is the key.
    static func childMap(nodes: [UUID: InsightNode]) -> [UUID: [String: [Int: UUID]]] {
        var map: [UUID: [String: [Int: UUID]]] = [:]
        for parent in nodes.values {
            guard let skeleton = parent.skeleton else { continue }
            let childNodes = parent.children.compactMap { nodes[$0] }
            for section in skeleton.sections {
                guard let topics = section.deepDiveTopics else { continue }
                for (index, topic) in topics.enumerated() {
                    guard let child = childNodes.first(where: { $0.title == topic.label }) else { continue }
                    map[parent.id, default: [:]][section.id, default: [:]][index] = child.id
                }
            }
        }
        return map
    }

    /// Copies the CONTENTS of `cacheRoot` into a fresh folder under the temporary directory, so the staging root holds `nodes/`,
    /// `_assets/` and `manifest.json` directly (the archive layout) and rewriting never touches the live cache. The caller removes it.
    static func makeStagingCopy(from cacheRoot: URL) throws -> URL {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("insight-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let entries = try fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for source in entries {
            try fm.copyItem(at: source, to: base.appendingPathComponent(source.lastPathComponent))
        }
        return base
    }

    /// Walks the staging folder and
    ///   1. promotes `nodes/<rootUUID>.html` to `index.html` at the export root, with its library references one level shallower
    ///      (`../_assets/` becomes `_assets/`);
    ///   2. rewrites every `nodes/<uuid>.html`: breadcrumbs to sibling files (or `../index.html` for the root) and every
    ///      `<button class="deep-dive" …>` that has a child page to an `<a class="deep-dive" href="<childUUID>.html">`.
    /// A button without a child stays as it is: in a standalone browser it is inert, because the person did not expand that topic.
    static func rewriteForStandalone(exportRoot: URL, rootNodeId: UUID?, nodeChildMap: [UUID: [String: [Int: UUID]]]) throws {
        let fm = FileManager.default
        let nodesDir = exportRoot.appendingPathComponent("nodes", isDirectory: true)

        if let rootId = rootNodeId {
            let rootSource = nodesDir.appendingPathComponent("\(rootId.uuidString).html")
            if fm.fileExists(atPath: rootSource.path) {
                var html = (try? String(contentsOf: rootSource, encoding: .utf8)) ?? ""
                html = html.replacingOccurrences(of: "\"../_assets/", with: "\"_assets/")
                html = rewriteDeepDiveButtons(in: html, parentNodeId: rootId, nodeChildMap: nodeChildMap, childHrefPrefix: "nodes/")
                html = rewriteBreadcrumbHrefs(in: html, isRoot: true, rootNodeId: rootId)
                try html.write(to: exportRoot.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            }
        }

        // The root copy under nodes/ stays: non-root breadcrumbs target `../index.html`, the canonical entry point.
        guard fm.fileExists(atPath: nodesDir.path) else { return }
        let nodeFiles = try fm.contentsOfDirectory(at: nodesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for nodeFile in nodeFiles where nodeFile.pathExtension.lowercased() == "html" {
            guard let nodeId = UUID(uuidString: nodeFile.deletingPathExtension().lastPathComponent) else { continue }
            var html = (try? String(contentsOf: nodeFile, encoding: .utf8)) ?? ""
            html = rewriteDeepDiveButtons(in: html, parentNodeId: nodeId, nodeChildMap: nodeChildMap, childHrefPrefix: "")
            html = rewriteBreadcrumbHrefs(in: html, isRoot: nodeId == rootNodeId, rootNodeId: rootNodeId)
            try html.write(to: nodeFile, atomically: true, encoding: .utf8)
        }
    }

    /// Replaces `<button class="deep-dive" data-section-id="X" data-topic-index="Y" title="…">label</button>` with an anchor to the
    /// child node's page. The pattern is the deterministic shape of `InsightSession.buildHTMLTemplate`; the escaped title and
    /// label are copied unchanged, only the URL we control is spliced in.
    static func rewriteDeepDiveButtons(in html: String, parentNodeId: UUID, nodeChildMap: [UUID: [String: [Int: UUID]]],
                                       childHrefPrefix: String) -> String {
        guard let sectionMap = nodeChildMap[parentNodeId], !sectionMap.isEmpty else { return html }
        let pattern = #"<button class="deep-dive" data-section-id="([^"]*)" data-topic-index="([0-9]+)" title="([^"]*)">([^<]*)</button>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let text = html as NSString
        // Reverse order keeps the earlier ranges valid while the string changes.
        var result = html
        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)).reversed() {
            guard match.numberOfRanges == 5, let topicIndex = Int(text.substring(with: match.range(at: 2))),
                  let childId = sectionMap[text.substring(with: match.range(at: 1))]?[topicIndex],
                  let range = Range(match.range, in: result) else { continue }
            let title = text.substring(with: match.range(at: 3))
            let label = text.substring(with: match.range(at: 4))
            result.replaceSubrange(range, with: "<a class=\"deep-dive\" href=\"\(childHrefPrefix)\(childId.uuidString).html\" title=\"\(title)\">\(label)</a>")
        }
        return result
    }

    /// Rewrites each breadcrumb `<a class="crumb" href="#<uuid>">` to a relative file link. The root page (`index.html`) points
    /// at `nodes/<uuid>.html`; a node page points at its sibling `<uuid>.html`, and its root crumb at `../index.html`.
    static func rewriteBreadcrumbHrefs(in html: String, isRoot: Bool, rootNodeId: UUID?) -> String {
        // The raw string uses ## delimiters because the pattern itself contains `"#`.
        guard let regex = try? NSRegularExpression(pattern: ##"<a class="crumb" href="#([0-9A-Fa-f-]+)">"##) else { return html }
        let text = html as NSString
        var result = html
        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)).reversed() {
            guard match.numberOfRanges == 2, let crumb = UUID(uuidString: text.substring(with: match.range(at: 1))),
                  let range = Range(match.range, in: result) else { continue }
            let href: String
            if crumb == rootNodeId {
                href = isRoot ? "index.html" : "../index.html"
            } else {
                href = isRoot ? "nodes/\(crumb.uuidString).html" : "\(crumb.uuidString).html"
            }
            result.replaceSubrange(range, with: "<a class=\"crumb\" href=\"\(href)\">")
        }
        return result
    }
}
