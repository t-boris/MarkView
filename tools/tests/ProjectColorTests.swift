// Checks project colors (MarkView/Models/ProjectColor.swift) against feature-2 DEC-008, DEC-009
// and DEC-010: palette, project key, stable automatic color, persistence and overrides.
import Foundation

var failures = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got == want { print("ok  \(name)") } else { failures += 1; print("FAIL \(name): got \(got.debugDescription) want \(want.debugDescription)") }
}

check("eight colors", String(ProjectColor.palette.count), "8")
check("distinct ids", String(Set(ProjectColor.palette.map(\.id)).count), "8")
check("distinct values", String(Set(ProjectColor.palette.map { "\($0.red) \($0.green) \($0.blue)" }).count), "8")

// Project key: standardized path after resolving symbolic links.
let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("pc-\(UUID().uuidString)", isDirectory: true)
let real = base.appendingPathComponent("a/my-project", isDirectory: true)
let other = base.appendingPathComponent("b/my-project", isDirectory: true)
let link = base.appendingPathComponent("link", isDirectory: true)
try! FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
defer { try? FileManager.default.removeItem(at: base) }
let key = ProjectColor.projectKey(for: real)
check("key is the path", key, real.path)
check("symlink resolves to the same project", ProjectColor.projectKey(for: link), key)
check("dot segments are standardized", ProjectColor.projectKey(for: real.appendingPathComponent("../my-project")), key)
check("trailing slash is the same project", ProjectColor.projectKey(for: URL(fileURLWithPath: real.path + "/")), key)
check("same name, other path is another project", String(ProjectColor.projectKey(for: other) == key), "false")

// Automatic color: a fixed value per key, identical in every process (not Swift's seeded hash).
check("stable across calls", ProjectColor.automatic(forKey: key).id, ProjectColor.automatic(forKey: key).id)
check("known key, known color", ProjectColor.automatic(forKey: "/Users/boris/github.com/MarkView").id,
      ProjectColor.palette[Int(fnv("/Users/boris/github.com/MarkView") % 8)].id)
// Pinned: changing the hash or the palette order would recolor every saved-less project.
check("pinned color 1", ProjectColor.automatic(forKey: "/Users/boris/github.com/MarkView").id, "red")
check("pinned color 2", ProjectColor.automatic(forKey: "/tmp/a").id, "pink")
let spread = Set((0..<200).map { ProjectColor.automatic(forKey: "/projects/p\($0)").id })
check("uses the whole palette", String(spread.count), "8")
func fnv(_ s: String) -> UInt64 {
    var h: UInt64 = 14695981039346656037
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return h
}

// Store: persistence, overrides, and one shared value for every window.
let suite = "ProjectColorTests-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
MainActor.assumeIsolated {
    let store = ProjectColorStore(defaults: defaults)
    check("reading does not persist", String(store.assignments.isEmpty), "true")
    check("unassigned shows the automatic color", store.color(forKey: key).id, ProjectColor.automatic(forKey: key).id)
    store.assignIfNeeded(key: key)
    check("first show persists the automatic color", store.assignments[key] ?? "", ProjectColor.automatic(forKey: key).id)
    let chosen = ProjectColor.palette.first { $0 != store.color(forKey: key) }!
    store.set(chosen, forKey: key)
    store.assignIfNeeded(key: key)
    check("a choice survives assignIfNeeded", store.color(forKey: key).id, chosen.id)
    let relaunched = ProjectColorStore(defaults: defaults)
    check("choice survives a relaunch", relaunched.color(forKey: key).id, chosen.id)
    defaults.set([key: "no-such-color"], forKey: ProjectColorStore.defaultsKey)
    let damaged = ProjectColorStore(defaults: defaults)
    check("unknown stored id falls back to automatic", damaged.color(forKey: key).id, ProjectColor.automatic(forKey: key).id)
    damaged.assignIfNeeded(key: key)
    check("unknown stored id is repaired", damaged.assignments[key] ?? "", ProjectColor.automatic(forKey: key).id)
}

print(failures == 0 ? "All project color checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
