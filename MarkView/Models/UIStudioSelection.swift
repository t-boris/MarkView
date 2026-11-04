import Foundation

/// The selected element and what is known of its source (SelectionContext, §10.1; PRE-06…PRE-10). The page runtime reads
/// the framework's development metadata (React fibers, Vue component instances, Svelte element locations, Angular
/// components); the session checks the paths against the project and reads the source around the mapped line.
struct StudioSelectionContext: Equatable {
    enum Mapping: String {
        /// The element's own location in a source file (React `_debugSource`, Svelte `__svelte_meta`).
        case exact
        /// The file of the component that renders it (Vue, Angular, React without element locations).
        case component
        /// No development metadata: a text search found candidates; ambiguous until checked.
        case candidate
        case none
    }

    var id: String
    var tag: String
    var selector: String
    var html: String
    var text: String
    var route: String
    var url: String
    var rect: CGRectValue
    var styles: [String: String]
    var framework: String
    var mapping: Mapping
    var sourcePath: String?
    var line: Int?
    var column: Int?
    var component: String?
    /// The source node's identity (file:line:column or component file), shared by every instance (PRE-08).
    var sourceNodeId: String?
    /// The instance's own identity on this page (fiber path, component uid).
    var instanceId: String?
    var instanceIndex: Int
    var instanceCount: Int
    /// What identifies the element when its position on the page changes (BUG-068).
    var classes: [String] = []
    var role: String? = nil
    var label: String? = nil
    var boundary: String?
    var snippet: String? = nil
    var snippetHash: String? = nil
    var imagePath: String? = nil
    var revision: StudioRevision? = nil
    var scenarioId: String? = nil
    /// The selection was checked again after a change and still points at the same source (PRE-09).
    var revalidated = false

    struct CGRectValue: Equatable {
        var x: Double, y: Double, width: Double, height: Double
    }

    var mappingDescription: String {
        guard let sourcePath else {
            return mapping == .none ? "none — no development metadata links this element to a source file" : mapping.rawValue
        }
        var text = sourcePath + (line.map { ":\($0)" } ?? "") + (column.map { ":\($0)" } ?? "")
        switch mapping {
        case .exact: text += " (element)"
        case .component: text += " (component file)"
        case .candidate: text += " (candidate, unverified)"
        case .none: break
        }
        return text
    }

    /// From the page runtime's description; nil when it is not a usable element.
    init?(_ object: [String: Any], id: String = UUID().uuidString) {
        guard let rect = object["rect"] as? [String: Any],
              let x = (rect["x"] as? NSNumber)?.doubleValue, let y = (rect["y"] as? NSNumber)?.doubleValue,
              let width = (rect["width"] as? NSNumber)?.doubleValue, let height = (rect["height"] as? NSNumber)?.doubleValue
        else { return nil }
        self.id = id
        self.rect = CGRectValue(x: x, y: y, width: width, height: height)
        tag = String((object["tag"] as? String ?? "element").prefix(200))
        selector = String((object["selector"] as? String ?? "").prefix(2_000))
        html = String((object["html"] as? String ?? "").prefix(40_000))
        text = String((object["text"] as? String ?? "").prefix(2_000))
        route = String((object["route"] as? String ?? "/").prefix(2_000))
        url = String((object["url"] as? String ?? "").prefix(4_000))
        var styles: [String: String] = [:]
        for (name, value) in (object["styles"] as? [String: Any] ?? [:]).prefix(80) {
            if let value = value as? String { styles[String(name.prefix(60))] = String(value.prefix(300)) }
        }
        self.styles = styles
        let source = object["source"] as? [String: Any] ?? [:]
        framework = String((source["framework"] as? String ?? "").prefix(40))
        mapping = Mapping(rawValue: source["mapping"] as? String ?? "none") ?? .none
        sourcePath = (source["file"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(2_000)) }
        line = (source["line"] as? NSNumber)?.intValue
        column = (source["column"] as? NSNumber)?.intValue
        component = (source["component"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        sourceNodeId = (source["nodeId"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(2_000)) }
        instanceId = (source["instanceId"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
        instanceIndex = max(0, (source["instanceIndex"] as? NSNumber)?.intValue ?? 0)
        instanceCount = max(1, (source["instanceCount"] as? NSNumber)?.intValue ?? 1)
        classes = (object["classes"] as? [Any] ?? []).prefix(40).compactMap { ($0 as? String).map { String($0.prefix(200)) } }
        role = (object["role"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(100)) }
        label = (object["label"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        boundary = (object["boundary"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
    }

    /// The element's tag name (`button` of `button.cta`).
    var tagName: String { String(tag.prefix { $0.isLetter || $0.isNumber || $0 == "-" }).lowercased() }

    /// The start of the element's text with whitespace collapsed, as the page runtime compares it.
    var textKey: String {
        String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(120))
    }

    /// What the page runtime needs to look for the element anywhere on the page (`similar`, `selectSimilar`).
    var fingerprint: [String: Any] {
        ["tag": tagName, "component": component ?? "", "classes": classes, "text": textKey]
    }

    /// The project-relative file of a path the framework reported: an absolute path inside the project, a path relative to
    /// the app folder, or a dev-server URL (`http://localhost:5173/src/App.tsx?t=1`). nil when it is outside the project
    /// or does not exist (paths are validated here, at the boundary).
    static func projectPath(_ reported: String, root: URL, appFolder: URL) -> String? {
        var text = reported.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme) {
            text = url.path
            if text.hasPrefix("/@fs/") { text = String(text.dropFirst(4)) }
        } else if text.hasPrefix("webpack://") {
            text = String(text.dropFirst("webpack://".count)).drop { $0 != "/" }.description
        }
        if let query = text.firstIndex(of: "?") { text = String(text[..<query]) }
        text = text.removingPercentEncoding ?? text
        guard !text.isEmpty, !text.contains("\0") else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        var candidates: [URL] = []
        if text.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: text))
            candidates.append(appFolder.appendingPathComponent(String(text.dropFirst())))
            candidates.append(root.appendingPathComponent(String(text.dropFirst())))
        } else {
            candidates.append(appFolder.appendingPathComponent(text))
            candidates.append(root.appendingPathComponent(text))
        }
        for candidate in candidates {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(base + "/"), FileManager.default.fileExists(atPath: resolved) else { continue }
            return String(resolved.dropFirst(base.count + 1))
        }
        return nil
    }

    /// The lines around `line` (1-based), numbered, for the assistant and for revalidation.
    static func snippet(of text: String, line: Int, radius: Int = 6) -> String {
        let lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return "" }
        let start = max(1, line - radius), end = min(lines.count, line + radius)
        return (start...end).map { String(format: "%5d%@ %@", $0, $0 == line ? ">" : " ", lines[$0 - 1]) }.joined(separator: "\n")
    }

    /// The exact line a mapping points at, as a hash: when it changes the mapping must be checked again (PRE-09).
    static func lineHash(of text: String, line: Int) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return nil }
        return StudioHash.sha256(lines[line - 1].trimmingCharacters(in: .whitespaces))
    }
}

/// What happens to a selection after the code changed (PRE-09): kept, moved to the element that now stands for it, or
/// cleared when that is ambiguous.
enum StudioSelectionRevalidation: Equatable {
    case kept(StudioSelectionContext)
    case remapped(StudioSelectionContext)
    case cleared(String)

    /// `candidates` are elements that may be the selected one (those matching the old selector, or the page runtime's
    /// `similar` search), with their source information. Only a candidate that is the same element counts (BUG-068): a
    /// positional selector finds whatever now sits where the element was, which after a restore can be another element.
    /// `afterEdit` is the check after a change, when the element's own classes and text may have changed.
    static func decide(previous: StudioSelectionContext, candidates all: [StudioSelectionContext],
                       afterEdit: Bool = false) -> StudioSelectionRevalidation {
        let candidates = all.filter { sameElement($0, as: previous, afterEdit: afterEdit) }
        guard !candidates.isEmpty else {
            return .cleared(afterEdit ? "The selected element is no longer on the page after the change."
                                      : "The selected element is not on the restored page.")
        }
        if let node = previous.sourceNodeId {
            let same = candidates.filter { $0.sourceNodeId == node }
            if let match = same.first(where: { $0.instanceIndex == previous.instanceIndex }) ?? (same.count == 1 ? same.first : nil) {
                var next = match
                next.id = previous.id
                next.revalidated = true
                return .kept(next)
            }
        }
        // The source moved (lines shifted by the edit): one element in the same place of the page is the same element.
        let positioned = candidates.filter { $0.instanceIndex == previous.instanceIndex || candidates.count == 1 }
        if positioned.count == 1 || candidates.count == 1 {
            var next = positioned.first ?? candidates[0]
            next.id = previous.id
            next.revalidated = true
            return .remapped(next)
        }
        return .cleared("The change left \(candidates.count) elements that could be the selected one; select it again.")
    }

    /// Whether `candidate` is the element `previous` described: the same tag, the same source node or component, and
    /// (unless a change may have altered them) the same classes and text.
    static func sameElement(_ candidate: StudioSelectionContext, as previous: StudioSelectionContext, afterEdit: Bool) -> Bool {
        guard candidate.tagName == previous.tagName else { return false }
        if let node = previous.sourceNodeId, candidate.sourceNodeId == node { return true }
        if let component = previous.component, candidate.component != component { return false }
        let sameClasses = Set(candidate.classes) == Set(previous.classes)
        let sameText = candidate.textKey == previous.textKey
        if afterEdit {
            if previous.component != nil { return true }
            let union = Set(candidate.classes).union(previous.classes)
            let shared = Set(candidate.classes).intersection(previous.classes)
            return sameClasses || sameText || (!union.isEmpty && Double(shared.count) / Double(union.count) >= 0.5)
        }
        return sameClasses && (sameText || previous.component != nil)
    }
}
