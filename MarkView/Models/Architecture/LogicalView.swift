import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The Logical view of the X-Ray: the components and subsystems the project's folders were clustered into, how files and folders
/// are assigned to them (the analysis's choice, then the person's overrides), and the view that shows it. Reads and writes the
/// snapshot only; the assistant calls that name the clusters stay with the store that runs them.
enum LogicalView {
    /// Above this many files, a component in the Logical view lists its folders instead.
    static let folderGroupingThreshold = 30

    /// Components and folder assignments from the clusters: named (or provisional from
    /// their folders), merged where the AI said so, under the AI's subsystems (or the
    /// clustering's own groups until those arrive).
    static func applyClusters(_ clusters: [XRayCluster.Cluster], names: [String: [String: Any]],
                                          grouping: [String: Any]?, to base: ArchitectureSnapshot) -> ArchitectureSnapshot {
        var next = base
        let ids = Set(clusters.map(\.id))
        // Merges, followed to their end (a → b → c) and never into itself.
        func target(_ id: String) -> String {
            var current = id, seen = Set<String>()
            while seen.insert(current).inserted, let into = names[current]?["mergeInto"] as? String, ids.contains(into) { current = into }
            return current
        }
        func folderName(_ path: String) -> String { path.isEmpty ? "Project root" : (path as NSString).lastPathComponent }
        func commonPrefix(_ paths: [String]) -> String {
            guard var prefix = paths.first?.split(separator: "/").map(String.init) else { return "" }
            for path in paths.dropFirst() {
                let parts = path.split(separator: "/").map(String.init)
                prefix = Array(zip(prefix, parts).prefix { $0 == $1 }.map(\.0))
            }
            return prefix.joined(separator: "/")
        }

        var components: [LogicalComponent] = []
        var parentOf: [String: String] = [:]
        if let subsystems = grouping?["subsystems"] as? [[String: Any]], !subsystems.isEmpty {
            for (index, raw) in subsystems.enumerated() {
                let id = "s-" + ((raw["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(index))
                components.append(LogicalComponent(id: id, name: raw["name"] as? String ?? id, purpose: raw["purpose"] as? String ?? "",
                                                   parent: "", layer: raw["layer"] as? String ?? "application"))
                for member in raw["components"] as? [String] ?? [] where ids.contains(member) && parentOf[member] == nil {
                    parentOf[member] = id
                }
            }
            if let system = grouping?["system"] as? [String: Any] {
                next.systemName = system["name"] as? String
                next.systemPurpose = system["purpose"] as? String
            }
        } else {
            // Provisional subsystems: the clustering's coarse groups, named by their main top folder.
            for group in Set(clusters.map(\.group)).sorted() {
                let tops = clusters.filter { $0.group == group }.flatMap(\.units).map { String($0.split(separator: "/").first ?? "") }
                let main = Dictionary(grouping: tops, by: { $0 }).max { $0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key > $1.key) }?.key ?? ""
                components.append(LogicalComponent(id: "s-" + group, name: main.isEmpty ? "Project root" : main, purpose: "",
                                                   parent: "", layer: "application"))
            }
            for cluster in clusters { parentOf[cluster.id] = "s-" + cluster.group }
        }
        var assignments: [String: LogicalAssignment] = [:]
        for cluster in clusters {
            let owner = target(cluster.id)
            for unit in cluster.units { assignments[unit] = LogicalAssignment(component: "c-" + owner, tags: []) }
            guard owner == cluster.id else { continue }
            let item = names[cluster.id]
            let prefix = commonPrefix(cluster.units)
            components.append(LogicalComponent(
                id: "c-" + cluster.id,
                name: (item?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folderName(prefix.isEmpty ? cluster.units[0] : prefix),
                purpose: item?["purpose"] as? String ?? "",
                parent: parentOf[cluster.id] ?? components.first { $0.parent.isEmpty }?.id ?? "",
                layer: item?["layer"] as? String ?? "application"))
        }
        next.components = components
        next.assignments = assignments
        next.logicalDraft = names.isEmpty
        // Importance of components and subsystems comes with their names: the Importance
        // filter is ready with the structure, without calls of its own.
        let levels = ImportanceRater.importance.levels
        var importance = next.ratings[ImportanceRater.importance.id] ?? [:]
        for cluster in clusters {
            guard let level = names[cluster.id]?["importance"] as? String, levels.contains(level) else { continue }
            importance["c:c-" + cluster.id] = .init(level: level, reason: names[cluster.id]?["purpose"] as? String ?? "")
        }
        for (index, raw) in (grouping?["subsystems"] as? [[String: Any]] ?? []).enumerated() {
            guard let level = raw["importance"] as? String, levels.contains(level) else { continue }
            let id = "s-" + ((raw["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(index))
            importance["c:" + id] = .init(level: level, reason: raw["purpose"] as? String ?? "")
        }
        next.ratings[ImportanceRater.importance.id] = importance
        next.logicalSignature = next.view("modules")?.nodes.first { $0.id == "m:" }?.signature
        return apply(next)
    }

    static func apply(_ snapshot: ArchitectureSnapshot) -> ArchitectureSnapshot {
        var next = snapshot
        next.views.removeAll { $0.id == "logical" }
        guard !snapshot.components.isEmpty, let moduleIndex = next.views.firstIndex(where: { $0.id == "modules" }) else {
            return next
        }
        let componentIds = Set(snapshot.components.map(\.id))

        /// Nearest assignment for `path`, walking up its folders (user overrides first).
        func resolve(_ path: String) -> (component: String?, tags: [String]) {
            var candidate = path
            var component: String?
            var tags: [String]?
            while true {
                if component == nil, let chosen = snapshot.overrides[candidate], componentIds.contains(chosen) { component = chosen }
                if let assignment = snapshot.assignments[candidate] {
                    if component == nil { component = assignment.component }
                    if tags == nil, !assignment.tags.isEmpty { tags = assignment.tags }
                }
                if (component != nil && tags != nil) || candidate.isEmpty { break }
                candidate = (candidate as NSString).deletingLastPathComponent
            }
            return (component, tags ?? [])
        }

        var modules = next.views[moduleIndex]
        for i in modules.nodes.indices where ["dir", "package", "file"].contains(modules.nodes[i].kind) {
            let node = modules.nodes[i]
            let resolved = resolve(node.path ?? "")
            modules.nodes[i].component = resolved.component
            // Tags from the path and file kind (what "Hide tests" and "Code only" use), plus any from the AI.
            var tags = CodePathTags.tags(node.path ?? "", isFile: node.kind == "file", language: node.language)
            for tag in resolved.tags where !tags.contains(tag) { tags.append(tag) }
            modules.nodes[i].tags = tags.isEmpty ? nil : tags
        }
        next.views[moduleIndex] = modules

        var nodes = [ArchNode(id: "l:", parent: nil, kind: "root", name: snapshot.systemName ?? "System",
                              summary: snapshot.systemPurpose)]
        for component in snapshot.components {
            let parent = componentIds.contains(component.parent) && component.parent != component.id ? "l:c:" + component.parent : "l:"
            nodes.append(ArchNode(id: "l:c:" + component.id, parent: parent, kind: "component", name: component.name,
                                  summary: component.purpose, role: component.layer))
        }
        var needsOther = false
        var filesByComponent: [String: [ArchNode]] = [:]
        for file in modules.nodes where file.kind == "file" {
            var copy = file
            copy.id = "l:f:" + (file.path ?? "")
            if let component = file.component { copy.parent = "l:c:" + component } else { copy.parent = "l:c:_other"; needsOther = true }
            filesByComponent[copy.parent ?? "", default: []].append(copy)
        }
        // A component with many files shows their folders first (double-click opens one),
        // instead of hundreds of file boxes at once.
        for (component, files) in filesByComponent.sorted(by: { $0.key < $1.key }) {
            let folders = Dictionary(grouping: files) { ((($0.path ?? "") as NSString).deletingLastPathComponent) }
            guard files.count > folderGroupingThreshold, folders.count > 1 else { nodes += files; continue }
            for (folder, members) in folders.sorted(by: { $0.key < $1.key }) {
                let id = "l:d:" + component.dropFirst(4) + "|" + folder
                let parts = folder.split(separator: "/")
                nodes.append(ArchNode(id: id, parent: component, kind: "dir",
                                      name: folder.isEmpty ? "(project root)" : parts.suffix(2).joined(separator: "/"), path: folder))
                nodes += members.map { var file = $0; file.parent = id; return file }
            }
        }
        if needsOther {
            nodes.append(ArchNode(id: "l:c:_other", parent: "l:", kind: "component", name: "Unassigned",
                                  summary: "Files the analysis did not place in a component."))
        }
        for node in modules.nodes where node.kind == "externalGroup" || node.kind == "external" { nodes.append(node) }

        // Sizes of components (files and lines below them).
        var totals: [String: (Int, Int)] = [:]
        let parentOf = Dictionary(nodes.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        for node in nodes where node.kind == "file" {
            var parent = node.parent
            while let p = parent {
                totals[p, default: (0, 0)].0 += 1
                totals[p, default: (0, 0)].1 += node.loc
                parent = parentOf[p] ?? nil
            }
        }
        for i in nodes.indices where nodes[i].kind == "component" || nodes[i].kind == "root" || nodes[i].kind == "dir" {
            nodes[i].files = totals[nodes[i].id]?.0 ?? 0
            nodes[i].loc = totals[nodes[i].id]?.1 ?? 0
        }

        let edges = modules.edges.map { edge -> ArchEdge in
            var e = edge
            if e.source.hasPrefix("m:") { e.source = "l:f:" + e.source.dropFirst(2) }
            if e.target.hasPrefix("m:") { e.target = "l:f:" + e.target.dropFirst(2) }
            return e
        }
        next.views.insert(ArchView(id: "logical", nodes: nodes, edges: edges), at: 0)
        return next
    }

    /// Language a cluster's name should be in: the majority language of its documents
    /// (measured locally, never guessed by the model); code counts as English.
    static func nameLanguage(_ cluster: XRayCluster.Cluster, plan: XRayDigest.Plan) -> String {
        let units = cluster.units.compactMap { plan.unitByPath[$0] }
        return XRayDigest.language(cyrillic: units.reduce(0) { $0 + $1.cyrillic }, latin: units.reduce(0) { $0 + $1.latin })
    }

    /// The majority language of all the plan's documents: the language subsystem names use.
    static func projectNameLanguage(_ plan: XRayDigest.Plan) -> String {
        XRayDigest.language(cyrillic: plan.units.reduce(0) { $0 + $1.cyrillic }, latin: plan.units.reduce(0) { $0 + $1.latin })
    }

    /// One prompt line per cluster: size, a few folders, packages, declared names.
    static func clusterLine(_ cluster: XRayCluster.Cluster, plan: XRayDigest.Plan) -> String {
        let byPath = plan.unitByPath
        let units = cluster.units.compactMap { byPath[$0] }
        var line = "- \(cluster.id) (group \(cluster.group); name in \(nameLanguage(cluster, plan: plan))): \(units.count) folders, \(units.reduce(0) { $0 + $1.files }) files — "
            + cluster.units.prefix(4).map { $0.isEmpty ? "(root)" : $0 + "/" }.joined(separator: ", ")
        let packages = units.compactMap(\.package).prefix(2)
        if !packages.isEmpty { line += " | packages: " + packages.joined(separator: "; ") }
        let names = units.flatMap(\.declarations).prefix(8)
        if !names.isEmpty { line += " | defines: " + names.joined(separator: ", ") }
        if let readme = units.compactMap(\.readme).first { line += " | readme: " + readme }
        return line
    }
}
