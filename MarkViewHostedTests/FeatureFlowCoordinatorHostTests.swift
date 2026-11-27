import Foundation
import AppKit
import Darwin
import MarkViewCore
import XCTest
@testable import MarkView

@MainActor
private final class FeatureFlowAssistantSpy: AssistantProviding, AssistantPrompting {
    let session: TerminalSession
    var sends = true
    var assistantIsBusy = false
    private(set) var sent: [(prompt: String, submit: Bool, terminal: TerminalSession)] = []
    var currentAssistant: CLICompletion.Assistant? { nil }
    var sessions: [TerminalSession] { [session] }
    var shownID: UUID? { session.id }
    init(root: URL) { session = TerminalSession(directory: root, profile: .assistant(CLITool(rawValue: "claude")!)) }
    func liveModelReported(_ model: String, terminalID: UUID) {}
    func openAITerminal(_ profile: TerminalProfile, resuming: Bool, model: String?) -> TerminalSession? { nil }
    func showAIConsole() {}
    func sendToAssistant(submit: Bool, to terminal: TerminalSession?, promptFor: (TerminalSession) -> String?) -> TerminalSession? {
        guard sends else { return nil }
        let target = terminal ?? session
        guard let prompt = promptFor(target) else { return nil }
        sent.append((prompt, submit, target))
        return target
    }
}

@MainActor
private final class FeatureFlowTabsSpy: FeatureFlowTabs {
    var activeTab: OpenTab?
    private(set) var opened: [URL] = []
    func openFile(_ url: URL) { opened.append(url) }
    func showGitHubTab(_ item: GitHubItem, root: URL) {}
    func reloadChangedOpenFiles(all: Bool) async {}
}

private actor FeatureIntakeFixture {
    enum Mode { case answer, bugAnswer, delayedAnswer, text, fail, wait }
    var mode: Mode = .answer
    var requests: [CLICompletion.Request] = []
    var cancellations = 0
    func setMode(_ mode: Mode) { self.mode = mode }
    func count() -> Int { requests.count }
    func lastRequest() -> CLICompletion.Request? { requests.last }
    func firstRequest(label: String) -> CLICompletion.Request? { requests.first { $0.label == label } }
    func cancellationCount() -> Int { cancellations }
    private static func answer() throws -> CLICompletion.Result {
        let object: [String: Any] = ["title": "Fixture feature", "idea": "A fixture", "problem": "A problem", "scope": "A scope",
                                     "analysis": "An analysis", "assumptions": [], "acceptance_criteria": ["It works"]]
        return try CLICompletion.Result(text: "", structured: object, inputTokens: 0, outputTokens: 0, costUSD: nil)
    }
    func run(_ request: CLICompletion.Request, _ delta: (@Sendable (String) -> Void)?,
             _ activity: (@Sendable (CLICompletion.Activity) -> Void)?) async throws -> CLICompletion.Result {
        requests.append(request)
        switch mode {
        case .answer:
            return try Self.answer()
        case .bugAnswer:
            return try CLICompletion.Result(text: "", structured: ["title": "Fixture bug", "summary": "A fixture",
                                                                          "severity": "medium", "questions": []],
                                            inputTokens: 0, outputTokens: 0, costUSD: nil)
        case .delayedAnswer:
            try await Task.sleep(nanoseconds: 200_000_000)
            return try Self.answer()
        case .text:
            return try CLICompletion.Result(text: "Fixture answer", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        case .fail:
            throw NSError(domain: "FeatureIntakeFixture", code: 7, userInfo: [NSLocalizedDescriptionKey: "fixture failure"])
        case .wait:
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { cancellations += 1; throw error }
            throw CancellationError()
        }
    }
}

extension EditorHostTests {
    @MainActor func testRealFeatureFlowGitHubCheckoutWithLocalFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-checkout-host-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) async throws -> String {
            let output = await GitHubClient.execute(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args,
                                                    in: root, git: true)
            guard output.status == 0 else { throw NSError(domain: "LocalGitFixture", code: Int(output.status), userInfo: [NSLocalizedDescriptionKey: output.stderr]) }
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["config", "core.hooksPath", "/dev/null"])
        let tracked = root.appendingPathComponent("tracked.md")
        try "initial\n".write(to: tracked, atomically: true, encoding: .utf8)
        _ = try await git(["add", "tracked.md"])
        _ = try await git(["commit", "-q", "-m", "initial"])
        _ = try await git(["branch", "pr-5"])
        _ = try await git(["branch", "pr-7"])
        _ = try await git(["remote", "add", "origin", "https://github.com/fixture-org/fixture.git"])
        let fixture = root.appendingPathComponent("fixture-gh")
        let script = #"""
        #!/bin/sh
        set -eu
        fixture_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
        [ "$(pwd -P)" = "$fixture_root" ] || exit 91
        [ -f "$fixture_root/fixture-gh" ] || exit 92
        [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || exit 93
        [ "${GH_CONFIG_DIR##*/}" = '.test-gh-config' ] || exit 94
        config_parent=$(CDPATH= cd -- "$(dirname -- "$GH_CONFIG_DIR")" && pwd -P)
        [ "$config_parent" = "$fixture_root" ] || exit 95
        printf '%s\n' "$*" >> "$fixture_root/fixture-gh.log"
        case "${1:-} ${2:-} ${3:-}" in
          'pr checkout 5') exec /usr/bin/git switch -q pr-5 ;;
          'pr checkout 7') exec /usr/bin/git switch -q pr-7 ;;
          'pr checkout 8') echo 'fixture checkout failed' >&2; exit 1 ;;
          'pr view 5') printf '{"number":5,"title":"Fixture 5","headRefName":"pr-5","baseRefName":"main","state":"OPEN","url":"https://example.invalid/5"}\n' ;;
          'pr view 7') printf '{"number":7,"title":"Fixture 7","headRefName":"pr-7","baseRefName":"main","state":"OPEN","url":"https://example.invalid/7"}\n' ;;
          'run view 1')
            case " $* " in
              *' --json jobs '*) printf '{"jobs":[{"databaseId":11,"name":"Build","status":"completed","conclusion":"failure","steps":[{"name":"Build","number":1,"status":"completed","conclusion":"failure"}]}]}\n' ;;
              *) printf '{"databaseId":1,"number":1,"displayTitle":"CI","workflowName":"CI","status":"completed","conclusion":"failure","headBranch":"other","event":"push","createdAt":"2026-01-01T00:00:00Z","url":"https://example.invalid/1"}\n' ;;
            esac ;;
          'api repos/fixture-org/fixture/actions/jobs/11/logs ')
            if [ -f "$fixture_root/block-log" ]; then
              /bin/sleep 30 &
              child=$!
              printf '%s %s\n' "$$" "$child" >> "$fixture_root/blocked-pids"
              wait "$child"
            fi
            printf '##[group]Run Build\nerror: fixture build failed\n' ;;
          *) printf '[]\n' ;;
        esac
        """#
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        GitHubClient.setTestGHExecutable(nil)
        let disabled = await GitHubClient.execute(["--version"], in: root)
        XCTAssertEqual(disabled.status, -1, "The test host must never discover the user's gh")
        GitHubClient.setTestGHExecutable(fixture)
        defer { GitHubClient.setTestGHExecutable(nil) }
        let preflight = await GitHubClient.execute(["--version"], in: root)
        guard preflight.status == 0 else { return XCTFail("Fixture preflight exited \(preflight.status): \(preflight.stderr)") }
        let settings = Settings.standard
        let previous = settings.stored(Setting.gitHubEnabled)
        settings.set(false, for: Setting.gitHubEnabled)
        defer {
            if let previous { settings.set(previous, for: Setting.gitHubEnabled) } else { settings.remove(Setting.gitHubEnabled) }
        }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        let previousFolder = settings.stored(Setting.lastFolder)
        let previousProjects = settings.stored(Setting.recentProjects)
        window.project.beginOpening(root)
        if let previousFolder { settings.set(previousFolder, for: Setting.lastFolder) } else { settings.remove(Setting.lastFolder) }
        if let previousProjects { settings.set(previousProjects, for: Setting.recentProjects) } else { settings.remove(Setting.recentProjects) }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        window.composition.gitClient.workingDirectory = root
        let assistant = FeatureFlowAssistantSpy(root: root)
        let flow = FeatureFlowCoordinator(project: window.project, assistants: assistant, tabs: window, requests: window.requests,
                                          layout: window.layout, chrome: window.chrome, gitClient: window.composition.gitClient,
                                          research: window.composition.research)
        defer { flow.close() }
        let evidence = LifecycleLog(testURL: root.appendingPathComponent("test-lifecycle-events.jsonl"))
        flow.features.testLifecycleLog = evidence
        let fallback = FeatureFlowCoordinator(project: window.project, assistants: assistant, tabs: window, requests: window.requests,
                                              layout: window.layout, chrome: window.chrome, gitClient: window.composition.gitClient,
                                              research: window.composition.research)
        defer { fallback.close() }
        fallback.openGitHubIssue(13)
        fallback.reset()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(window.tabs.openTabs.isEmpty, "Closing the flow cancels opening the external issue page")
        flow.setUp(at: root)
        XCTAssertFalse(GitHubSettings.enabled)
        let activation = await flow.activateGitHub(expecting: "FIXTURE-ORG/FIXTURE", in: root)
        XCTAssertNil(activation)
        XCTAssertTrue(GitHubSettings.enabled)
        for _ in 0..<500 where flow.gitHub.client == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(flow.gitHub.selectedRepo?.slug, "fixture-org/fixture")
        window.composition.gitClient.branchReports.send("fixture-branch")
        XCTAssertEqual(flow.gitHub.branch, "fixture-branch")
        let lifecycleFeature = try XCTUnwrap(flow.features.createFeature(title: "Poll fixture", idea: "A fixture"))
        flow.features.updateFeature(lifecycleFeature) { front, _ in front.set("issue", "#42") }
        _ = evidence.record(.workStarted, project: root.standardizedFileURL.path, feature: lifecycleFeature, actor: "Tester")
        await evidence.drainTestWrites()
        let pollLog = root.appendingPathComponent("fixture-gh.log")
        XCTAssertFalse((try String(contentsOf: pollLog, encoding: .utf8)).contains("api graphql"))
        let pollClient = try XCTUnwrap(flow.gitHub.client)
        flow.gitHub.polls.send(pollClient)
        for _ in 0..<500 {
            if ((try? String(contentsOf: pollLog, encoding: .utf8)) ?? "").contains("api graphql") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue((try String(contentsOf: pollLog, encoding: .utf8)).contains("api graphql"), "A GitHub poll reaches feature lifecycle synchronization")
        flow.openGitHubIssue(12)
        guard case .github(let item)? = window.tabs.activeTab?.kind else { return XCTFail("The issue tab was not opened") }
        XCTAssertEqual(item, .issue(number: 12, repo: "fixture-org/fixture", title: "#12"))
        let bugFixture = FeatureIntakeFixture()
        await bugFixture.setMode(.bugAnswer)
        AIAssistantRunner.setTestRunner { request, delta, activity in try await bugFixture.run(request, delta, activity) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        var intakeResults: [String?] = []
        window.requests.intake = IntakeRequest(kind: .bug)
        flow.submitIntake(.bug, from: "A synthetic failure", attachments: [], linkedIssue: 42, commentOnIssue: true) { intakeResults.append($0) }
        for _ in 0..<500 where intakeResults.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(intakeResults.count, 1)
        XCTAssertNil(intakeResults.first ?? "missing")
        let bug = try XCTUnwrap(flow.features.bugs.first)
        let bugFront = FrontMatter.split(try String(contentsOf: bug.url, encoding: .utf8)).0
        XCTAssertEqual(bugFront.string("issue"), "#42")
        let localLog = root.appendingPathComponent("fixture-gh.log")
        XCTAssertTrue((try String(contentsOf: localLog, encoding: .utf8)).contains("issue comment 42"))
        AIAssistantRunner.setTestRunner(nil)
        let checkout = await flow.checkoutPullRequest(5)
        XCTAssertNil(checkout)
        let firstBranch = try await git(["branch", "--show-current"])
        XCTAssertEqual(firstBranch, "pr-5")
        XCTAssertEqual(window.composition.gitClient.branch, "pr-5")
        for _ in 0..<200 where window.project.fileTree.rootNode?.children?.contains(where: { $0.name == "tracked.md" }) != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(window.project.fileTree.rootNode?.children?.contains(where: { $0.name == "tracked.md" }) == true)
        let log = root.appendingPathComponent("fixture-gh.log")
        let before = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "pr checkout 5").count
        let sameBranch = await flow.fixInPullRequest(5, prompt: "Fix the fixture.", work: .parts)
        XCTAssertNil(sameBranch)
        // The spy's terminal runs Claude Code: the request to work in parallel follows the prompt, in Claude Code's words.
        XCTAssertEqual(assistant.sent.last?.prompt, ParallelWork.parts.ask("Fix the fixture.", tool: CLITool(rawValue: "claude")))
        XCTAssertNotEqual(assistant.sent.last?.prompt, "Fix the fixture.")
        let after = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "pr checkout 5").count
        XCTAssertEqual(after, before, "A pull request already checked out is not checked out again")
        try "modified\n".write(to: tracked, atomically: true, encoding: .utf8)
        let refused = await flow.checkoutPullRequest(6)
        XCTAssertTrue(refused?.contains("uncommitted changes") == true)
        XCTAssertTrue(refused?.contains("#6") == true)
        XCTAssertFalse((try String(contentsOf: log, encoding: .utf8)).contains("pr checkout 6"))
        _ = try await git(["checkout", "--", "tracked.md"])
        try "untracked\n".write(to: root.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        let untracked = await flow.fixInPullRequest(7, prompt: "Fix the other fixture.", work: .parts)
        XCTAssertNil(untracked)
        XCTAssertEqual(assistant.sent.last?.prompt, ParallelWork.parts.ask("Fix the other fixture.", tool: CLITool(rawValue: "claude")))
        let secondBranch = try await git(["branch", "--show-current"])
        XCTAssertEqual(secondBranch, "pr-7")
        let failure = await flow.checkoutPullRequest(8)
        XCTAssertTrue(failure?.contains("fixture checkout failed") == true)
        let client = try XCTUnwrap(flow.gitHub.client)
        let model = GitHubRunModel(runId: 1, client: client, store: flow.gitHub)
        defer { model.close() }
        for _ in 0..<500 where model.run == nil || model.jobs.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.run)
        XCTAssertEqual(model.jobs.count, 1)
        let oldCount = assistant.sent.count
        flow.fixRunWithAI(model)
        for _ in 0..<500 where assistant.sent.count == oldCount { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(assistant.sent.count, oldCount + 1)
        let runPrompt = try XCTUnwrap(assistant.sent.last?.prompt)
        XCTAssertTrue(runPrompt.contains("fixture build failed"))
        XCTAssertTrue(runPrompt.contains("the run was on branch other; the working copy is on pr-7"))
        XCTAssertTrue(runPrompt.contains("\nFind the cause in this repository and fix it.\n\n"))
        XCTAssertTrue(runPrompt.hasSuffix(try XCTUnwrap(ParallelWork.parts.request(for: CLITool(rawValue: "claude")!.provider))))

        let block = root.appendingPathComponent("block-log")
        try Data().write(to: block)
        let delayed = GitHubRunModel(runId: 1, client: client, store: flow.gitHub)
        defer { delayed.close() }
        for _ in 0..<500 where delayed.run == nil || delayed.jobs.isEmpty || !delayed.loadingLog.contains(11) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(delayed.loadingLog.contains(11))
        let beforeStop = assistant.sent.count
        flow.fixRunWithAI(delayed)
        let pidsFile = root.appendingPathComponent("blocked-pids")
        var pids: [Int32] = []
        for _ in 0..<500 {
            let text = (try? String(contentsOf: pidsFile, encoding: .utf8)) ?? ""
            pids = text.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
            if pids.count >= 4 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(pids.count, 4, "Both log requests must be running before cancellation")
        flow.close()
        delayed.close()
        try FileManager.default.removeItem(at: block)
        for _ in 0..<500 where pids.contains(where: { Darwin.kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(pids.allSatisfy { Darwin.kill($0, 0) != 0 }, "Every blocked fixture process must end")
        XCTAssertEqual(assistant.sent.count, beforeStop, "Closing cancels a log hand-off that has not completed")
        await evidence.drainTestWrites()
    }

    @MainActor func testRealFeatureFlowProjectLifecycle() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("feature-lifecycle-host-" + UUID().uuidString)
        let first = base.appendingPathComponent("first", isDirectory: true)
        let second = base.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try ProjectWorkflowStore(projectRoot: first).save(.standard, expectedRevision: 0)
        _ = try ProjectWorkflowStore(projectRoot: second).save(.standard, expectedRevision: 0)
        let settings = Settings.standard
        let previous = settings.stored(Setting.gitHubEnabled)
        settings.set(false, for: Setting.gitHubEnabled)
        defer {
            if let previous { settings.set(previous, for: Setting.gitHubEnabled) } else { settings.remove(Setting.gitHubEnabled) }
        }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: first, isDirectory: true)
        let flow = window.flow
        flow.setUp(at: first)
        XCTAssertEqual(flow.features.root, first)
        XCTAssertTrue(flow.features.assistant.project === window.project)
        XCTAssertNil(flow.gitHub.root)
        let bug = try flow.features.createBug(BugReportDraft(title: "First", body: "Fixture", provenance: "Test"))
        flow.bugBatch.toggle(try XCTUnwrap(flow.features.bug(at: bug.url)))
        XCTAssertEqual(flow.bugBatch.basket.count, 1)
        flow.setUp(at: first)
        XCTAssertEqual(flow.bugBatch.basket.count, 1, "Reopening the same folder keeps its basket")
        window.project.fileTree.rootNode = FileNode(url: second, isDirectory: true)
        flow.cancelWork()
        flow.setUp(at: second)
        XCTAssertEqual(flow.features.root, second)
        XCTAssertTrue(flow.bugBatch.basket.isEmpty, "A different folder starts with an empty basket")
        XCTAssertNil(flow.gitHub.root)
        settings.set(true, for: Setting.gitHubEnabled)
        for _ in 0..<200 where flow.gitHub.root != second { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(flow.gitHub.root, second)
        settings.set(false, for: Setting.gitHubEnabled)
        for _ in 0..<200 where flow.gitHub.root != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(flow.gitHub.root)
        flow.reset()
        XCTAssertNil(flow.features.root)
        XCTAssertNil(flow.gitHub.root)
        flow.close()
        settings.set(true, for: Setting.gitHubEnabled)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(flow.gitHub.root, "A closed window no longer follows the integration setting")
    }

    @MainActor func testRealFeatureFlowResearchComment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-comment-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("research.md")
        try "# Research\n\n## Findings\n\nThe selected passage.\n".write(to: file, atomically: true, encoding: .utf8)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        await window.tabs.openTextFile(file)
        let fixture = FeatureIntakeFixture()
        await fixture.setMode(.text)
        AIAssistantRunner.setTestRunner { request, delta, activity in try await fixture.run(request, delta, activity) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        window.flow.runFeatureAction("comment", text: "The selected passage.", question: "Tighten this")
        XCTAssertTrue(window.research.jobs.isRunning(on: file))
        for _ in 0..<500 where window.research.jobs.isRunning(on: file) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(window.research.jobs.isRunning(on: file))
        let request = await fixture.lastRequest()
        let sent = try XCTUnwrap(request)
        XCTAssertTrue(sent.prompt.contains("The selected passage."))
        XCTAssertTrue(sent.prompt.contains("Tighten this"))
        XCTAssertEqual(sent.project?.standardizedFileURL.path, root.standardizedFileURL.path)
        let revised = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(revised.contains("Fixture answer"))
        XCTAssertTrue(revised.contains("## Findings"))
    }

    @MainActor func testRealFeatureFlowSelectedTextAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-selection-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ProjectWorkflowStore(projectRoot: root).save(.standard, expectedRevision: 0)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let tabs = FeatureFlowTabsSpy()
        let assistant = FeatureFlowAssistantSpy(root: root)
        let flow = FeatureFlowCoordinator(project: window.project, assistants: assistant, tabs: tabs, requests: window.requests,
                                          layout: window.layout, chrome: window.chrome, gitClient: window.composition.gitClient,
                                          research: window.composition.research)
        defer { flow.close() }
        flow.features.setup(root: root)
        let slug = try XCTUnwrap(flow.features.createFeature(title: "Test feature", idea: "An idea"))
        let overview = try XCTUnwrap(flow.features.feature(slug)?.overviewURL)
        tabs.activeTab = OpenTab(url: overview, content: "", originalContent: "")
        let fixture = FeatureIntakeFixture()
        await fixture.setMode(.text)
        AIAssistantRunner.setTestRunner { request, delta, activity in try await fixture.run(request, delta, activity) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        flow.runFeatureAction("ask", text: "selected passage", question: "why?")
        for _ in 0..<500 {
            if flow.features.assistant.results.first?.pending == false { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let result = try XCTUnwrap(flow.features.assistant.results.first)
        XCTAssertFalse(result.pending)
        XCTAssertEqual(result.text, "Fixture answer")
        XCTAssertEqual(result.feature, slug)
        let request = await fixture.lastRequest()
        let sent = try XCTUnwrap(request)
        XCTAssertTrue(sent.prompt.contains("selected passage"))
        XCTAssertTrue(sent.prompt.contains("why?"))
        XCTAssertTrue(sent.prompt.contains("docs/features/\(slug)/overview.md"))
        XCTAssertEqual(window.layout.navigatorTab, .feature)
        XCTAssertTrue(window.chrome.showTOC)
        flow.runFeatureAction("nonsense", text: "ignored", question: "")
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = await fixture.count()
        XCTAssertEqual(count, 1)
    }

    @MainActor func testRealFeatureFlowConflictAndBugBasketHandoffs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-basket-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var workflow = ProjectWorkflow.standard
        var restricted = workflow.bug.rules
        let start = try XCTUnwrap(restricted.firstIndex { $0.kind == .start })
        restricted[start].needs.removeValue(forKey: .human)
        workflow.variants.append(RuleVariant(id: "restricted-bug", name: "Restricted bug", kind: .bug,
                                             integration: .directToMain, checks: false, rules: restricted))
        _ = try ProjectWorkflowStore(projectRoot: root).save(workflow, expectedRevision: 0)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let assistant = FeatureFlowAssistantSpy(root: root)
        let git = window.composition.gitClient
        let flow = FeatureFlowCoordinator(project: window.project, assistants: assistant, tabs: window, requests: window.requests,
                                          layout: window.layout, chrome: window.chrome, gitClient: git,
                                          research: window.composition.research)
        defer { flow.close() }
        flow.resolveConflictsWithAI()
        XCTAssertTrue(assistant.sent.isEmpty)
        git.branch = "feature"
        git.operationInProgress = "merge"
        git.repoStatus = GitRepoStatus.parse("u UU N... 100644 100644 100644 100644 aaaa bbbb cccc src/a.swift\0u UU N... 100644 100644 100644 100644 aaaa bbbb cccc src/b.swift\0")
        assistant.assistantIsBusy = true
        flow.resolveConflictsWithAI()
        XCTAssertTrue(assistant.sent.isEmpty)
        XCTAssertTrue(git.lastError?.contains("still working") == true)
        assistant.assistantIsBusy = false
        flow.resolveConflictsWithAI()
        let conflict = try XCTUnwrap(assistant.sent.last)
        for text in ["src/a.swift", "src/b.swift", "merge", "feature"] { XCTAssertTrue(conflict.prompt.contains(text)) }
        XCTAssertTrue(conflict.submit)
        // Two conflicted files are a list of items: the Claude Code terminal is asked for a workflow over them.
        let claude = try XCTUnwrap(CLITool(rawValue: "claude"))
        XCTAssertTrue(conflict.prompt.hasSuffix(try XCTUnwrap(ParallelWork.items.request(for: claude.provider))))
        git.repoStatus = GitRepoStatus.parse("u UU N... 100644 100644 100644 100644 aaaa bbbb cccc src/a.swift\0")
        flow.resolveConflictsWithAI()
        XCTAssertTrue(try XCTUnwrap(assistant.sent.last).prompt.hasSuffix(try XCTUnwrap(ParallelWork.parts.request(for: claude.provider))),
                      "one file is one task, not a list")

        flow.features.setup(root: root)
        let first = try flow.features.createBug(BugReportDraft(title: "First bug", body: "First", provenance: "Test"))
        let second = try flow.features.createBug(BugReportDraft(title: "Second bug", body: "Second", provenance: "Test"))
        let firstReport = try XCTUnwrap(flow.features.bug(at: first.url))
        let secondReport = try XCTUnwrap(flow.features.bug(at: second.url))
        flow.bugBatch.toggle(firstReport)
        flow.fixBasketWithAI()
        XCTAssertEqual(assistant.sent.count, 2, "One bug is not a batch")
        flow.bugBatch.toggle(secondReport)
        XCTAssertEqual(flow.bugBatch.eligible.count, 2)
        assistant.assistantIsBusy = true
        flow.fixBasketWithAI()
        XCTAssertEqual(assistant.sent.count, 2)
        XCTAssertEqual(flow.bugBatch.eligible.count, 2)
        assistant.assistantIsBusy = false
        assistant.sends = false
        flow.fixBasketWithAI()
        XCTAssertEqual(assistant.sent.count, 2)
        XCTAssertEqual(flow.bugBatch.eligible.count, 2)
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, first.id), "open")
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, second.id), "open")
        XCTAssertNotNil(flow.bugBatch.notice)
        let third = try flow.features.createBug(BugReportDraft(title: "Restricted bug", body: "Third", provenance: "Test"))
        flow.bugBatch.toggle(try XCTUnwrap(flow.features.bug(at: third.url)))
        XCTAssertTrue(flow.features.lifecycle.assignVariant(.bug, third.id, to: "restricted-bug", by: .human("Tester")))
        XCTAssertFalse(flow.features.lifecycle.canStartByHandoff(.bug, third.id))
        assistant.sends = true
        flow.fixBasketWithAI()
        XCTAssertEqual(assistant.sent.count, 3)
        let sent = try XCTUnwrap(assistant.sent.last)
        XCTAssertTrue(sent.prompt.contains(first.id))
        XCTAssertTrue(sent.prompt.contains(second.id))
        XCTAssertFalse(sent.prompt.contains(third.id))
        XCTAssertTrue(sent.submit)
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, first.id), "fixing")
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, second.id), "fixing")
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, third.id), "open")
        XCTAssertTrue(flow.bugBatch.notice?.contains(third.id) == true)
        XCTAssertTrue(flow.bugBatch.basket.isEmpty)
        let fourth = try flow.features.createBug(BugReportDraft(title: "Fourth bug", body: "Fourth", provenance: "Test"))
        let fifth = try flow.features.createBug(BugReportDraft(title: "Fifth bug", body: "Fifth", provenance: "Test"))
        flow.bugBatch.toggle(try XCTUnwrap(flow.features.bug(at: fourth.url)))
        flow.bugBatch.toggle(try XCTUnwrap(flow.features.bug(at: fifth.url)))
        flow.fixBasketWithAI()
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, fourth.id), "fixing")
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, fifth.id), "fixing")
        XCTAssertTrue(flow.bugBatch.basket.isEmpty)
        XCTAssertNil(flow.bugBatch.notice)
    }

    @MainActor func testRealFeatureFlowIntakeSubmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-intake-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = FeatureIntakeFixture()
        AIAssistantRunner.setTestRunner { request, delta, activity in try await fixture.run(request, delta, activity) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        _ = try ProjectWorkflowStore(projectRoot: root).save(.standard, expectedRevision: 0)
        let tabs = FeatureFlowTabsSpy()
        let flow = FeatureFlowCoordinator(project: window.project, assistants: window.terminals, tabs: tabs, requests: window.requests,
                                          layout: window.layout, chrome: window.chrome, gitClient: window.composition.gitClient,
                                          research: window.composition.research)
        defer { flow.close() }
        flow.features.setup(root: root)
        func wait(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<500 {
                if condition() { return true }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return condition()
        }
        var results: [String?] = []
        let attachment = root.appendingPathComponent("attachment.md")
        try "attachment fixture".write(to: attachment, atomically: true, encoding: .utf8)
        window.requests.intake = IntakeRequest(kind: .quickFeature)
        flow.submitIntake(.quickFeature, from: "make it", attachments: [attachment], linkedIssue: 5, commentOnIssue: false) { results.append($0) }
        let success = try await wait { !results.isEmpty }
        XCTAssertTrue(success)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first ?? "missing")
        XCTAssertNil(window.requests.intake)
        XCTAssertEqual(flow.features.features.first?.title, "Fixture feature")
        XCTAssertEqual(window.layout.featureStage, .build)
        let overview = try XCTUnwrap(flow.features.features.first?.overviewURL)
        XCTAssertEqual(tabs.opened, [overview])
        let front = FrontMatter.split(try String(contentsOf: overview, encoding: .utf8)).0
        XCTAssertEqual(front.string("issue"), "#5")
        let intakeRequest = await fixture.firstRequest(label: "intake:quick-feature")
        XCTAssertTrue(intakeRequest?.prompt.contains("make it") == true)
        XCTAssertTrue(intakeRequest?.prompt.contains("attachment.md") == true)
        let sources = overview.deletingLastPathComponent().appendingPathComponent(FeatureObjectKind.source.folder)
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path)
        XCTAssertTrue(files.contains { $0.hasSuffix("-attachment.md") })

        await fixture.setMode(.fail)
        results = []
        window.requests.intake = IntakeRequest(kind: .bug)
        let openBeforeFailure = tabs.opened
        flow.submitIntake(.bug, from: "it breaks", attachments: [], linkedIssue: nil, commentOnIssue: false) { results.append($0) }
        let failed = try await wait { !results.isEmpty }
        XCTAssertTrue(failed)
        XCTAssertEqual(results.first ?? nil, "fixture failure")
        XCTAssertEqual(window.requests.intake?.kind, .bug)
        XCTAssertEqual(tabs.opened, openBeforeFailure)

        await fixture.setMode(.delayedAnswer)
        results = []
        let existingFeatures = flow.features.features.count
        flow.submitIntake(.quickFeature, from: "first", attachments: [], linkedIssue: 5, commentOnIssue: false) { results.append($0) }
        flow.submitIntake(.quickFeature, from: "second", attachments: [], linkedIssue: 5, commentOnIssue: false) { results.append($0) }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first.flatMap { $0 }?.contains("already being made") == true)
        let delayedFinished = try await wait { results.count == 2 }
        XCTAssertTrue(delayedFinished)
        XCTAssertNil(results.last ?? "missing")
        XCTAssertEqual(flow.features.features.count, existingFeatures + 1)

        await fixture.setMode(.wait)
        results = []
        window.requests.intake = IntakeRequest(kind: .quickFeature)
        let previous = await fixture.count()
        flow.submitIntake(.quickFeature, from: "one", attachments: [], linkedIssue: nil, commentOnIssue: false) { results.append($0) }
        flow.submitIntake(.quickFeature, from: "two", attachments: [], linkedIssue: nil, commentOnIssue: false) { results.append($0) }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first.flatMap { $0 }?.contains("already being made") == true)
        for _ in 0..<200 {
            if await fixture.count() > previous { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let count = await fixture.count()
        XCTAssertEqual(count, previous + 1)
        let openBeforeClose = tabs.opened
        let featureFolder = root.appendingPathComponent("docs/features")
        let featuresBeforeClose = try FileManager.default.contentsOfDirectory(atPath: featureFolder.path).sorted()
        flow.close()
        let cancelled = try await wait { results.count == 2 }
        if !cancelled {
            flow.features.assistant.stopAction("intake:quick-feature")
            _ = try await wait { results.count == 2 }
        }
        XCTAssertTrue(cancelled, "Closing the window must cancel the pending assistant request and notify the sheet")
        let cancelledCalls = await fixture.cancellationCount()
        XCTAssertEqual(cancelledCalls, 1)
        XCTAssertNotNil(window.requests.intake)
        XCTAssertEqual(tabs.opened, openBeforeClose)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: featureFolder.path).sorted(), featuresBeforeClose)
    }

    @MainActor func testRealFeatureFlowStartIssueOnLocalBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-issue-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) async throws -> String {
            let result = await GitHubClient.execute(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args,
                                                    in: root, git: true)
            guard result.status == 0 else { throw NSError(domain: "LocalGitFixture", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr]) }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["config", "core.hooksPath", "/dev/null"])
        _ = try await git(["commit", "--allow-empty", "-q", "-m", "initial"])
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        window.composition.gitClient.workingDirectory = root
        let assistant = FeatureFlowAssistantSpy(root: root)
        let flow = FeatureFlowCoordinator(project: window.project, assistants: assistant, tabs: window, requests: window.requests,
                                          layout: window.layout, chrome: window.chrome, gitClient: window.composition.gitClient,
                                          research: window.composition.research)
        defer { flow.close() }
        let comments = (0..<12).map { #"{"author":{"login":"user\#($0)"},"body":"comment \#($0)"}"# }.joined(separator: ",")
        let json = #"{"number":12,"title":"Fix the Crash on Save!","state":"OPEN","url":"https://example.invalid/12","body":"It crashes.","comments":[\#(comments)]}"#
        let issue = try JSONDecoder().decode(GHIssue.self, from: Data(json.utf8))
        let error = await flow.startIssueWithAI(issue)
        XCTAssertNil(error)
        let branch = try await git(["branch", "--show-current"])
        XCTAssertEqual(branch, "issue-12-fix-the-crash-on-save")
        let sent = try XCTUnwrap(assistant.sent.first)
        XCTAssertTrue(sent.submit)
        XCTAssertTrue(sent.prompt.contains("Fix the Crash on Save!"))
        XCTAssertTrue(sent.prompt.contains("It crashes."))
        XCTAssertTrue(sent.prompt.contains("You are on branch issue-12-fix-the-crash-on-save"))
        XCTAssertFalse(sent.prompt.contains("- user0:"))
        XCTAssertFalse(sent.prompt.contains("- user1:"))
        XCTAssertTrue(sent.prompt.contains("- user2: comment 2"))
        XCTAssertTrue(sent.prompt.contains("- user11: comment 11"))
        _ = try await git(["switch", "-q", "main"])
        let repeated = await flow.startIssueWithAI(issue)
        XCTAssertNil(repeated)
        let branches = try await git(["branch", "--list", "issue-12*"])
        XCTAssertEqual(branches.split(separator: "\n").count, 1)
        let reopened = try await git(["branch", "--show-current"])
        XCTAssertEqual(reopened, "issue-12-fix-the-crash-on-save")
        let bare = try JSONDecoder().decode(GHIssue.self, from: Data(#"{"number":3,"title":"!!!","state":"OPEN","url":"https://example.invalid/3","body":null,"comments":[]}"#.utf8))
        let bareError = await flow.startIssueWithAI(bare)
        XCTAssertNil(bareError)
        let bareBranch = try await git(["branch", "--show-current"])
        XCTAssertEqual(bareBranch, "issue-3")
        XCTAssertTrue(assistant.sent.last?.prompt.contains("(no description)") == true)
        let nonRepo = FileManager.default.temporaryDirectory.appendingPathComponent("feature-nonrepo-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepo) }
        let otherProject = ProjectContext(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("nonrepo-recent.json"))
        otherProject.fileTree.rootNode = FileNode(url: nonRepo, isDirectory: true)
        let otherAssistant = FeatureFlowAssistantSpy(root: nonRepo)
        let otherFlow = FeatureFlowCoordinator(project: otherProject, assistants: otherAssistant, tabs: window, requests: window.requests,
                                               layout: window.layout, chrome: window.chrome, gitClient: GitClient(),
                                               research: window.composition.research)
        defer { otherFlow.close(); otherProject.close() }
        let noRepository = await otherFlow.startIssueWithAI(issue)
        XCTAssertTrue(noRepository?.hasPrefix("Could not switch to issue-12-fix-the-crash-on-save:") == true)
        XCTAssertTrue(otherAssistant.sent.isEmpty)
        let blank = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("blank.json"))
        defer { blank.composition.close() }
        XCTAssertNil(blank.flow.projectRoot)
        let noFolder = await blank.flow.startIssueWithAI(issue)
        XCTAssertEqual(noFolder, "No folder open.")
    }

    @MainActor func testRealFeatureFlowAssistantHandoffs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-handoff-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "feature-handoff-host-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = ProjectContext(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"), settings: Settings(defaults))
        project.beginOpening(root)
        project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("window-recent.json"))
        defer { window.composition.close() }
        let assistant = FeatureFlowAssistantSpy(root: root)
        let flow = FeatureFlowCoordinator(project: project, assistants: assistant, tabs: window, requests: window.requests,
                                          layout: window.layout, chrome: window.chrome, gitClient: window.composition.gitClient,
                                          research: window.composition.research)
        defer { flow.close(); project.close() }
        _ = try ProjectWorkflowStore(projectRoot: root).save(.standard, expectedRevision: 0)
        flow.features.setup(root: root)
        let slug = try XCTUnwrap(flow.features.createFeature(title: "A feature", idea: "A fixture"))
        let folder = root.appendingPathComponent("docs/features/\(slug)")
        flow.implementWithAI(folder)
        XCTAssertEqual(window.requests.doneRequest, folder)
        XCTAssertTrue(assistant.sent.isEmpty)
        let before = try XCTUnwrap(flow.features.feature(slug)?.status)
        assistant.sends = false
        flow.startImplementation(folder, done: .standard)
        XCTAssertTrue(assistant.sent.isEmpty)
        XCTAssertEqual(flow.features.feature(slug)?.status, before)
        assistant.sends = true
        flow.startImplementation(root.appendingPathComponent("notes.md"), done: .standard)
        XCTAssertEqual(assistant.sent.count, 1)
        XCTAssertTrue(assistant.sent[0].submit)
        XCTAssertTrue(assistant.sent[0].prompt.contains("notes.md"))
        XCTAssertFalse(assistant.sent[0].prompt.contains("MarkView issue lifecycle"))
        XCTAssertEqual(flow.features.feature(slug)?.status, before)
        let evidenceURL = root.appendingPathComponent("test-lifecycle-events.jsonl")
        let evidence = LifecycleLog(testURL: evidenceURL)
        flow.features.testLifecycleLog = evidence
        flow.features.updateFeature(slug) { front, _ in front.set("status", "ready") }
        XCTAssertEqual(flow.features.feature(slug)?.status, "ready")
        flow.startImplementation(folder, done: .standard)
        XCTAssertEqual(assistant.sent.count, 2)
        let sentFeature = try XCTUnwrap(assistant.sent.last)
        XCTAssertTrue(sentFeature.submit)
        XCTAssertTrue(sentFeature.prompt.contains("docs/features/\(slug)"))
        XCTAssertTrue(sentFeature.prompt.contains("MarkView issue lifecycle for feature \(slug)"))
        XCTAssertEqual(flow.features.feature(slug)?.status, "implementing")
        XCTAssertEqual(flow.features.lifecycle.history(.feature, slug)?.changes.last?.actor.kind, .human)
        for _ in 0..<500 where evidence.events(project: root.standardizedFileURL.path, feature: slug).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let events = evidence.events(project: root.standardizedFileURL.path, feature: slug)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.stage, .workStarted)
        await evidence.drainTestWrites()
        let persisted = try String(contentsOf: evidenceURL, encoding: .utf8)
        let line = try XCTUnwrap(persisted.split(separator: "\n").first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recorded = try decoder.decode(LifecycleEvent.self, from: Data(line.utf8))
        XCTAssertEqual(recorded.feature, slug)
        XCTAssertEqual(recorded.project, root.standardizedFileURL.path)
        XCTAssertEqual(recorded.stage, .workStarted)
        XCTAssertTrue(recorded.note?.contains("Claude") == true)
        let singleFileProject = ProjectContext(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("single-recent.json"))
        singleFileProject.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let singleFileAssistant = FeatureFlowAssistantSpy(root: root)
        let singleFileRequests = WindowRequests()
        let singleFileFlow = FeatureFlowCoordinator(project: singleFileProject, assistants: singleFileAssistant, tabs: window,
                                                    requests: singleFileRequests, layout: window.layout, chrome: window.chrome,
                                                    gitClient: window.composition.gitClient, research: window.composition.research)
        defer { singleFileFlow.close(); singleFileProject.close() }
        singleFileFlow.implementWithAI(folder)
        XCTAssertNil(singleFileRequests.doneRequest)
        XCTAssertEqual(singleFileAssistant.sent.count, 1, "A single-file workspace uses the standard definition of done")

        let bug = try flow.features.createBug(BugReportDraft(title: "Broken", body: "A fixture", provenance: "Test"))
        let bugStatus = try XCTUnwrap(flow.features.bug(at: bug.url)?.status)
        let canStart = flow.features.lifecycle.canStartByHandoff(.bug, bug.id)
        let target = flow.features.lifecycle.startTarget(.bug, from: bugStatus, issue: bug.id)
        XCTAssertTrue(canStart, "Bug \(bug.id), stored status \(flow.features.lifecycle.storedStatus(.bug, bug.id) ?? "nil"), target \(target ?? "nil"), error \(flow.features.lastError ?? "none")")
        assistant.sends = false
        flow.fixBugWithAI(bug.url)
        XCTAssertEqual(flow.features.bug(at: bug.url)?.status, bugStatus)
        assistant.sends = true
        flow.fixBugWithAI(bug.url)
        XCTAssertEqual(assistant.sent.count, 3)
        let sentBug = try XCTUnwrap(assistant.sent.last)
        XCTAssertTrue(sentBug.prompt.contains(bug.url.lastPathComponent))
        XCTAssertTrue(sentBug.prompt.contains("MarkView issue lifecycle for bug \(bug.id)"))
        XCTAssertTrue(sentBug.submit)
        XCTAssertNotEqual(flow.features.bug(at: bug.url)?.status, bugStatus)
        XCTAssertEqual(flow.features.lifecycle.history(.bug, bug.id)?.changes.last?.actor.kind, .human)
        XCTAssertTrue(flow.features.updateBug(bug.url) { front, _ in front.set("status", "closed") })
        let beforeClosed = assistant.sent.count
        flow.fixBugWithAI(bug.url)
        XCTAssertEqual(assistant.sent.count, beforeClosed)
        XCTAssertTrue(flow.features.lastError?.contains("closed") == true)
        let otherTerminal = TerminalSession(directory: root, profile: .assistant(CLITool(rawValue: "codex")!))
        flow.fixBugWithAI(root.appendingPathComponent("loose.md"), in: otherTerminal)
        XCTAssertEqual(assistant.sent.count, beforeClosed + 1)
        XCTAssertTrue(assistant.sent.last?.terminal === otherTerminal)

        let result = await flow.fixInPullRequest(14, prompt: "Please fix.", work: .parts)
        XCTAssertNil(result)
        XCTAssertEqual(assistant.sent.last?.prompt, ParallelWork.parts.ask("Please fix.\n\nNote: this is pull request #14; its branch may not be the one checked out here.",
                                                                          tool: CLITool(rawValue: "claude")))
        let plain = await flow.fixInPullRequest(nil, prompt: "Review it.", work: .items)
        XCTAssertNil(plain)
        XCTAssertEqual(assistant.sent.last?.prompt, ParallelWork.items.ask("Review it.", tool: CLITool(rawValue: "claude")))
        XCTAssertTrue(assistant.sent.last?.prompt.contains("use a workflow") == true)
    }

    @MainActor func testRealFeatureFlowLocalBranches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-git-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) async throws -> String {
            let result = await GitHubClient.execute(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args,
                                                    in: root, git: true)
            guard result.status == 0 else { throw NSError(domain: "LocalGitFixture", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr]) }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["config", "core.hooksPath", "/dev/null"])
        let file = root.appendingPathComponent("tracked.md")
        try "main\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["add", "tracked.md"])
        _ = try await git(["commit", "-q", "-m", "initial"])
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        window.composition.gitClient.workingDirectory = root
        await window.tabs.openTextFile(file)
        let createError = await window.flow.createBranch("topic", from: "main")
        XCTAssertNil(createError)
        let topic = try await git(["branch", "--show-current"])
        XCTAssertEqual(topic, "topic")
        try "topic\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["add", "tracked.md"])
        _ = try await git(["commit", "-q", "-m", "topic"])
        let switchError = await window.flow.switchBranch("main")
        XCTAssertNil(switchError)
        for _ in 0..<300 where window.tabs.activeTab?.content != "main\n" { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(window.tabs.activeTab?.content, "main\n")
        let main = try await git(["branch", "--show-current"])
        XCTAssertEqual(main, "main")
        let againError = await window.flow.switchBranch("topic")
        XCTAssertNil(againError)
        for _ in 0..<300 where window.tabs.activeTab?.content != "topic\n" { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(window.tabs.activeTab?.content, "topic\n")
        let duplicateError = await window.flow.createBranch("topic", from: "main")
        XCTAssertNotNil(duplicateError)
        try "modified\n".write(to: file, atomically: true, encoding: .utf8)
        let checkoutError = await window.flow.checkoutPullRequest(6)
        XCTAssertTrue(checkoutError?.contains("uncommitted changes") == true)
        XCTAssertTrue(checkoutError?.contains("#6") == true)
        let current = try await git(["branch", "--show-current"])
        XCTAssertEqual(current, "topic")
        let blank = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("blank.json"))
        defer { blank.composition.close() }
        let noFolder = await blank.flow.checkoutPullRequest(1)
        XCTAssertEqual(noFolder, "No folder open.")
    }

    @MainActor func testRealFeatureFlowGitHubTabs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-github-tabs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blank = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("blank.json"))
        defer { blank.composition.close() }
        blank.flow.openGitHubTab(.issue(number: 4, repo: "o/r", title: "#4"))
        XCTAssertTrue(blank.tabs.openTabs.isEmpty)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        window.chrome.showCenter = false
        let run = GitHubItem.run(id: 3, repo: "o/r", title: "run")
        window.flow.openGitHubTab(run)
        XCTAssertEqual(window.layout.gitSection, .actions)
        XCTAssertEqual(window.layout.workSection, .git)
        XCTAssertEqual(window.layout.workspaceArea, .files)
        XCTAssertTrue(window.chrome.showCenter)
        guard case .github(let openedRun)? = window.tabs.activeTab?.kind else { return XCTFail("Run tab was not opened") }
        XCTAssertEqual(openedRun, run)
        let issue = GitHubItem.issue(number: 4, repo: "o/r", title: "#4")
        window.flow.openGitHubTab(issue)
        XCTAssertEqual(window.layout.gitSection, .issues)
        guard case .github(let openedIssue)? = window.tabs.activeTab?.kind else { return XCTFail("Issue tab was not opened") }
        XCTAssertEqual(openedIssue, issue)
        let pull = GitHubItem.pullRequest(number: 5, repo: "o/r", title: "#5")
        window.flow.openGitHubTab(pull)
        XCTAssertEqual(window.layout.gitSection, .pullRequests)
        guard case .github(let openedPull)? = window.tabs.activeTab?.kind else { return XCTFail("Pull request tab was not opened") }
        XCTAssertEqual(openedPull, pull)
        let count = window.tabs.openTabs.count
        window.flow.openGitHubTab(run)
        XCTAssertEqual(window.tabs.openTabs.count, count)
        guard case .github(let selected)? = window.tabs.activeTab?.kind else { return XCTFail("Run tab was not selected") }
        XCTAssertEqual(selected, run)
    }

    @MainActor func testRealFeatureFlowResumeHandoff() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("feature-resume-host-" + UUID().uuidString)
        let root = base.appendingPathComponent("project", isDirectory: true).resolvingSymlinksInPath()
        let outside = base.appendingPathComponent("outside.md")
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = docs.appendingPathComponent("a.md")
        try "inside".write(to: file, atomically: true, encoding: .utf8)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("link.md"), withDestinationURL: outside)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        let settings = Settings.standard
        let previousFolder = settings.stored(Setting.lastFolder)
        let previousProjects = settings.stored(Setting.recentProjects)
        window.project.beginOpening(root)
        if let previousFolder { settings.set(previousFolder, for: Setting.lastFolder) } else { settings.remove(Setting.lastFolder) }
        if let previousProjects { settings.set(previousProjects, for: Setting.recentProjects) } else { settings.remove(Setting.recentProjects) }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let flow = window.flow
        XCTAssertEqual(flow.projectRoot?.standardizedFileURL.path, root.standardizedFileURL.path)
        flow.resumeHandoff(slug: "f1", title: "No project", linkedFiles: ["docs/a.md"])
        XCTAssertNil(window.requests.handoffResume)
        flow.features.setup(root: root)
        flow.resumeHandoff(slug: "f1", title: "Cancelled", linkedFiles: ["docs/a.md"])
        flow.cancelWork()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(window.requests.handoffResume)
        XCTAssertTrue(window.tabs.openTabs.isEmpty)
        let missing = ["docs/gone.md", "docs/folder", "/etc/hosts", "../escape.md", "docs/link.md", "docs//a.md", ""]
        flow.resumeHandoff(slug: "f1", title: "Feature one", linkedFiles: ["docs/a.md"] + missing)
        for _ in 0..<200 where window.requests.handoffResume == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let resume = try XCTUnwrap(window.requests.handoffResume)
        XCTAssertEqual(resume.slug, "f1")
        XCTAssertEqual(resume.title, "Feature one")
        XCTAssertEqual(resume.missingFiles, missing)
        for _ in 0..<200 where window.tabs.activeTab?.url != file { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(window.tabs.openTabs.filter(\.isFileBacked).map(\.url), [file])
        XCTAssertEqual(window.layout.workspaceArea, .files)
        window.requests.handoffResume = nil
        flow.resumeHandoff(slug: "f2", title: "Old project", linkedFiles: ["docs/a.md"])
        let other = base.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        flow.features.setup(root: other)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(window.requests.handoffResume, "A result from the previous folder is dropped")
    }

    @MainActor func testRealFeatureFlowIntakeAndPresentation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("feature-flow-host-" + UUID().uuidString)
        let root = base.appendingPathComponent("project", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let doc = docs.appendingPathComponent("spec.md")
        let outside = base.appendingPathComponent("outside.md")
        let created = root.appendingPathComponent("docs/features/new-idea/overview.md")
        try FileManager.default.createDirectory(at: created.deletingLastPathComponent(), withIntermediateDirectories: true)
        for url in [doc, outside, created] { try "fixture".write(to: url, atomically: true, encoding: .utf8) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        let settings = Settings.standard
        let previousFolder = settings.stored(Setting.lastFolder)
        let previousProjects = settings.stored(Setting.recentProjects)
        window.project.beginOpening(root)
        if let previousFolder { settings.set(previousFolder, for: Setting.lastFolder) } else { settings.remove(Setting.lastFolder) }
        if let previousProjects { settings.set(previousProjects, for: Setting.recentProjects) } else { settings.remove(Setting.recentProjects) }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let flow = window.flow
        flow.startIntake(.bug, fromIssue: 7)
        XCTAssertEqual(window.requests.intake?.kind, .bug)
        XCTAssertEqual(window.requests.intake?.linkedIssue, 7)
        XCTAssertEqual(window.requests.intake?.loadIssue, 7)
        let pull = try JSONDecoder().decode(GHPullRequest.self, from: Data(#"{"number":9,"title":"Fix it","headRefName":"fix","baseRefName":"main","state":"OPEN","url":"https://example.invalid/9"}"#.utf8))
        flow.startIntake(.feature, fromPullRequest: pull)
        XCTAssertEqual(window.requests.intake?.loadPullRequest, 9)
        XCTAssertEqual(window.requests.intake?.text, "Pull request #9: Fix it (fix → main)")
        flow.startIntake(.feature, fromDocument: doc)
        XCTAssertEqual(window.requests.intake?.attachments, [doc])
        XCTAssertEqual(window.requests.intake?.text, "Build a feature from the document docs/spec.md (attached).")
        flow.startIntake(.research, fromDocument: doc)
        XCTAssertEqual(window.requests.intake?.targets, [doc])
        XCTAssertEqual(window.requests.intake?.attachments, [])
        flow.startIntake(.understand, fromDocument: doc)
        XCTAssertEqual(window.requests.intake?.attachments, [])
        XCTAssertNil(window.requests.intake?.targets)
        XCTAssertTrue(window.requests.intake?.text.contains("docs/spec.md") == true)
        flow.startResearch(fromFolder: docs)
        XCTAssertEqual(window.requests.intake?.targets, [docs])
        XCTAssertTrue(window.requests.intake?.text.hasPrefix("Review the documents in docs and its subfolders") == true)
        flow.newResearch()
        XCTAssertEqual(window.requests.intake?.kind, .research)
        XCTAssertNil(window.requests.intake?.targets)
        await window.tabs.openTextFile(doc)
        XCTAssertEqual(flow.researchDefaultTargets, [doc])
        await window.tabs.openTextFile(outside)
        XCTAssertTrue(flow.researchDefaultTargets.isEmpty)
        window.toolTabs.open(.git)
        XCTAssertTrue(flow.researchDefaultTargets.isEmpty, "A tool tab is not a research document")
        flow.showCreatedProject(root, specification: "new-idea")
        XCTAssertEqual(flow.features.activeSlug, "new-idea")
        XCTAssertEqual(window.layout.leftPanel, "issues")
        XCTAssertEqual(window.layout.issuesFeature, "new-idea")
        XCTAssertEqual(window.layout.featureStage, .explore)
        XCTAssertEqual(window.layout.navigatorTab, .feature)
        XCTAssertTrue(window.chrome.showTOC)
        XCTAssertTrue(window.chrome.showFileTree)
        for _ in 0..<200 where window.tabs.activeTab?.url != created { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(window.tabs.activeTab?.url, created)
        let prototypeOverview = root.appendingPathComponent("prototype-overview.md")
        try "prototype".write(to: prototypeOverview, atomically: true, encoding: .utf8)
        flow.featureWritten("from-prototype", overview: prototypeOverview)
        XCTAssertEqual(flow.features.activeSlug, "from-prototype")
        XCTAssertEqual(window.layout.featureStage, .build)
        for _ in 0..<200 where window.tabs.activeTab?.url != prototypeOverview { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(window.tabs.activeTab?.url, prototypeOverview)
        flow.intakeFinished(.quickFeature, outcome: FeatureAssistant.IntakeOutcome(file: nil, feature: "quick"))
        XCTAssertEqual(window.layout.featureStage, .build)
        XCTAssertEqual(flow.features.activeSlug, "quick")
        flow.intakeFinished(.feature, outcome: FeatureAssistant.IntakeOutcome(file: nil, feature: "full"))
        XCTAssertEqual(window.layout.featureStage, .explore)
        XCTAssertEqual(flow.features.activeSlug, "full")
        let bugFile = root.appendingPathComponent("bug.md")
        try "bug".write(to: bugFile, atomically: true, encoding: .utf8)
        window.chrome.showTOC = false
        flow.intakeFinished(.bug, outcome: FeatureAssistant.IntakeOutcome(file: bugFile))
        XCTAssertTrue(window.chrome.showTOC)
        XCTAssertEqual(window.layout.navigatorTab, .feature)
        for _ in 0..<200 where window.tabs.activeTab?.url != bugFile { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(window.tabs.activeTab?.url, bugFile)
        flow.showFeatureContext("ctx")
        XCTAssertEqual(flow.features.activeSlug, "ctx")
        XCTAssertEqual(window.layout.issuesFeature, "ctx")
        XCTAssertTrue(window.chrome.showTOC)
        XCTAssertTrue(window.chrome.terminalVisible)
        flow.showFeatureContext(nil)
        XCTAssertEqual(window.layout.issuesFeature, "ctx")
    }

    @MainActor func testFixBugAndBatchBuildPromptForActualReceivingTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-recipient-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = try XCTUnwrap(CLITool(rawValue: "claude"))
        let codex = try XCTUnwrap(CLITool(rawValue: "codex"))
        let copilot = try XCTUnwrap(CLITool(rawValue: "copilot"))
        let originalBackend = AIAssistantPreferences.backend(project: root)
        defer { AssistantChoice(project: root).setTool(originalBackend.rawValue) }

        @MainActor
        final class RoutingAssistantSpy: AssistantProviding, AssistantPrompting {
            var target: TerminalSession
            var sends = true
            var assistantIsBusy = false
            private(set) var sent: [(prompt: String, submit: Bool, terminal: TerminalSession)] = []
            var currentAssistant: CLICompletion.Assistant? { nil }
            var sessions: [TerminalSession] { [target] }
            var shownID: UUID? { target.id }
            init(target: TerminalSession) { self.target = target }
            func liveModelReported(_ model: String, terminalID: UUID) {}
            func openAITerminal(_ profile: TerminalProfile, resuming: Bool, model: String?) -> TerminalSession? { nil }
            func showAIConsole() {}
            func sendToAssistant(submit: Bool, to terminal: TerminalSession?, promptFor: (TerminalSession) -> String?) -> TerminalSession? {
                guard sends else { return nil }
                let chosen = terminal ?? target
                guard let prompt = promptFor(chosen) else { return nil }
                sent.append((prompt, submit, chosen))
                return chosen
            }
        }

        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.beginOpening(root)
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        _ = try ProjectWorkflowStore(projectRoot: root).save(.standard, expectedRevision: 0)

        let claudeTerminal = TerminalSession(directory: root, profile: .assistant(claude))
        let codexTerminal = TerminalSession(directory: root, profile: .assistant(codex))
        let copilotTerminal = TerminalSession(directory: root, profile: .assistant(copilot))
        let spy = RoutingAssistantSpy(target: codexTerminal)
        let flow = FeatureFlowCoordinator(project: window.project, assistants: spy, tabs: window, requests: window.requests,
                                          layout: window.layout, chrome: window.chrome, gitClient: window.composition.gitClient,
                                          research: window.composition.research)
        defer { flow.close() }
        flow.features.setup(root: root)

        // Case 1: Project default is Claude (fixesBugsAsGoal == true), but normal routing picks an open Codex terminal.
        // Neither single nor batch Fix with AI may send Claude's `/goal` syntax into Codex.
        // The request to run independent work in parallel is written for the receiving assistant too: a single bug is a task with
        // parts, a basket a list of items.
        func request(_ work: ParallelWork, _ tool: CLITool) throws -> String { try XCTUnwrap(work.request(for: tool.provider)) }
        AssistantChoice(project: root).setTool(claude.rawValue)
        spy.target = codexTerminal
        let bug1 = try flow.features.createBug(BugReportDraft(title: "Single codex recipient", body: "Detail", provenance: "Test"))
        flow.fixBugWithAI(bug1.url)
        let sentSingleCodex = try XCTUnwrap(spy.sent.last)
        XCTAssertTrue(sentSingleCodex.submit)
        XCTAssertTrue(sentSingleCodex.terminal === codexTerminal)
        XCTAssertFalse(sentSingleCodex.prompt.hasPrefix("/goal "), "Codex recipient must not receive Claude /goal syntax")
        XCTAssertTrue(sentSingleCodex.prompt.hasPrefix("Fix the bug described in "))
        XCTAssertTrue(sentSingleCodex.prompt.contains(try request(.parts, codex)))
        XCTAssertFalse(sentSingleCodex.prompt.contains(try request(.parts, claude)))
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, bug1.id), "fixing")

        let bug2 = try flow.features.createBug(BugReportDraft(title: "Batch codex one", body: "Detail", provenance: "Test"))
        let bug3 = try flow.features.createBug(BugReportDraft(title: "Batch codex two", body: "Detail", provenance: "Test"))
        flow.bugBatch.toggle(try XCTUnwrap(flow.features.bug(at: bug2.url)))
        flow.bugBatch.toggle(try XCTUnwrap(flow.features.bug(at: bug3.url)))
        flow.fixBasketWithAI()
        let sentBatchCodex = try XCTUnwrap(spy.sent.last)
        XCTAssertTrue(sentBatchCodex.submit)
        XCTAssertTrue(sentBatchCodex.terminal === codexTerminal)
        XCTAssertFalse(sentBatchCodex.prompt.hasPrefix("/goal "), "Batch Codex recipient must not receive Claude /goal syntax")
        XCTAssertTrue(sentBatchCodex.prompt.hasPrefix("Fix this batch of 2 bug reports"))
        XCTAssertTrue(sentBatchCodex.prompt.contains(try request(.items, codex)))
        XCTAssertFalse(sentBatchCodex.prompt.contains("in turn"))
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, bug2.id), "fixing")
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, bug3.id), "fixing")

        // Case 2: Project default is Copilot (fixesBugsAsGoal == false), but normal routing picks an open Claude terminal.
        // Both single and batch Fix with AI must use Claude's `/goal` syntax matching the actual recipient.
        AssistantChoice(project: root).setTool(copilot.rawValue)
        spy.target = claudeTerminal
        let bug4 = try flow.features.createBug(BugReportDraft(title: "Single claude recipient", body: "Detail", provenance: "Test"))
        flow.fixBugWithAI(bug4.url)
        let sentSingleClaude = try XCTUnwrap(spy.sent.last)
        XCTAssertTrue(sentSingleClaude.terminal === claudeTerminal)
        XCTAssertTrue(sentSingleClaude.prompt.hasPrefix("/goal fix the bug described in "))
        // One line: the request is part of the goal, not a second prompt.
        XCTAssertTrue(sentSingleClaude.prompt.components(separatedBy: "\n\n")[0].contains(try request(.parts, claude)))
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, bug4.id), "fixing")

        let bug5 = try flow.features.createBug(BugReportDraft(title: "Batch claude one", body: "Detail", provenance: "Test"))
        let bug6 = try flow.features.createBug(BugReportDraft(title: "Batch claude two", body: "Detail", provenance: "Test"))
        flow.bugBatch.toggle(try XCTUnwrap(flow.features.bug(at: bug5.url)))
        flow.bugBatch.toggle(try XCTUnwrap(flow.features.bug(at: bug6.url)))
        // Failed handoff leaves bugs unmarked and basket intact.
        spy.sends = false
        flow.fixBasketWithAI()
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, bug5.id), "open")
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, bug6.id), "open")
        XCTAssertEqual(flow.bugBatch.eligible.count, 2)

        spy.sends = true
        flow.fixBasketWithAI()
        let sentBatchClaude = try XCTUnwrap(spy.sent.last)
        XCTAssertTrue(sentBatchClaude.terminal === claudeTerminal)
        XCTAssertTrue(sentBatchClaude.prompt.hasPrefix("/goal fix this batch of 2 bugs"))
        XCTAssertTrue(sentBatchClaude.prompt.contains(try request(.items, claude)))
        XCTAssertTrue(sentBatchClaude.prompt.contains("use a workflow"))
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, bug5.id), "fixing")
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, bug6.id), "fixing")
        XCTAssertTrue(flow.bugBatch.basket.isEmpty)

        // Explicit terminal override also beats both project default and shown terminal.
        let bug7 = try flow.features.createBug(BugReportDraft(title: "Explicit copilot", body: "Detail", provenance: "Test"))
        flow.fixBugWithAI(bug7.url, in: copilotTerminal)
        let sentExplicit = try XCTUnwrap(spy.sent.last)
        XCTAssertTrue(sentExplicit.terminal === copilotTerminal)
        XCTAssertFalse(sentExplicit.prompt.hasPrefix("/goal "))
        XCTAssertTrue(sentExplicit.prompt.contains(try request(.parts, copilot)))
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, bug7.id), "fixing")
    }

}
