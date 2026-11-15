import Foundation

/// Where a selected element's source is, checked against the project (PRE-07, PRE-10): a reported path must be a file of
/// the project, a line must look like the element, and without metadata a search proposes candidates — never a guess
/// presented as certain.
struct StudioSourceResolution: Sendable {
    var path: String?
    var line: Int?
    var mapping: StudioSelectionContext.Mapping
    var snippet: String?
    var lineHash: String?
    var note: String?

    static func resolve(_ context: StudioSelectionContext, root: URL, appFolder: URL, tagName: String) -> StudioSourceResolution {
        var outside: String?
        if let reported = context.sourcePath {
            if let path = StudioSelectionContext.projectPath(reported, root: root, appFolder: appFolder), !StudioSourceMap.isGenerated(path) {
                let text = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
                var line = context.line
                if let given = line { line = refine(text, line: given, tagName: tagName) }
                else if let found = locate(text, tagName: tagName, context: context) { line = found }
                let snippet = line.map { StudioSelectionContext.snippet(of: text, line: $0) }
                return StudioSourceResolution(path: path, line: line, mapping: context.mapping, snippet: snippet,
                                              lineHash: line.flatMap { StudioSelectionContext.lineHash(of: text, line: $0) })
            }
            // A bundled chunk without a usable source map, or a file outside the project: never read; search instead.
            outside = "The framework named a bundled or outside file, not a project source."
        }
        // No usable location: search the sources for the component and the element, and say it is a candidate.
        let candidates = search(context, root: root, appFolder: appFolder)
        if candidates.count == 1, let first = candidates.first {
            let text = (try? String(contentsOf: root.appendingPathComponent(first.path), encoding: .utf8)) ?? ""
            return StudioSourceResolution(path: first.path, line: first.line, mapping: .candidate,
                                          snippet: StudioSelectionContext.snippet(of: text, line: first.line),
                                          lineHash: StudioSelectionContext.lineHash(of: text, line: first.line),
                                          note: "Found by searching the sources, not by development metadata: check it.")
        }
        if candidates.count > 1 {
            return StudioSourceResolution(path: nil, line: nil, mapping: .candidate,
                                          note: "\(candidates.count) candidate files: " + candidates.prefix(5).map { "\($0.path):\($0.line)" }.joined(separator: ", ") + ".")
        }
        return StudioSourceResolution(path: nil, line: nil, mapping: .none, note: outside)
    }

    /// A framework's line can be off by one (0- or 1-based); the line that opens the element's tag wins.
    static func refine(_ text: String, line: Int, tagName: String) -> Int {
        guard !tagName.isEmpty else { return line }
        let lines = text.components(separatedBy: "\n")
        for candidate in [line, line + 1, line - 1] where candidate >= 1 && candidate <= lines.count {
            if lines[candidate - 1].localizedCaseInsensitiveContains("<" + tagName) { return candidate }
        }
        return line
    }

    /// In a component file without a line: the only line that opens the tag with the element's first class.
    static func locate(_ text: String, tagName: String, context: StudioSelectionContext) -> Int? {
        let classes = context.tag.split(separator: ".").dropFirst().map(String.init)
        let lines = text.components(separatedBy: "\n")
        let matches = lines.indices.filter { index in
            let line = lines[index]
            return line.contains("<" + tagName) && (classes.first.map { line.contains($0) } ?? true)
        }
        return matches.count == 1 ? matches[0] + 1 : nil
    }

    /// Source files that contain the element's id, an Angular component's class, its first class name or its short text.
    static func search(_ context: StudioSelectionContext, root: URL, appFolder: URL) -> [(path: String, line: Int)] {
        var needles: [String] = []
        if let component = context.component, !component.isEmpty, component.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) {
            needles.append("class \(component)")
            // A function component's definition (React, Solid, Preact).
            if context.framework == "react" || context.framework.isEmpty {
                needles += ["function \(component)(", "function \(component)<", "const \(component) =", "const \(component): "]
            }
        }
        let parts = context.tag.split(separator: "#", maxSplits: 1)
        if parts.count == 2 { needles.append("id=\"\(parts[1].split(separator: ".").first ?? "")\"") }
        if let firstClass = context.tag.split(separator: ".").dropFirst().first, firstClass.count >= 3 { needles.append(String(firstClass)) }
        let text = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (4...80).contains(text.count), !text.contains("\n") { needles.append(text) }
        guard !needles.isEmpty, let enumerator = FileManager.default.enumerator(at: appFolder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                              options: [.skipsHiddenFiles]) else { return [] }
        let extensions: Set<String> = ["tsx", "jsx", "ts", "js", "vue", "svelte", "html", "astro", "hbs", "erb", "njk"]
        let skipped = StudioSourceMap.generatedFolders.union(["node_modules", "coverage", "vendor"])
        let base = root.standardizedFileURL.path
        var files: [URL] = []
        for case let url as URL in enumerator {
            if skipped.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            if extensions.contains(url.pathExtension.lowercased()) { files.append(url) }
            if files.count >= 3_000 { break }
        }
        for needle in needles {
            var found: [(String, Int)] = []
            for file in files {
                guard let content = try? String(contentsOf: file, encoding: .utf8), let range = content.range(of: needle) else { continue }
                let line = content[..<range.lowerBound].filter { $0 == "\n" }.count + 1
                let path = file.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                found.append((String(path.dropFirst(base.count + 1)), line))
                if found.count > 8 { break }
            }
            if !found.isEmpty { return found.map { (path: $0.0, line: $0.1) } }
        }
        return []
    }
}
