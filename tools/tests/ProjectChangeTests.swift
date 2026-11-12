import Darwin
import Foundation

// Checks the Project Changes scanner (MarkView/Models/ProjectChangeReview.swift, BUG-083): tool caches and agent worktrees
// are not walked, binary and large files are compared by size, date and identity instead of being read, text changes keep
// both texts, and a walk over many files does not hold their bytes until it ends.

// Stand-ins for the linked-folder types ProjectSearch.swift names; the scanner does not use them.
struct LinkedFolder { var name: String; var url: URL }
enum LinkedFolders { static let documentIdPrefix = "linked:" }

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("markview-changes-\(UUID().uuidString)", isDirectory: true)
defer { try? fm.removeItem(at: root) }

func write(_ path: String, _ data: Data) {
    let url = root.appendingPathComponent(path)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
}
func write(_ path: String, _ text: String) { write(path, Data(text.utf8)) }
/// Filesystem dates have a resolution; a later write must look newer.
func waitForNewerDate() { usleep(20_000) }

/// The most memory this process has ever used (its physical footprint high-water mark), in MB.
func peakFootprintMB() -> Double {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return status == 0 ? Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 : -1
}

write("notes.md", "first\n")
write("picture.png", Data(repeating: 7, count: 4_096))
write("large.log", Data(repeating: 65, count: ProjectChangeScanner.maximumHashBytes + 1))
write(".turbo/cache/task.log", "cached output\n")
write(".claude/worktrees/feature/app.swift", "let copy = 1\n")
write(".claude/settings.json", "{}\n")
write(".worktrees/feature/app.swift", "let copy = 1\n")
write("nested/.worktrees/feature/app.swift", "let copy = 1\n")
write("worktrees/notes.md", "first\n")

let scanner = ProjectChangeScanner()
try await scanner.open(root)
check(try await scanner.refresh().isEmpty, "an unchanged project reports no changes")

waitForNewerDate()
write("notes.md", "second\n")
write(".turbo/cache/task.log", "new cached output\n")
write(".turbo/cache/other.log", "more\n")
write(".claude/worktrees/feature/app.swift", "let copy = 2\n")
write(".claude/worktrees/feature/new.swift", "let added = 1\n")
write(".worktrees/feature/app.swift", "let copy = 2\n")
write(".worktrees/feature/new.swift", "let added = 1\n")
write("nested/.worktrees/feature/app.swift", "let copy = 2\n")
write("worktrees/notes.md", "second\n")
var changes = try await scanner.refresh()
let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
check(byPath["notes.md"]?.kind == .modified && byPath["notes.md"]?.before == "first\n" && byPath["notes.md"]?.current == "second\n",
      "a text change keeps both texts")
check(!changes.contains { $0.path.hasPrefix(".turbo/") }, "a build cache is not walked: \(changes.map(\.path))")
check(!changes.contains { $0.path.hasPrefix(".claude/worktrees/") }, "agent worktrees are not walked: \(changes.map(\.path))")
check(!changes.contains { $0.path.split(separator: "/").contains(".worktrees") },
      "root and nested .worktrees copies are not walked: \(changes.map(\.path))")
check(byPath["worktrees/notes.md"]?.kind == .modified, "an ordinary worktrees folder is still tracked")

await scanner.acknowledge()
waitForNewerDate()
write("large.log", Data(repeating: 66, count: ProjectChangeScanner.maximumHashBytes + 2))
write("picture.png", Data(repeating: 8, count: 4_096))
write(".claude/settings.json", "{\"a\":1}\n")
changes = try await scanner.refresh()
let kinds = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
check(kinds["large.log"]?.kind == .modified && kinds["large.log"]?.current == nil,
      "a large file's change is seen without reading it")
check(kinds["picture.png"]?.kind == .modified, "a binary file's change is seen without reading it")
check(kinds[".claude/settings.json"]?.kind == .modified, "other files under .claude are still tracked")

// 200 MB in 50 files below the hashing limit: each is read, and its chunks must not outlive the file.
let bulk = root.appendingPathComponent("bulk", isDirectory: true)
try? fm.createDirectory(at: bulk, withIntermediateDirectories: true)
let chunk = Data(repeating: 1, count: 4 << 20)
for index in 0..<50 { try? chunk.write(to: bulk.appendingPathComponent("part-\(index).bin.data")) }
let before = peakFootprintMB()
let fresh = ProjectChangeScanner()
try await fresh.open(root)
let growth = peakFootprintMB() - before
check(before > 0 && growth < 80, "a walk over 200 MB of files holds at most one file at a time (peak grew \(Int(growth)) MB)")

print(failures == 0 ? "All Project Changes checks passed." : "\(failures) Project Changes check(s) failed.")
exit(failures == 0 ? 0 : 1)
