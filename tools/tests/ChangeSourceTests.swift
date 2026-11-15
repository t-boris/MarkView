import Foundation

// Where the Pull request X-Ray's changes come from (ChangeSource): a real temporary git repository with a base branch, a feature branch
// that is checked out, a committed change, an uncommitted one, a new file git does not track, and a side branch. The GitHub integration is
// off (`gitHub: false`), so `gh` is never started. No window, no assistant.

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

@discardableResult
func git(_ arguments: [String], in directory: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

let fm = FileManager.default
let sandbox = fm.temporaryDirectory.appendingPathComponent("change-source-tests-\(UUID().uuidString)", isDirectory: true)
let repo = sandbox.appendingPathComponent("repo", isDirectory: true)
try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: sandbox) }
func write(_ text: String, _ name: String) { try? text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }

git(["init", "-q", "-b", "main", "."], in: repo)
git(["config", "user.email", "t@t.test"], in: repo)
git(["config", "user.name", "t"], in: repo)
write("one\ntwo\nthree\n", "a.txt")
git(["add", "-A"], in: repo)
git(["commit", "-q", "-m", "base"], in: repo)
let baseSha = git(["rev-parse", "HEAD"], in: repo)
// A side branch off the base with its own file.
git(["checkout", "-q", "-b", "side"], in: repo)
write("side file\n", "s.txt")
git(["add", "-A"], in: repo)
git(["commit", "-q", "-m", "side"], in: repo)
let sideSha = git(["rev-parse", "HEAD"], in: repo)
// The feature branch: a committed change, then an uncommitted one and a new untracked file.
git(["checkout", "-q", "main"], in: repo)
git(["checkout", "-q", "-b", "feature"], in: repo)
write("one\nTWO committed\nthree\n", "a.txt")
git(["add", "-A"], in: repo)
git(["commit", "-q", "-m", "feature"], in: repo)
write("one\nTWO committed\nthree edited\n", "a.txt")
write("brand new\n", "u.txt")
write("binary\u{0}data", "bin.dat")
try? Data(repeating: 0x61, count: 600 * 1024).write(to: repo.appendingPathComponent("big.txt"))

print("=== sources of a change ===")
let sources = ChangeSource.list(root: repo, repo: nil, gitHub: false)
check(sources == [PRSource(id: "local", title: "feature: all changes vs main (commits + uncommitted)")],
      "a git checkout offers its changes against the base branch, named for both sides, and no GitHub entry while the integration is off (\(sources.map(\.title)))")
let plain = sandbox.appendingPathComponent("plain", isDirectory: true)
try? fm.createDirectory(at: plain, withIntermediateDirectories: true)
check(ChangeSource.list(root: plain, repo: nil, gitHub: false).isEmpty, "a folder that is not a git checkout offers nothing")
check(ChangeSource.baseBranch(root: repo) == "main", "the base is the repository's main branch when there is no remote")

print("\n=== the change as a diff ===")
let local = ChangeSource.diff(for: PRSource(id: "local", title: ""), root: repo, repo: nil, gitHub: false) ?? ""
check(local.contains("+TWO committed") && local.contains("+three edited"), "this checkout against the base holds the committed and the uncommitted change")
check(local.contains("+++ b/u.txt") && local.contains("+brand new"), "a new file git does not track yet is added")
check(!local.contains("bin.dat") && !local.contains("big.txt"), "a binary file and a file over 512 KB are left out")
let headers = local.split(separator: "\n").filter { $0.hasPrefix("diff --git ") }.map(String.init)
check(headers == ["diff --git a/a.txt b/a.txt", "diff --git a/u.txt b/u.txt"], "it covers the changed file and the new one, nothing else (\(headers))")
check(ChangeSource.diff(for: PRSource(id: "gh:12", title: ""), root: repo, repo: nil, gitHub: false) == nil,
      "a pull request cannot be read while the GitHub integration is off")
check(ChangeSource.fetch(number: "12", root: repo, repo: nil, gitHub: false) == nil, "nor fetched")

print("\n=== comparisons ===")
check(ChangeSource.comparison("cmp:main")?.reverse == false && ChangeSource.comparison("cmp:main")?.ref == "main", "cmp:<ref> compares this checkout with the ref")
check(ChangeSource.comparison("rev:side")?.reverse == true && ChangeSource.comparison("rev:side")?.ref == "side", "rev:<ref> reads what the ref has that this checkout lacks")
check(ChangeSource.comparison("cmp:") == nil && ChangeSource.comparison("cmp:--output=x") == nil && ChangeSource.comparison("local") == nil,
      "an empty ref, a ref that looks like an option and other sources are no comparison")
let cmp = ChangeSource.diff(for: PRSource(id: "cmp:main", title: ""), root: repo, repo: nil, gitHub: false) ?? ""
check(cmp == local, "comparing with the base branch gives the same change as the checkout's own")
let rev = ChangeSource.diff(for: PRSource(id: "rev:side", title: ""), root: repo, repo: nil, gitHub: false) ?? ""
check(rev.contains("+++ b/s.txt") && rev.contains("+side file") && !rev.contains("a.txt"), "another branch's change is read from that branch, not from the working copy")
check(ChangeSource.diff(for: PRSource(id: "cmp:no-such-ref", title: ""), root: repo, repo: nil, gitHub: false) == nil, "an unknown ref has no diff")

print("\n=== what a load needs ===")
let loadedLocal = ChangeSource.read(PRSource(id: "local", title: ""), root: repo, repo: nil, gitHub: false)
check(loadedLocal.diff == local && loadedLocal.checkout == nil && loadedLocal.base == baseSha, "the local change starts at the merge base with the base branch")
let loadedSide = ChangeSource.read(PRSource(id: "rev:side", title: ""), root: repo, repo: nil, gitHub: false)
check(loadedSide.checkout?.number == "branch-side" && loadedSide.checkout?.head == sideSha && loadedSide.checkout?.mergeBase == baseSha && loadedSide.base == baseSha,
      "another branch is read at its own head, from where it left this one")
let sinceId = HistoricalBaseline.sourceId(for: baseSha) ?? ""
let loadedSince = ChangeSource.read(PRSource(id: sinceId, title: ""), root: repo, repo: nil, gitHub: false)
check(loadedSince.base == baseSha && (loadedSince.diff ?? "").contains("+TWO committed") && (loadedSince.diff ?? "").contains("+brand new"),
      "a chosen commit is the baseline itself and the diff runs to the working copy")

print("\n=== a file as it was ===")
let cache = sandbox.appendingPathComponent("cache", isDirectory: true)
let old = await ChangeSource.materialize(path: "a.txt", at: baseSha, into: cache, root: repo)
check(old?.path == cache.appendingPathComponent("a.txt").path && (try? String(contentsOf: old!, encoding: .utf8)) == "one\ntwo\nthree\n",
      "the version at a commit is written to the cache, not to the project")
check(await ChangeSource.materialize(path: "a.txt", at: baseSha, into: cache, root: repo) == old, "asked again, the cached file is returned")
check(await ChangeSource.materialize(path: "nope.txt", at: baseSha, into: cache, root: repo) == nil, "a file the commit does not have gives nothing")
check(ChangeSource.cacheRoot(root: repo, label: "PR-1").path == ChangeSource.cacheRoot(root: repo, label: "PR-1").path
      && ChangeSource.cacheRoot(root: repo, label: "PR-1") != ChangeSource.cacheRoot(root: plain, label: "PR-1")
      && ChangeSource.cacheRoot(root: repo, label: "PR-1").path.contains("MarkView/pull-requests/"),
      "a project has its own folder in MarkView's cache")

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
