import Foundation

// The schema of the feature and bug files (AR-39), through the shipping FeatureStore over real files in a temporary project.

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ok   \(label)")
    } else {
        failed += 1
        print("  FAIL \(label)")
    }
}

let fm = FileManager.default

func write(_ text: String, to url: URL) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>" }

func schemaLines(_ text: String) -> Int { text.components(separatedBy: "\nschema:").count - 1 }

@MainActor
func run() async {
    let project = fm.temporaryDirectory.appendingPathComponent("feature-schema-" + UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: project) }
    let features = project.appendingPathComponent("docs/features")
    let bugs = project.appendingPathComponent("docs/bugs")

    // Files written before the schema existed.
    let legacyOverview = "---\ntitle: Legacy\nstatus: draft\n---\n\n# Legacy\n\nOld overview.\n"
    let legacyRequirement = "---\ntype: requirement\nid: REQ-001\nfeature: legacy\ntitle: Old requirement\nstatus: draft\n---\n\nThe old text.\n"
    let legacyBug = "---\ntype: bug\nid: BUG-001\ntitle: Old bug\nstatus: open\nseverity: high\n---\n\n# Old bug\n\nIt crashes.\n"
    // Files of a newer schema.
    let futureOverview = "---\ntitle: Future\nstatus: draft\nschema: 99\nnew_field: kept\n---\n\n# Future\n\nNewer overview.\n"
    let futureRequirement = "---\ntype: requirement\nid: REQ-002\nfeature: legacy\ntitle: New requirement\nstatus: draft\nschema: 99\n---\n\nNewer text.\n"
    let futureBug = "---\ntype: bug\nid: BUG-002\ntitle: New bug\nstatus: open\nschema: 99\nextra: kept\n---\n\n# New bug\n\nText.\n"
    let futurePlan = "---\ntype: plan\nfeature: future\ntitle: Plan\nschema: 99\n---\n\n# Plan\n"

    let legacyOverviewURL = features.appendingPathComponent("legacy/overview.md")
    let legacyRequirementURL = features.appendingPathComponent("legacy/requirements/REQ-001.md")
    let futureRequirementURL = features.appendingPathComponent("legacy/requirements/REQ-002.md")
    let futureOverviewURL = features.appendingPathComponent("future/overview.md")
    let futurePlanURL = features.appendingPathComponent("future/implementation/plan.md")
    let legacyBugURL = bugs.appendingPathComponent("BUG-001-old-bug.md")
    let futureBugURL = bugs.appendingPathComponent("BUG-002-new-bug.md")
    write(legacyOverview, to: legacyOverviewURL)
    write(legacyRequirement, to: legacyRequirementURL)
    write(futureRequirement, to: futureRequirementURL)
    write(futureOverview, to: futureOverviewURL)
    write(futurePlan, to: futurePlanURL)
    write(legacyBug, to: legacyBugURL)
    write(futureBug, to: futureBugURL)

    let store = FeatureStore()
    store.setup(root: project)
    store.reloadSync()
    defer { store.reset() }

    print("-- reading")
    check(store.feature("legacy")?.status == "draft" && store.feature("future")?.status == "draft", "both features load, whatever their schema")
    check(store.feature("legacy")?.object("REQ-001") != nil && store.bugs.count == 2, "objects and bugs load, whatever their schema")
    check(read(legacyOverviewURL) == legacyOverview && read(legacyRequirementURL) == legacyRequirement && read(legacyBugURL) == legacyBug,
          "loading leaves a file written before the schema as it is")

    print("-- a file written before the schema")
    store.updateFeature("legacy") { front, _ in front.set("status", "review") }
    check(read(legacyOverviewURL) == "---\ntitle: Legacy\nstatus: review\nschema: 1\n---\n\n# Legacy\n\nOld overview.\n",
          "an overview gets the schema on its next write and nothing else changes")
    store.updateFeature("legacy") { front, _ in front.set("status", "ready") }
    check(schemaLines(read(legacyOverviewURL)) == 1, "a second write keeps one schema line")
    store.update("REQ-001", in: "legacy") { front, _ in front.set("status", "approved") }
    check(read(legacyRequirementURL).contains("status: approved\n") && read(legacyRequirementURL).contains("\nschema: 1\n")
          && schemaLines(read(legacyRequirementURL)) == 1 && read(legacyRequirementURL).hasSuffix("---\n\nThe old text.\n"),
          "an object gets the schema on its next write")
    let wrote = store.updateBug(legacyBugURL) { front, _ in front.set("status", "fixing") }
    check(wrote && read(legacyBugURL) == "---\ntype: bug\nid: BUG-001\ntitle: Old bug\nstatus: fixing\nseverity: high\nschema: 1\n---\n\n# Old bug\n\nIt crashes.\n",
          "a bug report gets the schema on its next write and nothing else changes")
    check(store.lastError == nil, "none of these writes is an error")

    print("-- new files")
    let created = store.create(.requirement, in: "legacy", title: "Brand new", body: "Text.\n", provenance: "test")
    check(created.map { read($0.url).contains("\nschema: 1\n") } == true, "a new object carries the schema")
    let slug = store.createFeature(title: "Fresh idea", idea: "An idea.")
    check(slug.map { read(features.appendingPathComponent($0 + "/overview.md")).contains("\nschema: 1\n") } == true, "a new feature carries the schema")

    print("-- a file of a newer schema")
    store.lastError = nil
    store.updateFeature("future") { front, _ in front.set("status", "review") }
    check(read(futureOverviewURL) == futureOverview, "an overview of a newer schema is not rewritten")
    check(store.lastError?.contains("newer MarkView") == true, "and the store says why: \(store.lastError ?? "no error")")
    store.lastError = nil
    store.update("REQ-002", in: "legacy") { front, _ in front.set("status", "approved") }
    check(read(futureRequirementURL) == futureRequirement && store.lastError?.contains("newer MarkView") == true, "an object of a newer schema is not rewritten")
    store.lastError = nil
    let refused = store.updateBug(futureBugURL) { front, _ in front.set("status", "fixing") }
    check(!refused && read(futureBugURL) == futureBug && store.lastError?.contains("newer MarkView") == true, "a bug report of a newer schema is not rewritten")
    store.lastError = nil
    store.updateMany(["REQ-001", "REQ-002"], in: "legacy") { _, front, _ in front.set("owner", "Boris") }
    check(read(futureRequirementURL) == futureRequirement && read(legacyRequirementURL).contains("owner: Boris\n"),
          "many at once: the object of the older schema is written, the newer one is left")
    check(store.lastError?.contains("newer MarkView") == true, "and the one that was left is reported")
    store.lastError = nil
    store.savePlan("future", title: "Plan", issues: [], epic: nil)
    check(read(futurePlanURL) == futurePlan && store.lastError?.contains("newer MarkView") == true, "a plan of a newer schema is not rewritten")
}

@main
struct Checks {
    static func main() async {
        await run()
        print(failed == 0 ? "All \(passed) checks passed" : "\(failed) FAILED, \(passed) passed")
        exit(failed == 0 ? 0 : 1)
    }
}
