import Foundation

struct GitHubRepo: Sendable { var slug: String; var isUpstream = false }
struct GitHubClient: Sendable {
    let root: URL
    let repo: GitHubRepo
    struct Output: Sendable { let status: Int32; let stdout: String; let stderr: String }
    static func ghPath() -> String? { "/usr/bin/gh" }
    static func detectRepos(root: URL) async -> [GitHubRepo] { [GitHubRepo(slug: "example/project")] }
    static func execute(_ args: [String], in root: URL, git: Bool = false, timeout: TimeInterval = 60) async -> Output {
        if git {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args; process.currentDirectoryURL = root
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return Output(status: -1, stdout: "", stderr: "") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Output(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self), stderr: "")
        }
        if args.prefix(2) == ["api", "graphql"] {
            let query = args.last ?? ""
            var prs: [String: Any] = [:]
            for (number, body) in [(1, ""), (2, "Fix for BUG-123, related to #77"), (3, "Feature: other")] where query.contains("p\(number):") {
                prs["p\(number)"] = ["body": body]
            }
            let data = try! JSONSerialization.data(withJSONObject: ["data": ["repository": prs]])
            return Output(status: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
        }
        if args.prefix(2) == ["pr", "view"] {
            return Output(status: 0, stdout: #"{"headRefOid":"pr-head","mergeCommit":{"oid":"squash-commit"}}"#, stderr: "")
        }
        if args.prefix(2) == ["run", "list"] {
            let failed = FileManager.default.fileExists(atPath: root.appendingPathComponent(".failed-check").path)
            let result = failed ? #"[{"status":"completed","conclusion":"failure"}]"# : #"[{"status":"completed","conclusion":"success"}]"#
            return Output(status: 0, stdout: result, stderr: "")
        }
        if args.prefix(2) == ["release", "list"] {
            return Output(status: 0, stdout: #"[{"tagName":"v1","publishedAt":"2099-01-01T00:00:00Z","isDraft":false}]"#, stderr: "")
        }
        if args.first == "api", args.count > 1, args[1].contains("/compare/") {
            let containsSquash = args[1].contains("/compare/squash-commit...v1")
            return Output(status: 0, stdout: containsSquash ? "ahead" : "diverged", stderr: "")
        }
        return Output(status: 1, stdout: "", stderr: "")
    }
}

@main struct CollectorChecks {
    static func git(_ args: [String], in root: URL) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args; process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try! process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0, "git \(args)")
    }
    static func main() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("issue-collector-\(UUID().uuidString)")
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        git(["init", "-b", "main"], in: root)
        git(["config", "user.name", "Test"], in: root)
        git(["config", "user.email", "test@example.org"], in: root)
        func commit(_ name: String, _ body: String) {
            try! name.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            git(["add", name], in: root)
            git(["commit", "-m", body], in: root)
        }
        commit("base.swift", "initial")
        git(["checkout", "-b", "feature-ci"], in: root)
        commit("ci.swift", "Improve pipeline\n\nFeature: ci")
        git(["checkout", "main"], in: root)
        git(["merge", "--no-ff", "feature-ci", "-m", "Merge pull request #1 from example/feature-ci\n\nImprove pipeline"], in: root)
        git(["checkout", "-b", "bug"], in: root)
        commit("bug.swift", "Fix bug without a trailer")
        git(["checkout", "main"], in: root)
        git(["merge", "--no-ff", "bug", "-m", "Merge pull request #2 from example/bug\n\nFix bug"], in: root)
        try! fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try! "notes".write(to: root.appendingPathComponent("docs/note.md"), atomically: true, encoding: .utf8)
        git(["add", "docs/note.md"], in: root)
        git(["commit", "-m", "Documentation\n\nFeature: docs-only"], in: root)
        git(["checkout", "-b", "unrelated"], in: root)
        commit("other.swift", "Another change")
        git(["checkout", "main"], in: root)
        git(["merge", "--no-ff", "unrelated", "-m", "Merge pull request #3 from example/unrelated\n\nAnother change"], in: root)
        func subject(_ kind: IssueKind, _ key: String) -> IssueEvidenceCollector.Subject {
            .init(kind: kind, issue: key, exclusiveNumbers: [], sharedNumbers: [], since: nil)
        }
        let feature = await IssueEvidenceCollector.collect(subject(.feature, "ci"), root: root, githubEnabled: true)
        check("a branch commit trailer identifies its merged PR", feature.isComplete && feature.lines.contains { $0.contains("PR #1") })
        let bug = await IssueEvidenceCollector.collect(subject(.bug, "BUG-123"), root: root, githubEnabled: true)
        check("a PR body identifies its merged bug fix", bug.isComplete && bug.lines.contains { $0.contains("PR #2") })
        let missing = await IssueEvidenceCollector.collect(subject(.feature, "absent"), root: root, githubEnabled: true)
        check("unrelated merges do not complete another issue", !missing.isComplete)
        let docsOnly = await IssueEvidenceCollector.collect(subject(.feature, "docs-only"), root: root, githubEnabled: true)
        check("a documentation commit is not attributed to the next unrelated merge", !docsOnly.isComplete)
        try! fm.createDirectory(at: root.appendingPathComponent(".dde"), withIntermediateDirectories: true)
        try! #"{"items":[{"id":"deploy","mode":"require"}]}"#.write(to: root.appendingPathComponent(".dde/definition-of-done.json"), atomically: true, encoding: .utf8)
        let released = await IssueEvidenceCollector.collect(subject(.feature, "ci"), root: root, githubEnabled: true)
        check("a release contains the landed squash commit, not the PR branch head", released.isComplete && released.lines.contains { $0.contains("v1") })
        try! fm.removeItem(at: root.appendingPathComponent(".dde"))
        let unavailable = await IssueEvidenceCollector.collect(subject(.feature, "ci"), root: root, githubEnabled: false)
        check("a merged commit does not bypass unavailable checks", !unavailable.isComplete)
        let shared = IssueEvidenceCollector.Subject(kind: .feature, issue: "not-ci", exclusiveNumbers: [], sharedNumbers: [77], since: nil)
        let ambiguous = await IssueEvidenceCollector.collect(shared, root: root, githubEnabled: true)
        check("a shared GitHub issue reference does not confirm a particular feature", !ambiguous.isComplete)
        let reopened = IssueEvidenceCollector.Subject(kind: .feature, issue: "ci", exclusiveNumbers: [], sharedNumbers: [], since: Date().addingTimeInterval(60))
        let old = await IssueEvidenceCollector.collect(reopened, root: root, githubEnabled: true)
        check("work merged before a reopening cannot complete it", !old.isComplete)
        try! "".write(to: root.appendingPathComponent(".failed-check"), atomically: true, encoding: .utf8)
        let failed = await IssueEvidenceCollector.collect(subject(.feature, "ci"), root: root, githubEnabled: true)
        check("a merged associated PR with failed checks cannot complete", !failed.isComplete)
        finish("issue collector")
    }
}
