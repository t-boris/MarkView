// Checks project colors (MarkView/Models/ProjectColor.swift) against feature-2 DEC-008, DEC-009,
// DEC-010 and DEC-014: palette, project key, name-based automatic color, chosen colors.
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

// Automatic color (DEC-014): a fixed value per folder name, ignoring case, identical in every
// process (not Swift's seeded hash).
check("stable across calls", ProjectColor.automatic(forKey: key).id, ProjectColor.automatic(forKey: key).id)
check("same name, other path, same color", ProjectColor.automatic(forKey: ProjectColor.projectKey(for: other)).id,
      ProjectColor.automatic(forKey: key).id)
check("worktree clone of the same name", ProjectColor.automatic(forKey: "/private/tmp/broker-fabric").id,
      ProjectColor.automatic(forKey: "/Users/boris/github.com/broker-fabric").id)
check("case is ignored", ProjectColor.automatic(forKey: "/a/MarkView").id, ProjectColor.automatic(forKey: "/b/markview").id)
check("known name, known color", ProjectColor.automatic(forKey: "/Users/boris/github.com/MarkView").id,
      ProjectColor.palette[Int(fnv("markview") % 8)].id)
// Pinned: changing the hash or the palette order would recolor every project without a choice.
check("pinned color 1", ProjectColor.automatic(forKey: "/Users/boris/github.com/MarkView").id, "orange")
check("pinned color 2", ProjectColor.automatic(forKey: "/Users/boris/github.com/broker-fabric").id, "yellow")
let spread = Set((0..<200).map { ProjectColor.automatic(forKey: "/projects/p\($0)").id })
check("uses the whole palette", String(spread.count), "8")
func fnv(_ s: String) -> UInt64 {
    var h: UInt64 = 14695981039346656037
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return h
}

// Store: only chosen colors persist; one shared value for every window.
let suite = "ProjectColorTests-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
MainActor.assumeIsolated {
    // Colors saved before DEC-014 (automatic and chosen alike) are dropped once.
    defaults.set([key: "teal"], forKey: ProjectColorStore.defaultsKey)
    let migrated = ProjectColorStore(defaults: defaults)
    check("old saved colors are dropped", String(migrated.assignments.isEmpty), "true")
    check("migration runs once", String(defaults.bool(forKey: ProjectColorStore.byNameMigrationKey)), "true")

    let store = ProjectColorStore(defaults: defaults)
    check("reading does not persist", String(store.assignments.isEmpty), "true")
    check("no choice shows the automatic color", store.color(forKey: key).id, ProjectColor.automatic(forKey: key).id)
    let chosen = ProjectColor.palette.first { $0 != store.color(forKey: key) }!
    store.set(chosen, forKey: key)
    check("a choice is saved", store.assignments[key] ?? "", chosen.id)
    check("a choice stays with its folder", store.color(forKey: ProjectColor.projectKey(for: other)).id,
          ProjectColor.automatic(forKey: key).id)
    let relaunched = ProjectColorStore(defaults: defaults)
    check("choice survives a relaunch", relaunched.color(forKey: key).id, chosen.id)
    relaunched.set(ProjectColor.automatic(forKey: key), forKey: key)
    check("choosing the automatic color clears the choice", String(relaunched.assignments[key] == nil), "true")
    defaults.set([key: "no-such-color"], forKey: ProjectColorStore.defaultsKey)
    let damaged = ProjectColorStore(defaults: defaults)
    check("unknown stored id falls back to automatic", damaged.color(forKey: key).id, ProjectColor.automatic(forKey: key).id)
}

print(failures == 0 ? "All project color checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
