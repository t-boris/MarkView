import Foundation

struct ArchNode {
    var id: String
    var parent: String?
    var kind: String
    var name: String
    var path: String?
    var files: Int
    var summary: String?
    var line: Int?
    var anchor: String?

    init(id: String, parent: String?, kind: String, name: String, path: String? = nil,
         files: Int = 0, summary: String? = nil) {
        self.id = id
        self.parent = parent
        self.kind = kind
        self.name = name
        self.path = path
        self.files = files
        self.summary = summary
    }
}

extension String {
    var editorLines: [Substring] {
        replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
    }
}

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "ok" : "FAIL")  \(name)")
    if !condition { failures += 1 }
}

let local = XRayContent.codeOutline(text: "func first() {}\nfunc second() {}\nfunc third() {}", language: "swift", signature: "fixture")!
let localNodes = XRayContent.nodes(for: local, path: "Small.swift", fileId: "file")
check("short code keeps all declarations directly under file",
      localNodes.count == 3 && localNodes.allSatisfy { $0.kind == "entity" && $0.parent == "file" })

func item(_ name: String, _ line: Int) -> XRayContent.Item {
    .init(name: name, line: line, summary: nil, anchor: nil)
}
func group(_ name: String, _ items: [XRayContent.Item]) -> XRayContent.Group {
    .init(name: name, items: items)
}
func part(_ name: String, _ groups: [XRayContent.Group]) -> XRayContent.Collection {
    .init(name: name, summary: nil, groups: groups)
}
func outline(_ collections: [XRayContent.Collection]) -> XRayContent.Outline {
    .init(signature: "fixture", collections: collections, source: "ai", language: "English")
}

let sparse = outline([
    part("State", [group("Helpers", [item("parse", 10), item("clean", 20)])]),
    part("Actions", [group("Functions", [item("start", 30), item("stop", 40)])]),
])
let sparseNodes = XRayContent.nodes(for: sparse, path: "Module.swift", fileId: "file")
check("sparse AI parts and groups add no levels",
      sparseNodes.count == 4 && sparseNodes.allSatisfy { $0.kind == "entity" && $0.parent == "file" })
check("sparse items keep source lines", sparseNodes.compactMap(\.line) == [10, 20, 30, 40])
check("flattened items keep stable IDs", sparseNodes.map(\.id) == [
    "l:e:Module.swift#0.0.0", "l:e:Module.swift#0.0.1",
    "l:e:Module.swift#1.0.0", "l:e:Module.swift#1.0.1",
])

let dense = outline([
    part("Parsing", [group("Helpers", [item("a", 1), item("b", 2), item("c", 3), item("d", 4)]),
                     group("Functions", [item("e", 5), item("f", 6)])]),
    part("Output", [group("Rendering", [item("g", 7), item("h", 8), item("i", 9), item("j", 10)])]),
])
let denseNodes = XRayContent.nodes(for: dense, path: "Module.swift", fileId: "file")
let byName = Dictionary(uniqueKeysWithValues: denseNodes.map { ($0.name, $0) })
check("useful parts stay visible", byName["Parsing"]?.parent == "file" && byName["Output"]?.parent == "file")
check("four-item group stays visible", byName["Helpers"]?.parent == byName["Parsing"]?.id)
check("two-item group is flattened", byName["Functions"] == nil && byName["e"]?.parent == byName["Parsing"]?.id)
check("single group adds no redundant level", byName["Rendering"] == nil && byName["g"]?.parent == byName["Output"]?.id)
check("every item is reachable", denseNodes.filter { $0.kind == "entity" }.count == 10 &&
      denseNodes.filter { $0.kind == "entity" }.allSatisfy { $0.line != nil })

let lone = outline([part("Declarations", [group("Types", [item("A", 1), item("B", 2), item("C", 3), item("D", 4)])])])
let loneNodes = XRayContent.nodes(for: lone, path: "Types.swift", fileId: "file")
check("one part with one group adds no redundant levels",
      loneNodes.count == 4 && loneNodes.allSatisfy { $0.kind == "entity" && $0.parent == "file" })

let untyped = outline([part("Mixed", [group("", [item("a", 1), item("b", 2), item("c", 3), item("d", 4)]),
                                      group("Public API", [item("e", 5), item("f", 6), item("g", 7), item("h", 8)])])])
let untypedNodes = XRayContent.nodes(for: untyped, path: "Mixed.swift", fileId: "file")
check("unnamed group does not become Other", !untypedNodes.contains { $0.kind == "group" && $0.name == "Other" })
check("useful named group remains under file", untypedNodes.first { $0.name == "Public API" }?.parent == "file")

if failures > 0 { exit(1) }
