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
            // #4 names an issue, as a squash title can: GitHub answers NOT_FOUND for that field alone and `gh` exits with 1.
            var object: [String: Any] = ["data": ["repository": prs]]
            var status: Int32 = 0
            if query.contains("p4:") {
                var repository = prs
                repository["p4"] = NSNull()
                object = ["data": ["repository": repository], "errors": [["type": "NOT_FOUND", "path": ["repository", "p4"],
                                                                         "message": "Could not resolve to a PullRequest with the number of 4."]]]
                status = 1
            }
            let data = try! JSONSerialization.data(withJSONObject: object)
            return Output(status: status, stdout: String(decoding: data, as: UTF8.self), stderr: status == 0 ? "" : "gh: Could not resolve to a PullRequest with the number of 4.")
        }
        if args.first == "api", args.count > 2, args[1] == "--paginate", args[2].contains("/commits/") {
            // BUG-106: the files of a commit as GitHub lists them; the marker file holds the answer, no marker is an unreachable GitHub.
            let marker = root.appendingPathComponent(".gh-commit-files")
            guard let files = try? String(contentsOf: marker, encoding: .utf8) else { return Output(status: 1, stdout: "", stderr: "gh: no route to host") }
            return Output(status: 0, stdout: files, stderr: "")
        }
        if args.prefix(2) == ["pr", "view"] {
            return Output(status: 0, stdout: #"{"headRefOid":"pr-head","mergeCommit":{"oid":"squash-commit"},"state":"MERGED","mergedAt":"2026-11-01T00:00:00Z"}"#, stderr: "")
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
    static func gitOutput(_ args: [String], in root: URL) -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args; p.currentDirectoryURL = root; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try! p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        precondition(p.terminationStatus == 0); return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
        // A direct commit titled with an issue number, like "(#293)" on t-boris/MarkView: BUG-104.
        commit("note.swift", "docs: a note about an issue (#4)")
        // The delivery rules of the standard workflow, as they are when it is adopted in a project without a Definition of Done.
        let standardFeature = ProjectWorkflow.standard.variant(StandardWorkflow.featureVariantID)!.deliveryRules
        let standardBug = ProjectWorkflow.standard.variant(StandardWorkflow.bugVariantID)!.deliveryRules
        func subject(_ kind: IssueKind, _ key: String, rules: DeliveryRules? = nil, confirmation: String? = nil) -> IssueEvidenceCollector.Subject {
            .init(kind: kind, issue: key, exclusiveNumbers: [], sharedNumbers: [], since: nil,
                  rules: rules ?? (kind == .feature ? standardFeature : standardBug), eventConfirmation: confirmation)
        }
        let feature = await IssueEvidenceCollector.collect(subject(.feature, "ci"), root: root, githubEnabled: true)
        check("a branch commit trailer identifies its merged PR", feature.isComplete && feature.lines.contains { $0.contains("PR #1") })
        let bug = await IssueEvidenceCollector.collect(subject(.bug, "BUG-123"), root: root, githubEnabled: true)
        check("a PR body identifies its merged bug fix", bug.isComplete && bug.lines.contains { $0.contains("PR #2") })
        let missing = await IssueEvidenceCollector.collect(subject(.feature, "absent"), root: root, githubEnabled: true)
        check("unrelated merges do not complete another issue", !missing.isComplete)
        let docsOnly = await IssueEvidenceCollector.collect(subject(.feature, "docs-only"), root: root, githubEnabled: true)
        check("a documentation commit is not attributed to the next unrelated merge", !docsOnly.isComplete)
        let released = await IssueEvidenceCollector.collect(subject(.feature, "ci"), root: root, githubEnabled: true)
        check("a merged feature does not need a release under the standard feature variant", released.isComplete)
        let releaseRules = DeliveryRules(integration: .directToMain, checksRequired: false, event: .githubRelease)
        let notReleased = await IssueEvidenceCollector.collect(subject(.feature, "ci", rules: releaseRules), root: root, githubEnabled: true)
        check("a variant that requires a GitHub release is complete once a release contains the work",
              notReleased.isComplete && notReleased.lines.contains { $0.contains("v1") })
        // An actual direct-to-main commit is identified by the feature discussion, without a commit trailer.
        commit("direct.swift", "Implement work directly")
        let sha = gitOutput(["rev-parse", "HEAD"], in: root)
        let discussion = root.appendingPathComponent("docs/features/direct/discussion.md")
        try! fm.createDirectory(at: discussion.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "Implementation was pushed directly to main at \(sha.prefix(7)). Local regression tests passed."
            .write(to: discussion, atomically: true, encoding: .utf8)
        let direct = await IssueEvidenceCollector.collect(subject(.feature, "direct"), root: root, githubEnabled: false)
        check("a documented direct main commit completes when PR and CI are not required", direct.isComplete && direct.lines.contains { $0.contains("CI not required") })
        let pullRequestRules = DeliveryRules(integration: .pullRequest, checksRequired: false, event: .none)
        let requiredPR = await IssueEvidenceCollector.collect(subject(.feature, "direct", rules: pullRequestRules), root: root, githubEnabled: true)
        check("a direct commit on main is a gap when the variant requires a pull request", !requiredPR.isComplete)
        let viaPR = await IssueEvidenceCollector.collect(subject(.feature, "ci", rules: pullRequestRules), root: root, githubEnabled: true)
        check("a merged pull request satisfies a variant that requires one", viaPR.isComplete)
        let unreleased = await IssueEvidenceCollector.collect(subject(.feature, "direct", rules: releaseRules), root: root, githubEnabled: true)
        check("a variant that requires a release waits when no release contains the work", !unreleased.isComplete)
        let needsRelease = await IssueEvidenceCollector.collect(subject(.feature, "direct", rules: releaseRules), root: root, githubEnabled: false)
        check("without GitHub a variant that needs a release is not complete", !needsRelease.isComplete)
        let eventRules = DeliveryRules(integration: .directToMain, checksRequired: false, event: .humanConfirmed(name: "installed"))
        let unconfirmed = await IssueEvidenceCollector.collect(subject(.feature, "direct", rules: eventRules), root: root, githubEnabled: false)
        check("a delivery event that a person confirms is missing until they do",
              !unconfirmed.isComplete && unconfirmed.lines.contains { $0.contains("\"installed\" has not been confirmed") })
        let confirmed = await IssueEvidenceCollector.collect(subject(.feature, "direct", rules: eventRules, confirmation: "on the other Mac"), root: root, githubEnabled: false)
        check("a person's confirmation completes it without GitHub", confirmed.isComplete && confirmed.lines.contains { $0.contains("confirmed by a person") })
        let unavailable = await IssueEvidenceCollector.collect(subject(.feature, "ci"), root: root, githubEnabled: false)
        check("a merged feature does not wait for unavailable checks", unavailable.isComplete)
        let shared = IssueEvidenceCollector.Subject(kind: .feature, issue: "not-ci", exclusiveNumbers: [], sharedNumbers: [77], since: nil, rules: standardFeature)
        let ambiguous = await IssueEvidenceCollector.collect(shared, root: root, githubEnabled: true)
        check("a shared GitHub issue reference does not confirm a particular feature", !ambiguous.isComplete)
        let reopened = IssueEvidenceCollector.Subject(kind: .feature, issue: "ci", exclusiveNumbers: [], sharedNumbers: [], since: Date().addingTimeInterval(60), rules: standardFeature)
        let old = await IssueEvidenceCollector.collect(reopened, root: root, githubEnabled: true)
        check("work merged before a reopening cannot complete it", !old.isComplete)
        try! "".write(to: root.appendingPathComponent(".failed-check"), atomically: true, encoding: .utf8)
        let failed = await IssueEvidenceCollector.collect(subject(.feature, "ci"), root: root, githubEnabled: true)
        check("a merged associated feature does not wait for checks under the standard feature variant", failed.isComplete)
        let checkRules = DeliveryRules(integration: .directToMain, checksRequired: true, event: .none)
        let failedChecks = await IssueEvidenceCollector.collect(subject(.feature, "ci", rules: checkRules), root: root, githubEnabled: true)
        check("a variant that requires successful checks is incomplete when one failed", !failedChecks.isComplete)
        // BUG-104: which answers of a batched pullRequest query can be trusted.
        func answer(_ status: Int32, _ object: [String: Any]) -> GitHubClient.Output {
            GitHubClient.Output(status: status, stdout: String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self), stderr: "")
        }
        func notFound(_ field: String) -> [String: Any] { ["type": "NOT_FOUND", "path": ["repository", field], "message": "Could not resolve"] }
        let two: [String: Any?] = ["p1": ["body": "one"], "p2": ["body": "two"]]
        let clean = IssueEvidenceCollector.pullRequestBodies(in: answer(0, ["data": ["repository": two]]), requested: [1, 2])
        check("every description of a clean answer is read", clean == [1: "one", 2: "two"])
        let partial = IssueEvidenceCollector.pullRequestBodies(
            in: answer(1, ["data": ["repository": ["p1": ["body": "one"], "p4": NSNull()]], "errors": [notFound("p4")]]), requested: [1, 4])
        check("an issue number among the pull requests is skipped, the others are read", partial == [1: "one"])
        let denied = IssueEvidenceCollector.pullRequestBodies(
            in: answer(1, ["data": ["repository": ["p1": NSNull()]], "errors": [["type": "FORBIDDEN", "path": ["repository", "p1"], "message": "no access"]]]), requested: [1])
        check("an error other than NOT_FOUND fails the read", denied == nil)
        let rateLimited = IssueEvidenceCollector.pullRequestBodies(
            in: answer(1, ["data": ["repository": ["p1": ["body": "one"]]], "errors": [["type": "RATE_LIMITED", "message": "limit"]]]), requested: [1])
        check("an error without a path fails the read", rateLimited == nil)
        let stranger = IssueEvidenceCollector.pullRequestBodies(
            in: answer(1, ["data": ["repository": ["p1": ["body": "one"]]], "errors": [notFound("p9")]]), requested: [1])
        check("NOT_FOUND on a field that was not requested fails the read", stranger == nil)
        let deeper = IssueEvidenceCollector.pullRequestBodies(
            in: answer(1, ["data": ["repository": ["p1": ["body": "one"]]], "errors": [["type": "NOT_FOUND", "path": ["repository", "p1", "body"], "message": "x"]]]), requested: [1])
        check("NOT_FOUND below a field fails the read", deeper == nil)
        let noRepository = IssueEvidenceCollector.pullRequestBodies(in: answer(1, ["data": NSNull(), "errors": [notFound("p1")]]), requested: [1])
        check("an answer without the repository fails the read", noRepository == nil)
        let failedProcess = IssueEvidenceCollector.pullRequestBodies(in: answer(1, ["data": ["repository": two]]), requested: [1, 2])
        check("a failed gh whose answer has no errors fails the read", failedProcess == nil)
        let offline = IssueEvidenceCollector.pullRequestBodies(in: GitHubClient.Output(status: 1, stdout: "", stderr: "dial tcp: no route to host"), requested: [1])
        check("no answer at all fails the read", offline == nil)
        let malformed = IssueEvidenceCollector.pullRequestBodies(
            in: answer(1, ["data": ["repository": ["p1": ["body": "one"]]], "errors": "NOT_FOUND"]), requested: [1])
        check("errors that are not a list fail the read", malformed == nil)
        // BUG-106: the oldest commit of a shallow clone has no parent for git, so `--name-only` lists its whole tree.
        let source = fm.temporaryDirectory.appendingPathComponent("issue-collector-source-\(UUID().uuidString)")
        let shallow = fm.temporaryDirectory.appendingPathComponent("issue-collector-shallow-\(UUID().uuidString)")
        try! fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: source); try? fm.removeItem(at: shallow) }
        git(["init", "-b", "main"], in: source)
        git(["config", "user.name", "Test"], in: source)
        git(["config", "user.email", "test@example.org"], in: source)
        func sourceCommit(_ name: String, _ body: String) {
            let url = source.appendingPathComponent(name)
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! body.write(to: url, atomically: true, encoding: .utf8)
            git(["add", name], in: source)
            git(["commit", "-m", body], in: source)
        }
        sourceCommit("app.swift", "initial code")
        sourceCommit("docs/bugs/BUG-200.md", "Record BUG-200 in the project records")
        git(["checkout", "-b", "fix-200"], in: source)
        sourceCommit("fix.swift", "Fix BUG-200")
        git(["checkout", "main"], in: source)
        git(["merge", "--no-ff", "fix-200", "-m", "Merge pull request #1 from example/fix-200\n\nFix BUG-200"], in: source)
        git(["clone", "-q", "--depth", "2", "--branch", "main", "file://\(source.path)", shallow.path], in: fm.temporaryDirectory)
        // A depth-2 clone of a merge has two roots (the record and the fix); the commit the collector sees is the end of the first-parent
        // chain, found by position so that the commit timestamps (which tie within one second) cannot change the answer.
        let recordSHA = gitOutput(["rev-list", "--first-parent", "HEAD"], in: shallow).split(separator: "\n").last.map(String.init) ?? ""
        let marker = shallow.appendingPathComponent(".gh-commit-files")
        let boundary = IssueEvidenceCollector.Subject(kind: .bug, issue: "BUG-200", exclusiveNumbers: [], sharedNumbers: [], since: nil, rules: standardBug)

        try! "docs/bugs/BUG-200.md\n".write(to: marker, atomically: true, encoding: .utf8)
        let recorded = await IssueEvidenceCollector.collect(boundary, root: shallow, githubEnabled: true)
        check("the documentation record at the end of a shallow clone is not code work", recorded.isComplete && recorded.lines.contains { $0.contains("PR #1") })
        check("the record is not listed as a work unit", !recorded.lines.contains { $0.contains(String(recordSHA.prefix(7))) })

        try! "app.swift\ndocs/bugs/BUG-200.md\n".write(to: marker, atomically: true, encoding: .utf8)
        let code = await IssueEvidenceCollector.collect(boundary, root: shallow, githubEnabled: true)
        check("a code commit at the end of a shallow clone is still code work", !code.isComplete && code.lines.contains { $0.contains(String(recordSHA.prefix(7))) })

        try! fm.removeItem(at: marker)
        let unreadable = await IssueEvidenceCollector.collect(boundary, root: shallow, githubEnabled: true)
        var unknownOnly = false
        if case .unknown(let reasons) = unreadable { unknownOnly = reasons.contains { $0.contains("changed files of commit") } }
        check("files GitHub cannot list leave the end of a shallow clone unknown, not a definite gap", unknownOnly)
        let off = await IssueEvidenceCollector.collect(boundary, root: shallow, githubEnabled: false)
        var offUnknown = false
        if case .unknown = off { offUnknown = true }
        check("with GitHub off the end of a shallow clone is unknown, not missing a pull request", offUnknown && !off.lines.contains { $0.contains("requires a merged pull request") })

        // A complete clone keeps the files git reports: a documentation-only first commit stays documentation.
        let whole = fm.temporaryDirectory.appendingPathComponent("issue-collector-whole-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: whole) }
        git(["clone", "-q", "file://\(source.path)", whole.path], in: fm.temporaryDirectory)
        let complete = await IssueEvidenceCollector.collect(boundary, root: whole, githubEnabled: true)
        check("a complete clone is judged by the files git reports", complete.isComplete && complete.lines.contains { $0.contains("PR #1") })
        finish("issue collector")
    }
}
