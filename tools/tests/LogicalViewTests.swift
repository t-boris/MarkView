import Foundation

// The Logical view (LogicalView): clusters become components and subsystems, files and folders are assigned to them, and the view that
// shows it is built from a Modules view like the scanner makes (folders, files, file edges). Real values in, the shipping code
// run, nothing mocked. No window, no assistant.

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)")
    }
}

func file(_ path: String, loc: Int = 10) -> ArchNode {
    ArchNode(id: "m:" + path, parent: "m:" + (path as NSString).deletingLastPathComponent, kind: "file",
             name: (path as NSString).lastPathComponent, path: path, language: path.hasSuffix(".swift") ? "swift" : nil, loc: loc, files: 1)
}
func folder(_ path: String) -> ArchNode {
    ArchNode(id: "m:" + path, parent: path.isEmpty ? nil : "m:" + (path as NSString).deletingLastPathComponent,
             kind: path.isEmpty ? "root" : "dir", name: path.isEmpty ? "Project" : (path as NSString).lastPathComponent, path: path)
}

// A small project as the scanner records it: two source folders, a test folder, a folder of 35 files, a file edge.
var modulesNodes = [folder(""), folder("Sources"), folder("Sources/App"), folder("Sources/Data"), folder("Tests"), folder("Sources/Big"), folder("Sources/Big/sub")]
modulesNodes += ["Sources/App/main.swift", "Sources/App/special.swift", "Sources/Data/store.swift", "Tests/StoreTests.swift", "stray.txt"].map { file($0) }
modulesNodes += (1...30).map { file("Sources/Big/f\($0).swift", loc: 2) } + (31...35).map { file("Sources/Big/sub/f\($0).swift", loc: 2) }
var base = ArchitectureSnapshot(
    views: [ArchView(id: "modules", nodes: modulesNodes,
                     edges: [ArchEdge(source: "m:Sources/App/main.swift", target: "m:Sources/Data/store.swift", kind: "imports")])],
    coverage: [:], deploymentHints: [], scannedAt: Date(timeIntervalSince1970: 0))
let clusters = [
    XRayCluster.Cluster(id: "app", units: ["Sources/App"], group: "g1"),
    XRayCluster.Cluster(id: "data", units: ["Sources/Data"], group: "g1"),
    XRayCluster.Cluster(id: "tests", units: ["Tests"], group: "g2"),
    XRayCluster.Cluster(id: "big", units: ["Sources/Big"], group: "g2"),
]

print("-- clusters before the assistant has named them")
let draft = LogicalView.applyClusters(clusters, names: [:], grouping: nil, to: base)
check(draft.logicalDraft && draft.components.count == 6, "a draft has a subsystem per coarse group and a component per cluster (\(draft.components.map(\.id)))")
check(draft.components.first { $0.id == "s-g1" }?.name == "Sources" && draft.components.first { $0.id == "s-g2" }?.name == "Sources",
      "a draft subsystem is named by the top folder most of its clusters are in, a tie goes to the name that sorts first")
check(draft.components.first { $0.id == "c-app" }?.name == "App" && draft.components.first { $0.id == "c-app" }?.parent == "s-g1",
      "a draft component is named by its folder and sits under its group")
check(draft.assignments["Sources/App"]?.component == "c-app" && draft.assignments["Tests"]?.component == "c-tests", "each folder is assigned to its cluster's component")

print("\n-- clusters named and grouped by the assistant")
let names: [String: [String: Any]] = [
    "app": ["name": "Application", "purpose": "Entry points", "layer": "presentation", "importance": "critical"],
    "data": ["name": "Storage", "purpose": "Persistence", "layer": "data", "importance": "high"],
    "tests": ["name": "Tests", "purpose": "Checks", "layer": "tests", "mergeInto": "data", "importance": "bogus"],
    "big": ["name": "Generated", "purpose": "Many files", "layer": "tooling", "mergeInto": "big", "importance": "low"],
]
let grouping: [String: Any] = [
    "system": ["name": "Demo", "purpose": "A demo system."],
    "subsystems": [
        ["id": "core", "name": "Core", "purpose": "The product", "layer": "application", "components": ["app", "data", "missing"], "importance": "critical"],
        ["id": "", "name": "Rest", "purpose": "Everything else", "layer": "tooling", "components": ["big"], "importance": "nonsense"],
    ],
]
let named = LogicalView.applyClusters(clusters, names: names, grouping: grouping, to: base)
check(!named.logicalDraft && named.systemName == "Demo" && named.systemPurpose == "A demo system.", "named clusters end the draft and carry the system's name")
check(named.components.map(\.id) == ["s-core", "s-1", "c-app", "c-data", "c-big"],
      "subsystems come first (an empty id becomes its position), a merged cluster has no component of its own (\(named.components.map(\.id)))")
check(named.components.first { $0.id == "c-app" }?.parent == "s-core" && named.components.first { $0.id == "c-big" }?.parent == "s-1"
      && named.components.first { $0.id == "c-data" }?.layer == "data", "components sit under the subsystem that lists them")
check(named.assignments["Tests"]?.component == "c-data", "a cluster merged into another is assigned to it")
check(named.assignments["Sources/Big"]?.component == "c-big", "a cluster that names itself in mergeInto keeps its own component")
check(named.ratings["importance"]?["c:c-app"]?.level == "critical" && named.ratings["importance"]?["c:s-core"]?.level == "critical"
      && named.ratings["importance"]?["c:c-tests"] == nil && named.ratings["importance"]?["c:s-1"] == nil,
      "importance of components and subsystems comes with the names, a level that is not one of the filter's is dropped")

print("\n-- the Logical view")
var snapshot = named
snapshot.overrides["Sources/App/special.swift"] = "c-data"
let applied = LogicalView.apply(snapshot)
let logical = applied.view("logical")
check(applied.views.first?.id == "logical" && applied.views.count == 2, "the Logical view is put first, next to the Modules view")
let byId = Dictionary(uniqueKeysWithValues: (logical?.nodes ?? []).map { ($0.id, $0) })
check(byId["l:"]?.name == "Demo" && byId["l:c:c-app"]?.parent == "l:c:s-core" && byId["l:c:s-core"]?.parent == "l:", "the system is the root, components nest in their subsystems")
check(byId["l:f:Sources/App/main.swift"]?.parent == "l:c:c-app", "a file takes the component of the folder it is in")
check(byId["l:f:Sources/App/special.swift"]?.parent == "l:c:c-data", "the person's override of a file wins over its folder")
check(byId["l:f:Tests/StoreTests.swift"]?.parent == "l:c:c-data", "a merged cluster's files belong to the component it was merged into")
check(byId["l:f:stray.txt"]?.parent == "l:c:_other" && byId["l:c:_other"]?.name == "Unassigned", "a file no folder claims goes to Unassigned")
check((logical?.nodes.filter { $0.kind == "file" && $0.parent?.hasPrefix("l:d:") == true }.count ?? 0) == 35
      && byId["l:d:c-big|Sources/Big"]?.parent == "l:c:c-big" && byId["l:d:c-big|Sources/Big/sub"]?.name == "Big/sub"
      && byId["l:f:Sources/Big/sub/f31.swift"]?.parent == "l:d:c-big|Sources/Big/sub",
      "a component with more than \(LogicalView.folderGroupingThreshold) files in several folders lists its folders, with the files below them")
check(byId["l:f:Sources/App/main.swift"]?.parent == "l:c:c-app" && byId["l:d:c-app|Sources/App"] == nil, "a small component keeps its files directly")
check(byId["l:c:c-big"]?.files == 35 && byId["l:c:c-big"]?.loc == 70 && byId["l:d:c-big|Sources/Big/sub"]?.files == 5 && byId["l:c:c-app"]?.files == 1 && byId["l:c:c-data"]?.files == 3 && byId["l:"]?.files == 40,
      "sizes add up from files to folders, components and the root (\(byId["l:c:c-big"]?.files ?? -1) \(byId["l:c:c-big"]?.loc ?? -1))")
check(logical?.edges.first?.source == "l:f:Sources/App/main.swift" && logical?.edges.first?.target == "l:f:Sources/Data/store.swift",
      "file edges point at the Logical view's file boxes")
let moduleNodes = Dictionary(uniqueKeysWithValues: (applied.view("modules")?.nodes ?? []).map { ($0.id, $0) })
check(moduleNodes["m:Sources/App/main.swift"]?.component == "c-app" && moduleNodes["m:Sources/App/special.swift"]?.component == "c-data"
      && moduleNodes["m:Tests/StoreTests.swift"]?.tags?.contains("tests") == true,
      "the Modules view's nodes learn their component, and tags from their path")
let empty = LogicalView.apply(base)
check(empty.view("logical") == nil && empty.views.count == 1, "with no components there is no Logical view")
check(LogicalView.apply(LogicalView.apply(snapshot)).views.filter { $0.id == "logical" }.count == 1, "building it again replaces it")

print("\n-- what the assistant is told about a cluster")
func unit(_ path: String, cyrillic: Int = 0, latin: Int = 0) -> XRayDigest.Folder {
    var folder = XRayDigest.Folder(path: path, nodeId: "m:" + path, files: 3, loc: 120, package: "app — The app", readme: nil,
                                   declarations: ["Main", "Router"], cyrillic: cyrillic, latin: latin)
    folder.readme = "Entry points of the demo."
    return folder
}
let plan = XRayDigest.Plan(units: [unit("Sources/App", latin: 900), unit("Sources/Data", cyrillic: 800, latin: 100), unit("Tests", cyrillic: 5, latin: 5000)],
                           overview: "Overview", children: [:])
check(LogicalView.nameLanguage(clusters[0], plan: plan) == "English" && LogicalView.nameLanguage(clusters[1], plan: plan) == "Russian",
      "a cluster's name follows the majority language of its documents, measured, not guessed")
check(LogicalView.projectNameLanguage(plan) == "English", "the subsystems follow the language of all the documents (\(LogicalView.projectNameLanguage(plan)))")
let line = LogicalView.clusterLine(clusters[0], plan: plan)
check(line == "- app (group g1; name in English): 1 folders, 3 files — Sources/App/ | packages: app — The app | defines: Main, Router | readme: Entry points of the demo.",
      "a cluster is listed by id and group with its size, folders, packages, declared names and readme (\(line))")

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
