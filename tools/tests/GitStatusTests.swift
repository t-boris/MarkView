import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

let z = "\0"
let sample = ["# branch.oid abc", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1",
              "1 .M N... 100644 100644 100644 aaa bbb Sources/a b.swift",
              "1 M. N... 100644 100644 100644 aaa bbb README.md",
              "1 MM N... 100644 100644 100644 aaa bbb both.txt",
              "1 A. N... 000000 100644 100644 000 bbb new.txt",
              "1 .D N... 100644 100644 000000 aaa bbb gone.txt",
              "2 R. N... 100644 100644 100644 aaa bbb R100 moved.txt", "old name.txt",
              "u UU N... 100644 100644 100644 100644 a b c clash.txt",
              "? scratch.txt", "? dir/inner.txt", "! build/", "! .DS_Store"].joined(separator: z) + z

let status = GitRepoStatus.parse(sample)
check(status.head == "main" && status.upstream == "origin/main", "branch and upstream are read")
check(status.ahead == 2 && status.behind == 1, "ahead and behind are read")
check(status.entries.count == 11, "every path becomes one entry: \(status.entries.count)")
check(status.entries.first { $0.path == "Sources/a b.swift" }?.worktree == .modified, "a path with a space keeps all of it")
check(status.entries.first { $0.path == "README.md" }?.index == .modified, "an index change is staged")
let both = status.entries.first { $0.path == "both.txt" }
check(both?.index == .modified && both?.worktree == .modified, "a staged file changed again has both states")
check(status.count(.staged) == 4 && status.count(.changes) == 3, "staged \(status.count(.staged)), changes \(status.count(.changes))")
check(status.entries.first { $0.path == "moved.txt" }.map { $0.index == .renamed && $0.origin == "old name.txt" } == true, "a rename reads its origin")
check(status.count(.conflicts) == 1 && status.entries(in: .conflicts).first?.path == "clash.txt", "an unmerged path is a conflict")
check(status.count(.untracked) == 2, "untracked files are listed one by one")
check(status.entries(in: .ignored).map(\.path) == ["build/", ".DS_Store"] && status.entries(in: .ignored)[0].isDirectory, "ignored paths and directories")
check(!status.changedPaths.contains("build/") && status.changedPaths.contains("scratch.txt"), "changedPaths leaves ignored out")
check(GitRepoStatus.parse("").entries.isEmpty && GitRepoStatus.parse("garbage\0") == GitRepoStatus.empty, "empty and malformed output is harmless")
check(GitRepoStatus.cleanTracked(lsFiles: "a.txt\0b.txt\0c.txt\0", changed: ["b.txt"]) == ["a.txt", "c.txt"], "clean tracked files exclude changed ones")

// The file tree's view of the same output.
check(status.decoration(of: "README.md", isDirectory: false) == GitDecoration(state: .modified, staged: true, inside: 0, detail: "Modified, staged"), "decoration: staged file")
check(status.decoration(of: "both.txt", isDirectory: false).state == .modified && !status.decoration(of: "both.txt", isDirectory: false).staged, "decoration: staged and changed again counts as not fully staged")
check(status.decoration(of: "scratch.txt", isDirectory: false).state == .untracked, "decoration: untracked file")
check(status.decoration(of: "clash.txt", isDirectory: false).state == .conflicted, "decoration: conflict")
check(status.decoration(of: "build", isDirectory: true).state == .ignored && status.decoration(of: "build/out/x.o", isDirectory: false).state == .ignored, "decoration: ignored directory and what is inside")
check(status.decoration(of: ".DS_Store", isDirectory: false).state == .ignored, "decoration: ignored file")
check(status.decoration(of: "dir", isDirectory: true).state == .untracked && status.decoration(of: "dir", isDirectory: true).inside == 1, "decoration: folder with an untracked file")
check(status.decoration(of: "Sources", isDirectory: true) == GitDecoration(state: .modified, staged: false, inside: 1, detail: "1 changed file inside"), "decoration: folder with a modified file")
check(status.decoration(of: "untouched.txt", isDirectory: false) == GitDecoration() && status.decoration(of: "docs", isDirectory: true) == GitDecoration(), "decoration: nothing for a clean path")

// Against real git.
func git(_ args: [String], in dir: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + args
    process.currentDirectoryURL = dir
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}
let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-status-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: repo) }
func write(_ name: String, _ text: String) throws {
    let url = repo.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}
_ = git(["init", "-q", "-b", "main"], in: repo)
_ = git(["config", "user.email", "t@example.com"], in: repo)
_ = git(["config", "user.name", "T"], in: repo)
try write(".gitignore", "build/\n*.log\n")
try write("keep.txt", "one\n"); try write("edit.txt", "one\n"); try write("drop.txt", "one\n")
_ = git(["add", "-A"], in: repo)
_ = git(["commit", "-q", "-m", "init"], in: repo)
try write("edit.txt", "two\n")
try write("added.txt", "x\n"); _ = git(["add", "added.txt"], in: repo)
try FileManager.default.removeItem(at: repo.appendingPathComponent("drop.txt"))
try write("build/out.bin", "x"); try write("run.log", "x"); try write("new dir/inner.txt", "x")

let live = GitRepoStatus.parse(git(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignored=matching"], in: repo))
check(live.head == "main", "real repo: branch")
check(live.entries.first { $0.path == "edit.txt" }?.worktree == .modified, "real repo: modified")
check(live.entries.first { $0.path == "added.txt" }?.index == .added, "real repo: added")
check(live.entries.first { $0.path == "drop.txt" }?.worktree == .deleted, "real repo: deleted")
check(live.entries(in: .untracked).map(\.path) == ["new dir/inner.txt"], "real repo: untracked directory is expanded")
check(Set(live.entries(in: .ignored).map(\.path)) == ["build/", "run.log"], "real repo: ignored: \(live.entries(in: .ignored).map(\.path))")
let tracked = GitRepoStatus.cleanTracked(lsFiles: git(["ls-files", "-z"], in: repo), changed: live.changedPaths)
check(Set(tracked) == [".gitignore", "keep.txt"], "real repo: clean tracked files: \(tracked)")

print(failures == 0 ? "All git status checks passed." : "\(failures) git status check(s) failed.")
exit(failures == 0 ? 0 : 1)
