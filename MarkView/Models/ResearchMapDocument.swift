import Foundation

/// Research maps (feature mind-map, DEC-006, DEC-007, DEC-009): the Markdown format of a map, its
/// parsing that tolerates edits made in a text editor, and every rule of the map (cascade delete,
/// duplicate connections, recursive layout). The map view in the
/// editor page only draws a snapshot of this model and sends operations; nothing else implements
/// the format. Pure (Foundation, FrontMatter and ResearchDocument), so `tools/tests` can compile it alone.
///
/// File layout: front matter (`type: research-map`, id, title, question, created, status, incomplete,
/// targets, attachments, web_queries), `# title`, `## Question`, `## Map` (nested list of
/// `[Title](#id)`), `## Connections` (`[A](#id) ↔ [B](#id)`), `## Nodes` (one `### Title {#id}` section
/// per node: property list, description, `#### Evidence`). Sections the app does not know are kept.
struct ResearchMap: Equatable {
    // MARK: Types

    enum Status: String {
        case researching, complete, incomplete
    }

    typealias Label = ResearchDocument.Label

    struct Evidence: Equatable {
        var label: Label
        var text: String
        /// A repository path (`path` or `path:line`), a URL, or empty.
        var source: String
    }

    struct Node: Equatable {
        var id: String
        /// Empty for the root.
        var parent: String
        var title: String
        var tags: [String] = []
        /// `#rrggbb` or empty.
        var color = ""
        /// A built-in icon id (`ResearchMap.iconIDs`), one emoji, or empty (REQ-008, DEC-011).
        var icon = ""
        /// The badge shown before the title, 1 to `numberLimit`: step order, phase number (REQ-008).
        var number: Int?
        /// A shape id from `ResearchMap.shapes`, or empty for the default rounded rectangle (REQ-009, DEC-012).
        var shape = ""
        /// Minimum width and height in map pixels (`widthRange`, `heightRange`); nil means automatic (REQ-009, DEC-012).
        var width: Int?
        var height: Int?
        /// Markdown source of the description.
        var description = ""
        /// The node's own layout preset id, or empty (inherits).
        var layout = ""
        /// Manual position (centre, absolute map coordinates).
        var x: Int?
        var y: Int?
        var evidence: [Evidence] = []
    }

    struct Link: Equatable {
        var from: String
        var to: String
    }

    /// An operation the map refuses; the message is shown to the person as it is.
    struct Rejection: Error, Equatable {
        var message: String
    }

    /// A node the AI proposes (see `ResearchMapRun`).
    struct Draft {
        var title: String
        var description = ""
        var tags: [String] = []
        var evidence: [Evidence] = []
        /// Only set when the order of the nodes matters (steps, phases).
        var number: Int?
    }

    // MARK: Fields

    /// Front matter as read, so keys the app does not know survive a rewrite.
    var front = FrontMatter()
    var id = ""
    var created = ""
    var question = ""
    var status = Status.researching
    /// Why the research stopped (only while `status` is `.incomplete`).
    var incompleteReason = ""
    var targets: [String] = []
    var attachments: [String] = []
    var webQueries: [String] = []
    /// Outline (pre-)order, the root first. Children of a node keep their relative order.
    var nodes: [Node] = []
    var links: [Link] = []
    /// `##` sections the app does not know, verbatim (heading line included), in file order.
    var extraSections: [String] = []

    /// Equal when the map says the same; the front matter's unknown keys and order do not count.
    static func == (a: ResearchMap, b: ResearchMap) -> Bool {
        a.id == b.id && a.created == b.created && a.question == b.question && a.status == b.status
            && a.incompleteReason == b.incompleteReason && a.targets == b.targets && a.attachments == b.attachments
            && a.webQueries == b.webQueries && a.nodes == b.nodes && a.links == b.links && a.extraSections == b.extraSections
    }

    // MARK: Limits and presets

    static let titleLimit = 120
    static let tagLimit = 120
    static let tagCount = 30
    static let descriptionLimit = 200_000
    static let coordinateLimit = 1_000_000
    static let numberLimit = 999
    /// An emoji is one character; this bounds the bytes of a sequence with modifiers and joiners.
    static let emojiByteLimit = 40

    /// The built-in node icons (DEC-011). The page draws each one by its id and shows the ids as names; a check in
    /// `research-map-web-tests.sh` keeps this list and the page's drawings equal.
    static let iconIDs = [
        "check", "warning", "error", "info", "question", "bug", "lock", "key", "database", "server",
        "cloud", "user", "users", "clock", "calendar", "flag", "star", "heart", "bulb", "target",
        "rocket", "book", "file", "folder", "code", "terminal", "gear", "shield", "globe", "chain",
        "mail", "chat", "money", "chart", "trend", "bolt", "pin", "tag", "bell", "eye", "package",
    ]

    /// Node shapes in picker order (DEC-012). `defaultShape` is the look before shapes existed and is never written to
    /// the file. The page draws each shape by its id and renders its picker from this list; a check in
    /// `research-map-web-tests.sh` keeps the page's drawings and this list equal.
    static let defaultShape = "rounded"
    static let shapes: [(id: String, name: String)] = [
        ("rounded", "Rounded"), ("rectangle", "Rectangle"), ("pill", "Pill"), ("ellipse", "Ellipse"), ("diamond", "Diamond"),
    ]
    /// A node is at least as large as its text; these are the limits of the minimum that can be set (DEC-012).
    static let widthRange = 60...800
    static let heightRange = 28...600

    /// Layout presets in menu order (DEC-007). The page renders its menu from this list.
    static let layouts: [(id: String, name: String)] = [
        ("balanced", "Balanced"), ("right", "Right"), ("left", "Left"), ("down", "Top-down"),
        ("up", "Bottom-up"), ("radial", "Radial"), ("outline", "Outline"),
    ]

    static func isLayout(_ id: String) -> Bool { layouts.contains { $0.id == id } }

    /// A built-in icon id, or one emoji (a single character that presents as an emoji, with its modifiers and joiners).
    static func isIcon(_ text: String) -> Bool {
        if iconIDs.contains(text) { return true }
        guard text.count == 1, text.utf8.count <= emojiByteLimit, let character = text.first else { return false }
        return character.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
    }

    /// The icon as it is stored: valid or empty.
    static func clean(icon: String) -> String {
        let text = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        return isIcon(text) ? text : ""
    }

    static func isNumber(_ value: Int) -> Bool { (1...numberLimit).contains(value) }

    static func isShape(_ id: String) -> Bool { shapes.contains { $0.id == id } }

    /// The shape as it is stored: a known shape other than the default, or empty (the default).
    static func clean(shape: String) -> String {
        let id = shape.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id != defaultShape && isShape(id) ? id : ""
    }

    // MARK: Detection

    static func isMap(_ text: String) -> Bool {
        FrontMatter.split(text).0.string("type") == "research-map"
    }

    /// A new map: one root node named after the question, research running.
    static func new(id: String, question: String, created: String, targets: [String], attachments: [String]) -> ResearchMap {
        var map = ResearchMap()
        map.id = id
        map.created = created
        map.question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        map.targets = targets
        map.attachments = attachments
        map.nodes = [Node(id: "n1", parent: "", title: clean(title: firstLine(map.question)))]
        if map.nodes[0].title.isEmpty { map.nodes[0].title = "Research" }
        return map
    }

    // MARK: Queries

    var root: Node? { nodes.first }
    var title: String { root?.title ?? "" }

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    func index(of id: String) -> Int? { nodes.firstIndex { $0.id == id } }

    func children(of id: String) -> [Node] { nodes.filter { $0.parent == id } }

    /// Ids of every descendant of `id`, in outline order.
    func descendants(of id: String) -> [String] {
        var found = Set([id])
        var result: [String] = []
        for node in nodes where found.contains(node.parent) && !found.contains(node.id) {
            found.insert(node.id)
            result.append(node.id)
        }
        return result
    }

    /// Levels below the root (the root is 0).
    func depth(of id: String) -> Int {
        var depth = 0
        var current = node(id)
        while let node = current, !node.parent.isEmpty, depth <= nodes.count {
            depth += 1
            current = self.node(node.parent)
        }
        return depth
    }

    /// Whether `id` is `ancestor` or lies under it.
    func isInSubtree(_ id: String, of ancestor: String) -> Bool {
        id == ancestor || descendants(of: ancestor).contains(id)
    }

    func hasLink(_ a: String, _ b: String) -> Bool {
        links.contains { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }
    }

    /// `n<highest number + 1>`.
    func nextID() -> String {
        var highest = 0
        for node in nodes {
            if node.id.hasPrefix("n"), let number = Int(node.id.dropFirst()) { highest = max(highest, number) }
        }
        return "n\(highest + 1)"
    }

    // MARK: Operations (DEC-009)

    /// Adds a child as the last child of `parent`; returns its id.
    @discardableResult
    mutating func addNode(parent: String, draft: Draft) throws -> String {
        guard let parentIndex = index(of: parent) else { throw Rejection(message: "The parent node no longer exists.") }
        let title = Self.clean(title: draft.title)
        guard !title.isEmpty else { throw Rejection(message: "Give the node a name.") }
        var node = Node(id: nextID(), parent: parent, title: title)
        node.tags = Self.clean(tags: draft.tags)
        node.description = Self.clean(description: draft.description)
        node.evidence = draft.evidence
        if let number = draft.number, Self.isNumber(number) { node.number = number }
        let insertAt = parentIndex + 1 + descendants(of: parent).count
        nodes.insert(node, at: insertAt)
        return node.id
    }

    @discardableResult
    mutating func addChild(parent: String, title: String) throws -> String {
        try addNode(parent: parent, draft: Draft(title: title))
    }

    /// Changes the given properties of a node. Renaming the root renames the map.
    /// `icon`: "" clears it. `number`: `.some(nil)` clears it, `.some(n)` sets it (1 to `numberLimit`).
    /// `shape`: "" or the default shape's id restores the default look. `width`/`height`: `.some(nil)` makes it
    /// automatic, `.some(n)` sets the minimum (`widthRange`, `heightRange`).
    mutating func update(id: String, title: String? = nil, tags: [String]? = nil, color: String? = nil,
                         description: String? = nil, icon: String? = nil, number: Int?? = nil,
                         shape: String? = nil, width: Int?? = nil, height: Int?? = nil) throws {
        guard let i = index(of: id) else { throw Rejection(message: "That node no longer exists.") }
        if let title {
            let cleaned = Self.clean(title: title)
            guard !cleaned.isEmpty else { throw Rejection(message: "The name cannot be empty.") }
            nodes[i].title = cleaned
        }
        if let tags { nodes[i].tags = Self.clean(tags: tags) }
        if let color {
            guard color.isEmpty || Self.isColor(color) else { throw Rejection(message: "Colours are written #rrggbb.") }
            nodes[i].color = color.lowercased()
        }
        if let description {
            guard description.count <= Self.descriptionLimit else { throw Rejection(message: "The description is too long.") }
            nodes[i].description = Self.clean(description: description)
        }
        if let icon {
            let text = icon.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty || Self.isIcon(text) else { throw Rejection(message: "Choose an icon from the list, or paste one emoji.") }
            nodes[i].icon = text
        }
        if let number {
            if let value = number {
                guard Self.isNumber(value) else { throw Rejection(message: "A number is between 1 and \(Self.numberLimit).") }
                nodes[i].number = value
            } else {
                nodes[i].number = nil
            }
        }
        // Validate the shape-and-size group before applying any of it, so a refused value changes none of the three.
        let text = shape?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let text { guard text.isEmpty || Self.isShape(text) else { throw Rejection(message: "Choose one of the shapes in the list.") } }
        if let width, let value = width {
            guard Self.widthRange.contains(value) else {
                throw Rejection(message: "A width is between \(Self.widthRange.lowerBound) and \(Self.widthRange.upperBound).")
            }
        }
        if let height, let value = height {
            guard Self.heightRange.contains(value) else {
                throw Rejection(message: "A height is between \(Self.heightRange.lowerBound) and \(Self.heightRange.upperBound).")
            }
        }
        if let text { nodes[i].shape = Self.clean(shape: text) }
        if let width { nodes[i].width = width }
        if let height { nodes[i].height = height }
    }

    /// Numbers the children of a node 1, 2, 3 … in map order (REQ-008), or removes their numbers when `clear` is set.
    /// Returns how many children changed.
    @discardableResult
    mutating func numberChildren(of id: String, clear: Bool = false) throws -> Int {
        guard index(of: id) != nil else { throw Rejection(message: "That node no longer exists.") }
        var changed = 0
        var next = 1
        for i in nodes.indices where nodes[i].parent == id {
            let wanted: Int? = clear ? nil : next
            if next > Self.numberLimit && !clear { throw Rejection(message: "There are too many children to number.") }
            if nodes[i].number != wanted { nodes[i].number = wanted; changed += 1 }
            next += 1
        }
        return changed
    }

    /// Deletes a node with all its descendants and every connection that touches one of them.
    /// Returns the number of nodes removed. The root cannot be deleted.
    @discardableResult
    mutating func delete(id: String) throws -> Int {
        guard let i = index(of: id) else { throw Rejection(message: "That node no longer exists.") }
        guard !nodes[i].parent.isEmpty else { throw Rejection(message: "The root node cannot be deleted.") }
        let removed = Set([id] + descendants(of: id))
        nodes.removeAll { removed.contains($0.id) }
        links.removeAll { removed.contains($0.from) || removed.contains($0.to) }
        return removed.count
    }

    /// Moves a node to a position on the canvas without changing its parent.
    mutating func moveVisual(id: String, x: Int, y: Int) throws {
        guard let i = index(of: id) else { throw Rejection(message: "That node no longer exists.") }
        guard abs(x) <= Self.coordinateLimit, abs(y) <= Self.coordinateLimit else { throw Rejection(message: "That position is outside the map.") }
        nodes[i].x = x
        nodes[i].y = y
    }

    mutating func link(_ from: String, _ to: String) throws {
        guard from != to else { throw Rejection(message: "Choose two different nodes.") }
        guard node(from) != nil, node(to) != nil else { throw Rejection(message: "One of the nodes no longer exists.") }
        guard !hasLink(from, to) else { throw Rejection(message: "This connection already exists.") }
        links.append(Link(from: from, to: to))
    }

    mutating func unlink(_ from: String, _ to: String) {
        links.removeAll { ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from) }
    }

    /// Applies a layout to a branch and, recursively, to its whole subtree: the nested layouts and
    /// manual positions of every descendant are removed (DEC-005, DEC-007). An empty id clears the
    /// branch's own layout.
    mutating func applyLayout(id: String, layout: String) throws {
        guard let i = index(of: id) else { throw Rejection(message: "That node no longer exists.") }
        guard layout.isEmpty || Self.isLayout(layout) else { throw Rejection(message: "Unknown layout.") }
        nodes[i].layout = layout
        let below = Set(descendants(of: id))
        for j in nodes.indices where below.contains(nodes[j].id) {
            nodes[j].layout = ""
            nodes[j].x = nil
            nodes[j].y = nil
        }
    }

    mutating func addWebQueries(_ queries: [String]) {
        for query in queries {
            let cleaned = query.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty, !webQueries.contains(cleaned) { webQueries.append(cleaned) }
        }
    }

    mutating func markResearching() {
        status = .researching
        incompleteReason = ""
    }

    mutating func markComplete() {
        status = .complete
        incompleteReason = ""
    }

    mutating func markIncomplete(_ reason: String) {
        status = .incomplete
        incompleteReason = reason.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Normalising

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    static func clean(title: String) -> String {
        let line = title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let squeezed = line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(squeezed.prefix(titleLimit)).trimmingCharacters(in: .whitespaces)
    }

    static func clean(tags: [String]) -> [String] {
        var result: [String] = []
        for tag in tags {
            let cleaned = String(clean(title: tag).prefix(tagLimit))
            if cleaned.isEmpty || result.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) { continue }
            result.append(cleaned)
            if result.count == tagCount { break }
        }
        return result
    }

    static func clean(description: String) -> String {
        description.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isColor(_ text: String) -> Bool {
        guard text.count == 7, text.hasPrefix("#") else { return false }
        return text.dropFirst().allSatisfy { $0.isHexDigit }
    }

    // MARK: Evidence

    /// Evidence as the existing research verifies it: a [Project fact] must cite a repository file that
    /// exists and an [External fact] a URL; otherwise it becomes an [AI inference] with a note.
    static func verified(label: Label, text: String, source: String, pathExists: (String) -> Bool) -> Evidence {
        let text = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let source = source.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let checked = ResearchDocument.checkedFinding("[\(label.rawValue)] \(text) \(source)", pathExists: pathExists)
        guard checked.relabelled else { return Evidence(label: label, text: text, source: source) }
        let marker = "*(labelled as inference: "
        let note = checked.text.range(of: marker, options: .backwards).map {
            String(checked.text[$0.upperBound...].dropLast(2))
        } ?? "unverified"
        return Evidence(label: .aiInference, text: "\(text) (labelled as inference: \(note))", source: source)
    }
}

// MARK: - Parsing

extension ResearchMap {
    /// Why a file is not a readable map.
    struct Problem: Error, Equatable {
        var message: String
    }

    /// Reads a map from Markdown, tolerating hand edits (DEC-006). Fails only when the file is not a
    /// map: wrong front matter type, front matter the app cannot rewrite safely, or no `## Map` items.
    static func parse(_ text: String) -> Result<ResearchMap, Problem> {
        let (front, body) = FrontMatter.split(text)
        guard front.string("type") == "research-map" else {
            return .failure(Problem(message: "The front matter does not say type: research-map."))
        }
        guard front.isLossless else {
            return .failure(Problem(message: "The front matter has comments or lines the app cannot rewrite safely; remove them in the source."))
        }
        var map = ResearchMap()
        map.front = front
        map.id = front.string("id")
        map.created = front.string("created")
        map.question = front.string("question")
        map.status = Status(rawValue: front.string("status")) ?? .complete
        map.incompleteReason = front.string("incomplete")
        map.targets = front.strings("targets")
        map.attachments = front.strings("attachments")
        map.webQueries = front.strings("web_queries")

        let sections = splitSections(body)
        var mapLines: [String] = []
        var connectionLines: [String] = []
        var nodeLines: [String] = []
        var sawMap = false
        for section in sections {
            switch section.name.lowercased() {
            case "question":
                let q = section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !q.isEmpty { map.question = q }
            case "map": sawMap = true; mapLines = section.lines
            case "connections": connectionLines = section.lines
            case "nodes": nodeLines = section.lines
            default: map.extraSections.append(section.text)
            }
        }
        guard sawMap else { return .failure(Problem(message: "There is no \"## Map\" list.")) }

        // The outline: nested list of [Title](#id).
        var taken = Set<String>()
        var pending: [(indent: Int, id: String?, title: String, parentIndex: Int?)] = []
        var stack: [(indent: Int, index: Int)] = []
        for line in mapLines {
            guard let item = listItem(line) else { continue }
            while let top = stack.last, top.indent >= item.indent { stack.removeLast() }
            let (title, id) = outlineEntry(item.text)
            pending.append((item.indent, id, title, stack.last?.index))
            stack.append((item.indent, pending.count - 1))
        }
        guard !pending.isEmpty else { return .failure(Problem(message: "The \"## Map\" list has no items.")) }
        var highest = 0
        for entry in pending {
            if let id = entry.id, id.hasPrefix("n"), let number = Int(id.dropFirst()) { highest = max(highest, number) }
        }
        for line in nodeLines {
            if let id = nodeHeading(line)?.id, id.hasPrefix("n"), let number = Int(id.dropFirst()) { highest = max(highest, number) }
        }
        var ids: [String] = []
        for entry in pending {
            var id = entry.id ?? ""
            if id.isEmpty || taken.contains(id) {
                highest += 1
                id = "n\(highest)"
            }
            taken.insert(id)
            ids.append(id)
        }
        for (i, entry) in pending.enumerated() {
            // The first top-level item is the root; any other top-level item hangs under it.
            let parent = entry.parentIndex.map { ids[$0] } ?? (i == 0 ? "" : ids[0])
            let title = clean(title: entry.title)
            map.nodes.append(Node(id: ids[i], parent: parent, title: title.isEmpty ? "Untitled" : title))
        }
        map.normaliseOrder()

        // Per-node sections. Only a heading with a known {#id} starts one.
        var current: String?
        var buffers: [String: [String]] = [:]
        var inFence: String?
        for line in nodeLines {
            if let marker = fenceMarker(line) {
                if inFence == nil { inFence = marker } else if inFence == marker { inFence = nil }
            }
            if inFence == nil, let heading = nodeHeading(line) {
                // A heading with an {#id} always starts a section; one that names no node of the list
                // (or a second one for the same node) is an orphan and its text is dropped.
                if map.node(heading.id) != nil, buffers[heading.id] == nil {
                    current = heading.id
                    buffers[heading.id] = []
                } else {
                    current = nil
                }
                continue
            }
            if let current { buffers[current, default: []].append(line) }
        }
        for (id, lines) in buffers {
            guard let i = map.index(of: id) else { continue }
            applySection(lines, to: &map.nodes[i])
        }

        // Connections.
        for line in connectionLines {
            guard let item = listItem(line) else { continue }
            let found = anchorIDs(in: item.text)
            guard found.count >= 2 else { continue }
            let a = found[0], b = found[1]
            if a != b, map.node(a) != nil, map.node(b) != nil, !map.hasLink(a, b) { map.links.append(Link(from: a, to: b)) }
        }
        return .success(map)
    }

    /// Puts `nodes` into outline pre-order (children after their parent, siblings in file order).
    mutating func normaliseOrder() {
        guard !nodes.isEmpty else { return }
        var byParent: [String: [Node]] = [:]
        for node in nodes { byParent[node.parent, default: []].append(node) }
        var ordered: [Node] = []
        func walk(_ id: String) {
            for child in byParent[id] ?? [] {
                ordered.append(child)
                walk(child.id)
            }
        }
        if let root = nodes.first(where: { $0.parent.isEmpty }) {
            ordered.append(root)
            walk(root.id)
        }
        if ordered.count == nodes.count { nodes = ordered }
    }

    // MARK: Parsing helpers

    private struct Section {
        var name: String
        var lines: [String]
        /// The section as written, heading line included.
        var text: String
    }

    /// `##` sections of the body outside code fences; text before the first is dropped.
    private static func splitSections(_ body: String) -> [Section] {
        var sections: [Section] = []
        var inFence: String?
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let marker = fenceMarker(line) {
                if inFence == nil { inFence = marker } else if inFence == marker { inFence = nil }
            }
            if inFence == nil, line.hasPrefix("## ") {
                sections.append(Section(name: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), lines: [], text: line))
                continue
            }
            if !sections.isEmpty {
                sections[sections.count - 1].lines.append(line)
                sections[sections.count - 1].text += "\n" + line
            }
        }
        return sections.map { section in
            var section = section
            section.text = section.text.trimmingCharacters(in: .newlines)
            return section
        }
    }

    /// The fence opener/closer a line is (```` ``` ```` or `~~~`), or nil.
    private static func fenceMarker(_ line: String) -> String? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3 else { return nil }
        if trimmed.hasPrefix("```") { return "`" }
        if trimmed.hasPrefix("~~~") { return "~" }
        return nil
    }

    /// A list item's indentation (tabs count as four spaces) and text after the marker.
    private static func listItem(_ line: String) -> (indent: Int, text: String)? {
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            indent += first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        for marker in ["- ", "* ", "+ "] where rest.hasPrefix(marker) {
            return (indent, String(rest.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// `[Title](#id)` → (title, id); anything else is a title with no id.
    private static func outlineEntry(_ text: String) -> (String, String?) {
        guard text.hasPrefix("["), text.hasSuffix(")"), let close = text.range(of: "](#", options: .backwards) else {
            return (unescape(text), nil)
        }
        let id = String(text[close.upperBound...].dropLast())
        let title = String(text[text.index(after: text.startIndex)..<close.lowerBound])
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return (unescape(text), nil) }
        return (unescape(title), id)
    }

    /// Ids in `(#id)` links of a connection line, in order.
    private static func anchorIDs(in text: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "(#") {
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: ")") else { break }
            ids.append(String(after[..<close]))
            rest = after[after.index(after: close)...]
        }
        return ids
    }

    /// `### Title {#id}` → (title, id).
    private static func nodeHeading(_ line: String) -> (title: String, id: String)? {
        guard line.hasPrefix("### "), line.hasSuffix("}"), let open = line.range(of: "{#", options: .backwards) else { return nil }
        let id = String(line[open.upperBound...].dropLast())
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return (String(line[line.index(line.startIndex, offsetBy: 4)..<open.lowerBound]).trimmingCharacters(in: .whitespaces), id)
    }

    /// Property list, description and evidence of one node section.
    private static func applySection(_ lines: [String], to node: inout Node) {
        var rest = lines[...]
        while let first = rest.first, first.trimmingCharacters(in: .whitespaces).isEmpty { rest = rest.dropFirst() }
        while let first = rest.first, let (key, value) = property(first) {
            switch key {
            case "tags": node.tags = clean(tags: value.components(separatedBy: ","))
            case "color": node.color = isColor(value) ? value.lowercased() : ""
            case "icon": node.icon = clean(icon: value)
            case "number": node.number = Int(value).flatMap { isNumber($0) ? $0 : nil }
            case "shape": node.shape = clean(shape: value)
            case "width": node.width = Int(value).flatMap { widthRange.contains($0) ? $0 : nil }
            case "height": node.height = Int(value).flatMap { heightRange.contains($0) ? $0 : nil }
            case "layout": node.layout = isLayout(value) ? value : ""
            case "position":
                let parts = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]),
                   abs(x) <= coordinateLimit, abs(y) <= coordinateLimit {
                    node.x = x
                    node.y = y
                }
            default: break
            }
            rest = rest.dropFirst()
        }
        var description: [String] = []
        var evidence: [String] = []
        var inFence: String?
        var inEvidence = false
        for line in rest {
            if !inEvidence {
                if let marker = fenceMarker(line) {
                    if inFence == nil { inFence = marker } else if inFence == marker { inFence = nil }
                }
                if inFence == nil, line.trimmingCharacters(in: .whitespaces).lowercased() == "#### evidence", !line.hasPrefix(" ") {
                    inEvidence = true
                    continue
                }
                description.append(line)
            } else {
                evidence.append(line)
            }
        }
        node.description = clean(description: unescapeStructure(description).joined(separator: "\n"))
        node.evidence = parseEvidence(evidence)
    }

    private static func property(_ line: String) -> (String, String)? {
        guard line.hasPrefix("- ") else { return nil }
        let rest = line.dropFirst(2)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let key = rest[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard ["tags", "color", "icon", "number", "shape", "width", "height", "layout", "position"].contains(key) else { return nil }
        return (key, rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    private static func parseEvidence(_ lines: [String]) -> [Evidence] {
        var items: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                items.append(String(trimmed.dropFirst(2)))
            } else if !items.isEmpty {
                items[items.count - 1] += " " + trimmed
            }
        }
        return items.map { item in
            var label = Label.aiInference
            var rest = Substring(item)
            for candidate in Label.allCases {
                let token = "[" + candidate.rawValue + "]"
                if item.lowercased().hasPrefix(token.lowercased()) {
                    label = candidate
                    rest = rest.dropFirst(token.count)
                    break
                }
            }
            let body = rest.trimmingCharacters(in: .whitespaces)
            guard let dash = body.range(of: " — ", options: .backwards) else {
                return Evidence(label: label, text: body, source: "")
            }
            let source = body[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            return Evidence(label: label, text: String(body[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces),
                            source: cleanSource(source))
        }
    }

    private static func cleanSource(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        if s.hasPrefix("`"), s.hasSuffix("`"), s.count >= 2 { s = String(s.dropFirst().dropLast()) }
        return s
    }

    /// `\[` `\]` in an outline title back to brackets.
    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\[", with: "[").replacingOccurrences(of: "\\]", with: "]")
    }

    /// Removes the escape the writer put before a line that would look like structure.
    private static func unescapeStructure(_ lines: [String]) -> [String] {
        var inFence: String?
        return lines.map { line in
            if let marker = fenceMarker(line) {
                if inFence == nil { inFence = marker } else if inFence == marker { inFence = nil }
            }
            guard inFence == nil, line.hasPrefix("\\#"), looksStructural(String(line.dropFirst())) else { return line }
            return String(line.dropFirst())
        }
    }

    /// Lines of a description the parser would take for structure: `## `, `### … {#id}` and `#### Evidence`.
    private static func looksStructural(_ line: String) -> Bool {
        if line.hasPrefix("## ") || nodeHeading(line) != nil { return true }
        return line.trimmingCharacters(in: .whitespaces).lowercased() == "#### evidence" && !line.hasPrefix(" ")
    }
}

// MARK: - Writing

extension ResearchMap {
    /// The canonical Markdown file (DEC-006). Parsing it gives back an equal map.
    func markdown() -> String {
        var front = self.front
        front.set("type", "research-map")
        front.set("id", id)
        front.set("title", title)
        front.set("question", Self.firstLine(question))
        front.set("created", created)
        front.set("status", status.rawValue)
        front.set("incomplete", status == .incomplete && !incompleteReason.isEmpty ? incompleteReason : nil)
        for (key, values) in [("targets", targets), ("attachments", attachments), ("web_queries", webQueries)] {
            if values.isEmpty { front[key] = nil } else { front.set(key, list: values) }
        }

        var body: [String] = []
        body.append("# " + (title.isEmpty ? "Research" : title))
        body.append("")
        body.append("## Question")
        body.append("")
        body.append(question)
        body.append("")
        body.append("## Map")
        body.append("")
        var depths: [String: Int] = [:]
        for node in nodes {
            let depth = node.parent.isEmpty ? 0 : (depths[node.parent] ?? 0) + 1
            depths[node.id] = depth
            body.append(String(repeating: "  ", count: depth) + "- " + Self.outline(node))
        }
        if !links.isEmpty {
            body.append("")
            body.append("## Connections")
            body.append("")
            for link in links {
                if let a = node(link.from), let b = node(link.to) {
                    body.append("- \(Self.outline(a)) ↔ \(Self.outline(b))")
                }
            }
        }
        body.append("")
        body.append("## Nodes")
        for node in nodes {
            body.append("")
            body.append("### \(node.title) {#\(node.id)}")
            var props: [String] = []
            if !node.tags.isEmpty { props.append("- tags: " + node.tags.joined(separator: ", ")) }
            if !node.color.isEmpty { props.append("- color: " + node.color) }
            if !node.icon.isEmpty { props.append("- icon: " + node.icon) }
            if let number = node.number { props.append("- number: \(number)") }
            if !node.shape.isEmpty { props.append("- shape: " + node.shape) }
            if let width = node.width { props.append("- width: \(width)") }
            if let height = node.height { props.append("- height: \(height)") }
            if !node.layout.isEmpty { props.append("- layout: " + node.layout) }
            if let x = node.x, let y = node.y { props.append("- position: \(x), \(y)") }
            if !props.isEmpty {
                body.append("")
                body.append(contentsOf: props)
            }
            if !node.description.isEmpty {
                body.append("")
                body.append(contentsOf: Self.escapeStructure(node.description.components(separatedBy: "\n")))
            }
            if !node.evidence.isEmpty {
                body.append("")
                body.append("#### Evidence")
                body.append("")
                body.append(contentsOf: node.evidence.map(Self.evidenceLine))
            }
        }
        for extra in extraSections {
            body.append("")
            body.append(extra)
        }
        return front.join(body: body.joined(separator: "\n"))
    }

    private static func outline(_ node: Node) -> String {
        let title = node.title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "[\(title)](#\(node.id))"
    }

    /// Escapes the lines of a description that would read as structure when the file is parsed.
    private static func escapeStructure(_ lines: [String]) -> [String] {
        var inFence: String?
        return lines.map { line in
            if let marker = fenceMarker(line) {
                if inFence == nil { inFence = marker } else if inFence == marker { inFence = nil }
            }
            if inFence == nil, looksStructural(line) || (line.hasPrefix("\\#") && looksStructural(String(line.dropFirst()))) {
                return "\\" + line
            }
            return line
        }
    }

    private static func evidenceLine(_ evidence: Evidence) -> String {
        var text = evidence.text.replacingOccurrences(of: "\n", with: " ")
        guard !evidence.source.isEmpty else {
            text = text.replacingOccurrences(of: " — ", with: " – ")
            return "- [\(evidence.label.rawValue)] \(text)"
        }
        let source = evidence.source.lowercased().hasPrefix("http") ? "<\(evidence.source)>" : "`\(evidence.source)`"
        // The source is what follows the LAST " — ", so a dash inside the text of a sourced finding is safe.
        return "- [\(evidence.label.rawValue)] \(text) — \(source)"
    }
}

// MARK: - Snapshot for the map view

extension ResearchMap {
    /// What the page needs to draw the map (DEC-009). `job` is the running AI job, if any.
    struct JobInfo: Equatable {
        var kind: String
        var label: String
        var step: String
        var startedAt: Double
    }

    func snapshot(job: JobInfo? = nil, created createdID: String = "", notice: String = "") -> [String: Any] {
        [
            "ok": true,
            "problem": "",
            "id": id,
            "title": title,
            "question": question,
            "status": status.rawValue,
            "incomplete": incompleteReason,
            "job": job.map { ["kind": $0.kind, "label": $0.label, "step": $0.step, "startedAt": $0.startedAt] as [String: Any] } ?? NSNull(),
            "webQueries": webQueries,
            "nodes": nodes.map { node -> [String: Any] in
                [
                    "id": node.id, "parent": node.parent, "title": node.title, "tags": node.tags, "color": node.color,
                    "icon": node.icon, "number": node.number.map { $0 as Any } ?? NSNull(),
                    "shape": node.shape, "width": node.width.map { $0 as Any } ?? NSNull(),
                    "height": node.height.map { $0 as Any } ?? NSNull(),
                    "description": node.description, "layout": node.layout,
                    "x": node.x.map { $0 as Any } ?? NSNull(), "y": node.y.map { $0 as Any } ?? NSNull(),
                    "evidence": node.evidence.map { ["label": $0.label.rawValue, "text": $0.text, "source": $0.source] },
                ]
            },
            "links": links.map { ["from": $0.from, "to": $0.to] },
            "layouts": Self.layouts.map { ["id": $0.id, "name": $0.name] },
            "icons": Self.iconIDs,
            "shapes": Self.shapes.map { ["id": $0.id, "name": $0.name] },
            "sizeLimits": ["width": [Self.widthRange.lowerBound, Self.widthRange.upperBound],
                           "height": [Self.heightRange.lowerBound, Self.heightRange.upperBound]],
            "created": createdID,
            "notice": notice,
        ]
    }

    /// The snapshot of a file that is not a map: the page shows the reason and the source.
    static func unreadableSnapshot(problem: String) -> [String: Any] {
        ["ok": false, "problem": problem, "id": "", "title": "", "question": "", "status": "complete", "incomplete": "",
         "job": NSNull(), "webQueries": [String](), "nodes": [Any](), "links": [Any](), "layouts": [Any](),
         "created": "", "notice": ""]
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        // U+2028/2029 end a line in JavaScript source.
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
