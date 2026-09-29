// Checks ProjectOperation.primary (MarkView/Models/ProjectOperation.swift): which operations get a
// button up front — running first, then recently started, then by kind and label, at most five.
import Foundation

var failures = 0
func check(_ name: String, _ got: [String], _ want: [String]) {
    if got == want { print("ok  \(name)") } else { failures += 1; print("FAIL \(name): got \(got) want \(want)") }
}

func operation(_ id: String, _ kind: String, _ label: String? = nil) -> ProjectOperation {
    let json = """
    {"id":"\(id)","label":"\(label ?? id)","kind":"\(kind)","nodes":[],"command":"echo \(id)","cwd":".",
     "origin":"discovered","provenance":[],"prerequisites":[],"remoteTrigger":false}
    """
    return try! JSONDecoder().decode(ProjectOperation.self, from: Data(json.utf8))
}

let many = [operation("docs", "other"), operation("clean", "clean"), operation("build-web", "build"),
            operation("build-app", "build"), operation("install", "install"), operation("restart", "restart"),
            operation("deploy-prod", "deploy"), operation("deploy-stage", "deploy"), operation("migrate", "other")]
let ids = { (list: [ProjectOperation]) in list.map(\.id) }

check("five at most, by kind then label",
      ids(ProjectOperation.primary(many, running: [], lastStarted: [:])),
      ["deploy-prod", "deploy-stage", "install", "build-app", "build-web"])
check("running comes first",
      ids(ProjectOperation.primary(many, running: ["migrate"], lastStarted: [:])).prefix(1).map { $0 }, ["migrate"])
let now = Date()
check("recently started before unused",
      ids(ProjectOperation.primary(many, running: [], lastStarted: ["clean": now, "docs": now.addingTimeInterval(-60)])),
      ["clean", "docs", "deploy-prod", "deploy-stage", "install"])
check("fewer than five: all of them", ids(ProjectOperation.primary(Array(many.prefix(2)), running: [], lastStarted: [:])),
      ["clean", "docs"])
check("unknown kind ranks last", ids(ProjectOperation.primary([operation("x", "weird"), operation("y", "other")],
                                                              running: [], lastStarted: [:])), ["y", "x"])

print(failures == 0 ? "All primary operation checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
