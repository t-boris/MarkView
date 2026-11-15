import Foundation

/// Local groundwork for the X-Ray analysis, built without AI in about a second.
///
/// The AI used to explore the repository itself, one file read per round trip, which
/// made large projects take many minutes. Instead this collects what it needs up front
/// — per folder: manifest name and description, the README's first line, declared
/// names, file names and which other folders it imports — so every AI call is a single
/// pass with no tools. It also picks the folders the AI describes ("units"; deeper
/// folders follow their nearest unit) and arranges them as a tree; `XRayCluster`
/// groups them from how they are connected.
enum XRayDigest {
    struct Folder {
        /// Workspace-relative folder path ("" = project root).
        let path: String
        /// Structure-view node id ("m:<path>").
        let nodeId: String
        let files: Int
        let loc: Int
        /// "name — description" from package.json, pyproject.toml, Cargo.toml or go.mod.
        var package: String?
        /// First line of prose from the folder's README.
        var readme: String?
        var declarations: [String] = []
        var fileNames: [String] = []
        /// Other units this folder imports from, most used first.
        var dependsOn: [String] = []
        /// Language its documents are written in ("English" for code): names follow it.
        var textLanguage = "English"
        /// Letters seen in its documents: Cyrillic and Latin (for the majority vote).
        var cyrillic = 0
        var latin = 0

        /// One prompt line.
        var line: String {
            var text = "- \(path.isEmpty ? "(root)" : path + "/") (\(files) files, \(loc) lines)"
            if let package { text += " | package: " + package }
            if let readme { text += " | readme: " + readme }
            if !declarations.isEmpty { text += " | defines: " + declarations.joined(separator: ", ") }
            if !fileNames.isEmpty { text += " | files: " + fileNames.joined(separator: ", ") }
            if !dependsOn.isEmpty { text += " | uses: " + dependsOn.joined(separator: ", ") }
            return text
        }
    }

    struct Plan {
        let units: [Folder]
        /// Project-level context shared by every AI call.
        let overview: String
        /// Unit folder → its unit subfolders ("" = project root), sorted by path.
        let children: [String: [String]]

        var unitByPath: [String: Folder] { Dictionary(units.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }) }

        /// `folders` and their unit subfolders down to `levels` more levels, as they would
        /// be listed for one call (parents before children).
        func subtree(of folders: [String], levels: Int) -> [String] {
            var out: [String] = [], seen = Set<String>()
            func visit(_ path: String, _ depth: Int) {
                guard seen.insert(path).inserted else { return }
                out.append(path)
                guard depth < levels else { return }
                for child in children[path] ?? [] { visit(child, depth + 1) }
            }
            for folder in folders { visit(folder, 0) }
            return out
        }

        /// `tree`-style listing: indentation by depth below the shallowest folder, full
        /// paths so answers can refer to them; digest facts only for undescribed folders.
        func treeText(_ paths: [String], described: Set<String>) -> String {
            let byPath = unitByPath
            let base = paths.map { $0.isEmpty ? 0 : $0.split(separator: "/").count }.min() ?? 0
            return paths.compactMap { path -> String? in
                guard let folder = byPath[path] else { return nil }
                let depth = (path.isEmpty ? 0 : path.split(separator: "/").count) - base
                let indent = String(repeating: "  ", count: max(0, depth))
                if described.contains(path) {
                    return indent + "- \(path.isEmpty ? "(root)" : path + "/") (\(folder.files) files) [known]"
                }
                return indent + folder.line
            }.joined(separator: "\n")
        }
    }

    static let maxUnits = 360

    // MARK: - Plan

    static func plan(root: URL, modules: ArchView) -> Plan {
        let folders = modules.nodes.filter { ["dir", "package"].contains($0.kind) && $0.files > 0 && $0.path != nil }
        func depth(_ path: String) -> Int { path.isEmpty ? 0 : path.split(separator: "/").count }

        // As deep as fits: drop the deepest levels until the unit count is manageable.
        var maxDepth = folders.map { depth($0.path ?? "") }.max() ?? 0
        while maxDepth > 1, folders.filter({ depth($0.path ?? "") <= maxDepth }).count > maxUnits { maxDepth -= 1 }
        var chosen = folders.filter { depth($0.path ?? "") <= maxDepth }
        // Every ordering below breaks ties by path: the prompt must be identical for the
        // same project, or the answer cache never hits.
        if chosen.count > maxUnits {
            chosen = Array(chosen.sorted { ($0.loc, $1.path ?? "") > ($1.loc, $0.path ?? "") }.prefix(maxUnits))
        }
        var unitPaths = Set(chosen.compactMap(\.path))

        let files = modules.nodes.filter { $0.kind == "file" && $0.path != nil }
        // Files directly in the project root form their own unit.
        if files.contains(where: { !($0.path ?? "").contains("/") }) { unitPaths.insert("") }

        func unit(ofFolder folder: String) -> String {
            var candidate = folder
            while !candidate.isEmpty && !unitPaths.contains(candidate) {
                candidate = (candidate as NSString).deletingLastPathComponent
            }
            return unitPaths.contains(candidate) ? candidate : ""
        }
        func unit(ofFile path: String) -> String { unit(ofFolder: (path as NSString).deletingLastPathComponent) }

        var filesByUnit: [String: [ArchNode]] = [:]
        for file in files { filesByUnit[unit(ofFile: file.path ?? ""), default: []].append(file) }

        // Folder-to-folder dependencies from the scanner's file-level import edges.
        var uses: [String: [String: Int]] = [:]
        for edge in modules.edges where edge.source.hasPrefix("m:") && edge.target.hasPrefix("m:") {
            let from = unit(ofFile: String(edge.source.dropFirst(2)))
            let to = unit(ofFile: String(edge.target.dropFirst(2)))
            if from != to { uses[from, default: [:]][to, default: 0] += edge.weight }
        }

        let nodeByPath = Dictionary(folders.map { ($0.path ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        var units: [Folder] = []
        for path in unitPaths.sorted() {
            let unitFiles = (filesByUnit[path] ?? []).sorted { ($0.loc, $1.path ?? "") > ($1.loc, $0.path ?? "") }
            guard !unitFiles.isEmpty, path.isEmpty || nodeByPath[path] != nil else { continue }
            let folderURL = path.isEmpty ? root : root.appendingPathComponent(path)
            var folder = Folder(path: path, nodeId: "m:" + path,
                                files: unitFiles.count, loc: unitFiles.reduce(0) { $0 + $1.loc },
                                package: manifestSummary(in: folderURL), readme: readmeLine(in: folderURL))
            folder.fileNames = unitFiles.prefix(10).compactMap { ($0.path as NSString?)?.lastPathComponent }
            var names: [String] = []
            for file in unitFiles.prefix(6) {
                for name in declarations(in: root.appendingPathComponent(file.path ?? ""), language: file.language)
                where !names.contains(name) { names.append(name) }
                if names.count >= 10 { break }
            }
            folder.declarations = Array(names.prefix(10))
            // The language of its prose (notes and docs), sampled locally; code counts as English.
            for file in unitFiles.prefix(8) where file.language == "markdown" {
                guard let text = read(root.appendingPathComponent(file.path ?? ""), limit: 4096) else { continue }
                for scalar in text.unicodeScalars {
                    if (0x0400...0x04FF).contains(scalar.value) { folder.cyrillic += 1 }
                    else if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) { folder.latin += 1 }
                }
            }
            folder.textLanguage = Self.language(cyrillic: folder.cyrillic, latin: folder.latin)
            folder.dependsOn = (uses[path] ?? [:]).sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5)
                .map { $0.key.isEmpty ? "(root)" : $0.key }
            units.append(folder)
        }

        // Unit tree: each unit's parent is its nearest unit ancestor (the root unit "" at the top).
        let kept = Set(units.map(\.path))
        var children: [String: [String]] = [:]
        for unit in units where !unit.path.isEmpty {
            var parent = (unit.path as NSString).deletingLastPathComponent
            while !parent.isEmpty && !kept.contains(parent) { parent = (parent as NSString).deletingLastPathComponent }
            children[parent, default: []].append(unit.path)
        }
        for key in children.keys { children[key]?.sort() }

        return Plan(units: units, overview: overview(root: root, modules: modules, units: units), children: children)
    }

    private static func overview(root: URL, modules: ArchView, units: [Folder]) -> String {
        var text = "Project: \(root.lastPathComponent)"
        if let manifest = manifestSummary(in: root) { text += "\nRoot package: " + manifest }
        if let readme = readmeParagraph(in: root) { text += "\nREADME: " + readme }
        let top = modules.nodes.filter { $0.parent == "m:" && ["dir", "package"].contains($0.kind) }
            .sorted { ($0.loc, $1.path ?? "") > ($1.loc, $0.path ?? "") }
            .map { "\($0.path ?? $0.name)/ (\($0.files) files)" }
        if !top.isEmpty { text += "\nTop-level folders: " + top.joined(separator: ", ") }
        text += "\nTotal: \(units.reduce(0) { $0 + $1.files }) files in \(units.count) described folders."
        return text
    }

    /// "Russian" when Cyrillic makes up a real share of the letters, else "English".
    static func language(cyrillic: Int, latin: Int) -> String {
        cyrillic > 0 && Double(cyrillic) > Double(latin) * 0.3 ? "Russian" : "English"
    }

    // MARK: - File facts

    private static func read(_ url: URL, limit: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return single.count > limit ? String(single.prefix(limit)) + "…" : single
    }

    /// "name — description" of the package whose manifest sits in `folder`.
    static func manifestSummary(in folder: URL) -> String? {
        if let text = read(folder.appendingPathComponent("package.json")),
           let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            let name = object["name"] as? String ?? folder.lastPathComponent
            let description = (object["description"] as? String).map { " — " + clip($0, 140) } ?? ""
            return name + description
        }
        for file in ["pyproject.toml", "Cargo.toml"] {
            guard let text = read(folder.appendingPathComponent(file)) else { continue }
            let name = tomlValue("name", in: text) ?? folder.lastPathComponent
            return name + (tomlValue("description", in: text).map { " — " + clip($0, 140) } ?? "")
        }
        if let text = read(folder.appendingPathComponent("go.mod")),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("module ") }) {
            return String(line.dropFirst("module ".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func tomlValue(_ key: String, in text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(key), let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            return line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return nil
    }

    private static func readmeText(in folder: URL) -> String? {
        for name in ["README.md", "readme.md", "Readme.md", "README"] {
            if let text = read(folder.appendingPathComponent(name), limit: 16 * 1024) { return text }
        }
        return nil
    }

    /// Prose lines of a README: no headings, badges, HTML, tables or code.
    private static func proseLines(_ text: String) -> [String] {
        var inFence = false
        return text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); return nil }
            if inFence || line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[![") || line.hasPrefix("<")
                || line.hasPrefix("|") || line.hasPrefix("---") || line.hasPrefix("![") { return nil }
            return line
        }
    }

    static func readmeLine(in folder: URL) -> String? {
        readmeText(in: folder).flatMap { proseLines($0).first }.map { clip($0, 160) }
    }

    private static func readmeParagraph(in folder: URL) -> String? {
        guard let text = readmeText(in: folder) else { return nil }
        let lines = proseLines(text).prefix(6)
        return lines.isEmpty ? nil : clip(lines.joined(separator: " "), 600)
    }

    private static let declarationPatterns: [String: NSRegularExpression] = {
        func re(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: options)
        }
        let script = re(#"^export\s+(?:default\s+)?(?:async\s+)?(?:function\*?|class|const|let|interface|type|enum)\s+([A-Za-z_$][\w$]*)"#)
        return [
            "javascript": script, "typescript": script,
            "swift": re(#"^(?:@\w+\s+)*(?:public\s+|open\s+|final\s+|internal\s+)*(?:class|struct|enum|protocol|actor)\s+([A-Za-z_]\w*)"#),
            "python": re(#"^(?:class|def|async\s+def)\s+([A-Za-z_]\w*)"#),
            "go": re(#"^(?:func\s+(?:\([^)]*\)\s*)?|type\s+)([A-Z]\w*)"#),
            "rust": re(#"^pub\s+(?:async\s+)?(?:fn|struct|enum|trait|mod)\s+([A-Za-z_]\w*)"#),
            "java": re(#"^\s*public\s+(?:abstract\s+|final\s+)*(?:class|interface|enum|record)\s+([A-Za-z_]\w*)"#),
            "kotlin": re(#"^(?:data\s+|sealed\s+|abstract\s+|open\s+)*(?:class|interface|object|fun)\s+([A-Za-z_]\w*)"#),
            "csharp": re(#"^\s*public\s+(?:static\s+|abstract\s+|sealed\s+|partial\s+)*(?:class|interface|enum|record|struct)\s+([A-Za-z_]\w*)"#),
            // Notes and docs: their headings say what they are about.
            "markdown": re(#"^#{1,3}[ \t]+(.+?)[ \t#]*$"#),
            "sql": re(#"^\s*create\s+(?:or\s+replace\s+)?(?:table|view|function|procedure|type)\s+(?:if\s+not\s+exists\s+)?([\w."]+)"#,
                      [.anchorsMatchLines, .caseInsensitive]),
        ]
    }()

    /// Names a source file declares at top level (exported where the language marks it).
    static func declarations(in file: URL, language: String?) -> [String] {
        guard let language, let regex = declarationPatterns[language], let text = read(file) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).prefix(12).compactMap { match in
            Range(match.range(at: 1), in: text).map { raw -> String in
                // Headings carry emphasis markup; keep the words.
                let clean = String(text[raw]).filter { !"*_`\"".contains($0) }.trimmingCharacters(in: .whitespaces)
                return clean.count > 60 ? String(clean.prefix(60)) + "…" : clean
            }
        }.filter { !$0.isEmpty }
    }

    /// Contents of the build and deploy config files, clipped, for the Deployment prompt.
    static func configExcerpts(root: URL, paths: [String], perFile: Int = 4000, total: Int = 40000) -> String {
        var out = "", used = 0
        for path in paths {
            guard used < total, let text = read(root.appendingPathComponent(path), limit: perFile) else { continue }
            let body = text.count >= perFile ? text + "\n[…clipped]" : text
            out += "\n=== \(path) ===\n\(body)\n"
            used += body.count
        }
        return out
    }
}

// MARK: - Answers in progress

extension XRayDigest {
    /// Complete objects of the array `key` in a JSON answer that is still being written,
    /// e.g. the components already finished while the assistant writes the folders.
    /// Unfinished trailing objects are left out.
    static func completedObjects(in partial: String, key: String) -> [[String: Any]] {
        let chars = Array(partial.utf8)
        guard let start = arrayStart(of: key, in: chars) else { return [] }
        var objects: [[String: Any]] = []
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: "]") { break }
            if c == UInt8(ascii: "{") {
                guard let end = objectEnd(chars, from: i) else { break }
                if let object = (try? JSONSerialization.jsonObject(with: Data(chars[i...end]))) as? [String: Any] {
                    objects.append(object)
                }
                i = end + 1
                continue
            }
            i += 1
        }
        return objects
    }

    /// The object value of `key`, once it is complete.
    static func completedObject(in partial: String, key: String) -> [String: Any]? {
        let chars = Array(partial.utf8)
        guard let colon = keyValueStart(of: key, in: chars) else { return nil }
        var i = colon
        while i < chars.count, chars[i] != UInt8(ascii: "{") { i += 1 }
        guard i < chars.count, let end = objectEnd(chars, from: i) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(chars[i...end]))) as? [String: Any]
    }

    /// The string value of `key`, once its closing quote has been written.
    static func completedString(in partial: String, key: String) -> String? {
        let chars = Array(partial.utf8)
        guard var i = keyValueStart(of: key, in: chars) else { return nil }
        while i < chars.count, chars[i] != UInt8(ascii: "\"") { i += 1 }
        let open = i
        var escaped = false
        i += 1
        while i < chars.count {
            if escaped { escaped = false } else if chars[i] == UInt8(ascii: "\\") { escaped = true } else if chars[i] == UInt8(ascii: "\"") {
                return (try? JSONSerialization.jsonObject(with: Data(chars[open...i]), options: .fragmentsAllowed)) as? String
            }
            i += 1
        }
        return nil
    }

    /// Index just past `"key"` and its colon.
    private static func keyValueStart(of key: String, in chars: [UInt8]) -> Int? {
        let needle = Array("\"\(key)\"".utf8)
        guard chars.count >= needle.count else { return nil }
        var i = 0
        while i <= chars.count - needle.count {
            if chars[i] == needle[0] && Array(chars[i..<i + needle.count]) == needle {
                var j = i + needle.count
                while j < chars.count, chars[j] == UInt8(ascii: " ") || chars[j] == 10 || chars[j] == 13 || chars[j] == 9 { j += 1 }
                if j < chars.count, chars[j] == UInt8(ascii: ":") { return j + 1 }
            }
            i += 1
        }
        return nil
    }

    private static func arrayStart(of key: String, in chars: [UInt8]) -> Int? {
        guard var i = keyValueStart(of: key, in: chars) else { return nil }
        while i < chars.count, chars[i] != UInt8(ascii: "[") { i += 1 }
        return i < chars.count ? i + 1 : nil
    }

    /// Index of the `}` closing the object that opens at `from`, or nil if not written yet.
    private static func objectEnd(_ chars: [UInt8], from: Int) -> Int? {
        var depth = 0, inString = false, escaped = false
        var i = from
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") { inString = false }
            } else if c == UInt8(ascii: "\"") {
                inString = true
            } else if c == UInt8(ascii: "{") {
                depth += 1
            } else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }
}
