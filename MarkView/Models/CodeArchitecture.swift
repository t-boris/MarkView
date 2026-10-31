import Foundation

/// A code-only projection of the X-Ray. Layer guesses are a visible draft until
/// the existing source-based component analysis supplies semantic assignments.
enum CodeArchitecture {
    static let layers: [(id: String, name: String)] = [
        ("presentation", "Presentation"), ("application", "Application"),
        ("domain", "Domain logic"), ("data", "Data & storage"),
        ("integration", "Integrations"), ("infrastructure", "Infrastructure"),
        ("platform", "Shared platform"), ("tooling", "Build & tooling"),
        ("tests", "Tests"), ("other", "Unclassified code")
    ]

    static func layer(_ raw: String) -> String {
        let aliases = ["ui": "presentation", "app": "application", "api": "application",
                       "logic": "domain", "database": "data", "infra": "infrastructure",
                       "config": "tooling", "build": "tooling", "scripts": "tooling",
                       "shared": "platform", "test": "tests"]
        let value = aliases[raw] ?? raw
        return layers.contains { $0.id == value } ? value : "other"
    }

    static func guessedLayer(_ path: String, language: String?) -> String {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        if parts.contains(where: { ["tests", "test", "__tests__", "spec", "fixtures"].contains($0) }) { return "tests" }
        if language == "sql" || parts.contains(where: { ["db", "database", "data", "storage", "persistence", "repositories", "migrations"].contains($0) }) { return "data" }
        if parts.contains(where: { ["views", "ui", "pages", "screens", "components", "frontend", "presentation"].contains($0) }) { return "presentation" }
        if parts.contains(where: { ["domain", "entities", "logic", "business"].contains($0) }) { return "domain" }
        if parts.contains(where: { ["services", "application", "controllers", "api", "handlers", "app"].contains($0) }) { return "application" }
        if parts.contains(where: { ["integrations", "clients", "adapters", "bridge"].contains($0) }) { return "integration" }
        if parts.contains(where: { ["infra", "infrastructure", "deploy", "docker"].contains($0) }) { return "infrastructure" }
        if parts.contains(where: { ["tools", "scripts", "build", "config", ".github"].contains($0) }) { return "tooling" }
        return "other"
    }

    static func view(_ snapshot: ArchitectureSnapshot) -> ArchView {
        guard let modules = snapshot.view("modules") else { return ArchView(id: "code", nodes: [], edges: []) }
        let logical = snapshot.codeModel.map { modelView($0, modules: modules, contents: snapshot.view("logical") ?? modules) } ?? snapshot.view("logical")
        let semantic = snapshot.codeModel != nil || (!snapshot.logicalDraft && !snapshot.components.isEmpty)
        let source = logical ?? modules
        let files = source.nodes.filter { $0.kind == "file" && $0.language != "markdown" && $0.language != nil }
        let index = Dictionary(source.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var nodes = [ArchNode(id: "code:", kind: "root", name: snapshot.codeModel?.name ?? snapshot.systemName ?? "Code architecture",
                              summary: semantic ? (snapshot.codeModel?.purpose ?? snapshot.systemPurpose) : "Draft layers inferred from paths. Analyze reads source declarations and dependencies to name and group components.")]
        var added = Set(["code:"])
        var usedLayers = Set<String>()
        var fileIDs: [String: String] = [:]
        func add(_ node: ArchNode) { if added.insert(node.id).inserted { nodes.append(node) } }
        for file in files {
            guard let path = file.path else { continue }
            var ancestors: [ArchNode] = []
            var cursor = file.parent
            var seen = Set<String>()
            while let id = cursor, seen.insert(id).inserted, let node = index[id], node.kind != "root" {
                if node.kind == "component" || node.kind == "dir" || node.kind == "package" { ancestors.append(node) }
                cursor = node.parent
            }
            let role = semantic ? ancestors.first(where: { $0.kind == "component" })?.role : nil
            let layerID = role.map(layer) ?? guessedLayer(path, language: file.language)
            usedLayers.insert(layerID)
            var parent = "code:layer:" + layerID
            // Clone by layer as a subsystem may contain files from several layers.
            for ancestor in ancestors.reversed() {
                var copy = ancestor
                copy.id = "code:" + layerID + ":" + ancestor.id
                copy.parent = parent
                copy.role = layerID
                add(copy)
                parent = copy.id
            }
            var copy = file
            copy.id = "code:f:" + path
            copy.parent = parent
            copy.role = layerID
            add(copy)
            fileIDs[file.id] = copy.id
        }
        let componentParents = Set(nodes.filter { $0.kind == "component" }.compactMap(\.parent))
        for item in layers where usedLayers.contains(item.id) {
            let names = nodes.filter { $0.kind == "component" && $0.role == item.id && !componentParents.contains($0.id) }.map(\.name)
            let summary = semantic && !names.isEmpty ? Set(names).sorted().prefix(3).joined(separator: " · ") : "Draft grouping from source paths"
            add(ArchNode(id: "code:layer:" + item.id, parent: "code:", kind: "layer", name: item.name,
                         summary: summary, role: item.id))
        }
        // File contents already carry source positions; retain every available level.
        for node in source.nodes where ["collection", "group", "entity"].contains(node.kind) {
            var cursor = node.parent
            var seen = Set<String>()
            while let id = cursor, seen.insert(id).inserted, let ancestor = index[id] {
                if let file = fileIDs[id] {
                    var copy = node
                    copy.id = "code:s:" + node.id
                    copy.parent = node.parent == id ? file : node.parent.map { "code:s:" + $0 }
                    add(copy)
                    break
                }
                cursor = ancestor.parent
            }
        }
        for external in modules.nodes where external.kind == "externalGroup" || external.kind == "external" {
            var copy = external
            copy.id = "code:" + external.id
            copy.parent = external.kind == "externalGroup" ? "code:" : external.parent.map { "code:" + $0 }
            add(copy)
            fileIDs[external.id] = copy.id
        }
        let nodeIDs = Set(nodes.map(\.id))
        var edges = source.edges.compactMap { edge -> ArchEdge? in
            guard let from = fileIDs[edge.source], let to = fileIDs[edge.target], nodeIDs.contains(from), nodeIDs.contains(to) else { return nil }
            var copy = edge; copy.source = from; copy.target = to; return copy
        }
        if let model = snapshot.codeModel {
            for dependency in model.dependencies ?? [] {
                func representative(_ id: String) -> ArchNode? {
                    let ownLayer = model.components.first { $0.id == id }?.layer
                    let candidates = nodes.filter { $0.kind == "component" && $0.component == id }
                    return candidates.first { $0.role == ownLayer } ?? candidates.first
                }
                if let from = representative(dependency.source), let to = representative(dependency.target), from.id != to.id {
                    edges.append(ArchEdge(source: from.id, target: to.id, kind: "calls", label: dependency.label, evidence: dependency.evidence))
                }
            }
        }
        let parents = Dictionary(nodes.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        var totals: [String: (files: Int, loc: Int)] = [:]
        for node in nodes where node.kind == "file" {
            var cursor = node.parent
            var seen = Set<String>()
            while let id = cursor, seen.insert(id).inserted {
                totals[id, default: (0, 0)].files += 1
                totals[id, default: (0, 0)].loc += node.loc
                cursor = parents[id] ?? nil
            }
        }
        for i in nodes.indices where nodes[i].kind != "file" && totals[nodes[i].id] != nil {
            nodes[i].files = totals[nodes[i].id]!.files; nodes[i].loc = totals[nodes[i].id]!.loc
        }
        return ArchView(id: "code", nodes: nodes, edges: edges)
    }

    private static func modelView(_ model: CodeArchitectureModel, modules: ArchView, contents: ArchView) -> ArchView {
        var nodes = [ArchNode(id: "cm:", kind: "root", name: model.name)]
        let componentIDs = Set(model.components.map(\.id))
        for component in model.components {
            nodes.append(ArchNode(id: "cm:c:" + component.id,
                                  parent: componentIDs.contains(component.parent) ? "cm:c:" + component.parent : "cm:",
                                  kind: "component", name: component.name, summary: component.purpose, role: component.layer, component: component.id))
        }
        let parentOf = Dictionary(model.components.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        func depth(_ id: String) -> Int {
            var cursor = id, seen = Set<String>()
            while !cursor.isEmpty, seen.insert(cursor).inserted { cursor = parentOf[cursor] ?? "" }
            return seen.count
        }
        for file in modules.nodes where file.kind == "file" && file.language != "markdown" {
            guard let path = file.path else { continue }
            // The most specific path wins; an equal path belongs to the deepest component.
            var matches: [(id: String, specificity: Int, depth: Int)] = []
            for component in model.components {
                for owned in component.paths where path == owned || path.hasPrefix(owned + "/") {
                    matches.append((component.id, owned.count, depth(component.id)))
                }
            }
            matches.sort { a, b in
                if a.specificity != b.specificity { return a.specificity > b.specificity }
                if a.depth != b.depth { return a.depth > b.depth }
                return a.id < b.id
            }
            var copy = file
            copy.parent = matches.first.map { "cm:c:" + $0.0 } ?? "cm:"
            nodes.append(copy)
        }
        // Outlines refer to the old file ids; remap parents while retaining all symbol levels.
        let fileByPath = Dictionary(nodes.filter { $0.kind == "file" }.compactMap { n in n.path.map { ($0, n.id) } }, uniquingKeysWith: { a, _ in a })
        let contentIndex = Dictionary(contents.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for node in contents.nodes where ["collection", "group", "entity"].contains(node.kind) {
            guard let path = node.path, let fileID = fileByPath[path] else { continue }
            var copy = node
            if let parent = node.parent, contentIndex[parent]?.kind == "file" { copy.parent = fileID }
            nodes.append(copy)
        }
        return ArchView(id: "code-model", nodes: nodes, edges: modules.edges)
    }

    static func prompt(root: URL, files: [String]) -> String {
        """
        Infer the architecture of the source code at \(root.path). Read the actual source files
        and follow imports, calls, entry points, storage and integration boundaries. Support
        whatever languages are present; do not infer responsibilities from folder names alone.
        Build a nested component tree of responsibilities, not a mirror of the directory tree.
        Top-level components are subsystems; nest their components and smaller responsibilities
        as deeply as the code justifies. Each component has a layer, a short purpose, and paths
        of source files/folders it owns. A child may narrow its parent's paths. A file belongs
        to the deepest, most specific matching component. Cover all first-party source code;
        use fewer broad components for tests/tooling/vendor code. Do not invent databases,
        services or layers absent from the code. Use 1-120 components, usually 8-35.
        Every component MUST cite a real code file and line as evidence, within its own paths.
        parent is an existing component id or empty for a top-level component. No cycles.
        Also return dependencies: component source id, target id, short action label, and a real
        path:line evidence for the dependency. Include actual calls, data access, imports and
        cross-language integration boundaries discovered in source. Do not invent links to make
        the graph connected. Name the action (e.g. "stores order"), not just "uses".
        Names should come from the source; summaries explain responsibilities and uncertainty.
        Source file inventory (up to 3000 paths; discover additional files with your tools):
        \(files.prefix(3000).joined(separator: "\n"))
    """
    }

    static var schema: [String: Any] {
        func string() -> [String: Any] { ["type": "string"] }
        return ["type": "object", "additionalProperties": false,
                "required": ["name", "purpose", "components", "dependencies"], "properties": [
                    "name": string(), "purpose": string(),
                    "dependencies": ["type": "array", "items": ["type": "object", "additionalProperties": false,
                        "required": ["source", "target", "label", "evidence"], "properties": [
                            "source": string(), "target": string(), "label": string(), "evidence": string()
                        ]]],
                    "components": ["type": "array", "items": ["type": "object", "additionalProperties": false,
                        "required": ["id", "name", "purpose", "parent", "layer", "paths", "evidence"], "properties": [
                            "id": string(), "name": string(), "purpose": string(), "parent": string(),
                            "layer": ["type": "string", "enum": layers.map(\.id)],
                            "paths": ["type": "array", "items": string()], "evidence": string()
                        ]]]
                ]]
    }

    static func validateModel(_ model: CodeArchitectureModel, modules: ArchView, root: URL) throws {
        let files = Set(modules.nodes.filter { $0.kind == "file" && $0.language != "markdown" }.compactMap(\.path))
        var problems: [String] = []
        let ids = Set(model.components.map(\.id))
        if model.components.isEmpty || model.components.count > 120 { problems.append("Use 1-120 source-grounded components") }
        if ids.count != model.components.count { problems.append("Component ids must be unique") }
        let parents = Dictionary(model.components.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        if model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("Name the system") }
        for component in model.components {
            if component.id.isEmpty || component.name.isEmpty || !layers.contains(where: { $0.id == component.layer }) { problems.append("Each component needs an id, name and supported layer") }
            if !component.parent.isEmpty && !ids.contains(component.parent) { problems.append("Unknown parent for \(component.id)") }
            var cursor = component.id, seen = Set<String>()
            while !cursor.isEmpty {
                if !seen.insert(cursor).inserted { problems.append("Component hierarchy contains a cycle at \(cursor)"); break }
                cursor = parents[cursor] ?? ""
            }
            if component.paths.isEmpty { problems.append("\(component.name) must own source paths") }
            for path in component.paths {
                if path.isEmpty || path.hasPrefix("/") || path.split(separator: "/").contains("..") || !files.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) {
                    problems.append("\(component.name) has an unknown source path: \(path)")
                }
            }
            if let location = sourceLocation(component.evidence, root: root), files.contains(location.path),
               component.paths.contains(where: { location.path == $0 || location.path.hasPrefix($0 + "/") }) {
                // The citation must be in the code this component actually owns.
            } else { problems.append("\(component.name) needs valid source evidence in one of its paths") }
        }
        for dependency in model.dependencies ?? [] {
            if !ids.contains(dependency.source) || !ids.contains(dependency.target) || dependency.label.isEmpty {
                problems.append("Dependencies need existing component ids and an action label")
            }
            if let location = sourceLocation(dependency.evidence, root: root), files.contains(location.path) {
                // The cited boundary must be in a scanned source file.
            } else { problems.append("Dependency needs valid source evidence") }
        }
        if !problems.isEmpty { throw DiagramAI.Failure.unusable(problems) }
    }

    /// Reject outside paths (including symlinks), directories and invalid line numbers.
    static func sourceLocation(_ value: String, root: URL) -> (path: String, line: Int)? {
        guard let colon = value.lastIndex(of: ":"), let line = Int(value[value.index(after: colon)...]), line > 0 else { return nil }
        let path = String(value[..<colon])
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= ArchitectureScanner.maxParseBytes,
              let text = try? String(contentsOf: url, encoding: .utf8), line <= text.components(separatedBy: .newlines).count else { return nil }
        return (path, line)
    }

    static func validateSequence(_ spec: DiagramSpec, root: URL) throws {
        var problems: [String] = []
        for node in spec.nodes where !["actor", "external"].contains(node.kind) {
            if sourceLocation(node.source ?? "", root: root) == nil { problems.append("\(node.label) needs a project source file and valid line") }
        }
        for (i, edge) in spec.edges.enumerated() {
            if !edge.label.hasPrefix("\(i + 1). ") { problems.append("Sequence steps must be numbered in time order, starting at 1") }
            if sourceLocation(edge.evidence ?? "", root: root) == nil { problems.append("Step \(i + 1) needs a project source file and valid line") }
        }
        if !problems.isEmpty { throw DiagramAI.Failure.unusable(problems) }
    }

    static func sequenceMermaid(_ spec: DiagramSpec) -> String {
        // Never interpolate model text as Mermaid syntax or HTML.
        func label(_ text: String) -> String {
            text.map { ch -> String in
                if ch.isLetter || ch.isNumber || " .,_()-/".contains(ch) { return String(ch) }
                return " "
            }.joined()
        }
        var lines = ["sequenceDiagram"]
        for (i, node) in spec.nodes.enumerated() { lines.append("participant p\(i) as \(label(node.label))") }
        let ids = Dictionary(spec.nodes.enumerated().map { ($0.element.id, "p\($0.offset)") }, uniquingKeysWith: { a, _ in a })
        for edge in spec.edges {
            if let from = ids[edge.from], let to = ids[edge.to] { lines.append("\(from)->>\(to): \(label(edge.label))") }
        }
        return lines.joined(separator: "\n")
    }
}

struct CodeSequence: Codable {
    var scope: String
    var signature: String
    var diagram: DiagramSpec
    var createdAt: Date
}

/// Separate from the document-oriented Logical view: inferred by reading code,
/// with nested responsibilities and a source citation for each component.
struct CodeArchitectureModel: Codable {
    struct Component: Codable {
        var id: String
        var name: String
        var purpose: String
        var parent: String
        var layer: String
        var paths: [String]
        var evidence: String
    }
    var name: String
    var purpose: String
    var components: [Component]
    struct Dependency: Codable {
        var source: String
        var target: String
        var label: String
        var evidence: String
    }
    var signature: String? = nil
    var analyzedAt: Date? = nil
    var dependencies: [Dependency]? = nil
}
