import Combine
import Foundation

// The feature flow of a window (AR-14 step 9): the shipping `FeatureFlowCoordinator` over real temporary folders and git repositories,
// the real panels, batch rules, prompts and GitHub client, with stand-in stores, terminals and tabs (`FeatureFlowCoordinatorStubs.swift`)
// that record what it asks of them. Nothing is shown, typed or sent to GitHub: `gh` is never run.

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

/// Wait, with the main run loop turning, until `condition` holds.
@MainActor
func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

nonisolated(unsafe) var temporaryFolders: [URL] = []

func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("feature-flow-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    temporaryFolders.append(url)
    return url
}

/// The panels' own defaults: one suite for the whole run, emptied each time a window is made, so the checks leave one small file at most.
let defaultsSuite = "feature-flow-coordinator-tests-panels"

func defaults() -> UserDefaults {
    let suite = UserDefaults(suiteName: defaultsSuite)!
    suite.removePersistentDomain(forName: defaultsSuite)
    return suite
}

let claude = CLITool(rawValue: "claude")!

/// One window's worth of collaborators around a coordinator.
@MainActor
struct Rig {
    let folder: URL
    let project = StubProject()
    let assistants: StubAssistants
    let tabs = StubTabs()
    let requests = WindowRequests()
    let layout = PanelLayout(defaults: defaults())
    let chrome = WindowChrome(defaults: defaults())
    let gitClient = GitClient()
    let research = ResearchMapController()
    let flow: FeatureFlowCoordinator

    init(folder: URL = temporaryFolder(), open: Bool = true) {
        self.folder = folder
        assistants = StubAssistants(directory: folder, tool: claude)
        if open { project.root = folder }
        flow = FeatureFlowCoordinator(project: project, assistants: assistants, tabs: tabs, requests: requests, layout: layout,
                                      chrome: chrome, gitClient: gitClient, research: research)
    }
}

func git(_ arguments: [String], in folder: URL) async -> GitHubClient.Output {
    await GitHubClient.execute(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments, in: folder, git: true)
}

/// A repository with one commit holding `tracked.txt`.
func repository() async -> URL {
    let folder = temporaryFolder()
    _ = await git(["init", "-q", "-b", "main"], in: folder)
    try? "one\n".write(to: folder.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    _ = await git(["add", "tracked.txt"], in: folder)
    _ = await git(["commit", "-q", "-m", "first"], in: folder)
    return folder
}

func currentBranch(_ folder: URL) async -> String {
    await git(["rev-parse", "--abbrev-ref", "HEAD"], in: folder).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }

func issue(_ number: Int, title: String, body: String?, comments: Int = 0) -> GHIssue {
    let items = (0..<comments).map { #"{"author":{"login":"user\#($0)"},"body":"comment \#($0)"}"# }.joined(separator: ",")
    let text = body.map { "\"" + $0.replacingOccurrences(of: "\n", with: "\\n") + "\"" }
    return decode(#"{"number":\#(number),"title":"\#(title)","state":"OPEN","url":"https://example.invalid/\#(number)","body":\#(text ?? "null"),"comments":[\#(items)]}"#)
}

// MARK: Intake

@MainActor
func intake() {
    print("-- intake")
    let rig = Rig()
    rig.flow.startIntake(.bug, fromIssue: 7)
    check(rig.requests.intake?.kind == .bug && rig.requests.intake?.linkedIssue == 7 && rig.requests.intake?.loadIssue == 7,
          "a bug from issue #7 opens the intake sheet at once, linked, and the sheet loads the issue")

    let pull: GHPullRequest = decode(#"{"number":9,"title":"Fix it","headRefName":"fix","baseRefName":"main","state":"OPEN","url":"https://example.invalid/9"}"#)
    rig.flow.startIntake(.feature, fromPullRequest: pull)
    check(rig.requests.intake?.loadPullRequest == 9 && rig.requests.intake?.text == "Pull request #9: Fix it (fix → main)",
          "a feature from a pull request carries its title and branches and loads the description")

    let doc = rig.folder.appendingPathComponent("docs/spec.md")
    rig.flow.startIntake(.feature, fromDocument: doc)
    check(rig.requests.intake?.attachments == [doc] && rig.requests.intake?.text == "Build a feature from the document docs/spec.md (attached).",
          "a feature from a document attaches it and names it by its project path")
    rig.flow.startIntake(.research, fromDocument: doc)
    check(rig.requests.intake?.targets == [doc] && rig.requests.intake?.attachments.isEmpty == true, "a research from a document makes it the first target")
    rig.flow.startIntake(.understand, fromDocument: doc)
    check(rig.requests.intake?.attachments.isEmpty == true && rig.requests.intake?.targets == nil
          && rig.requests.intake?.text.contains("docs/spec.md") == true, "an understand request only names the document")

    let docs = rig.folder.appendingPathComponent("docs")
    rig.flow.startResearch(fromFolder: docs)
    check(rig.requests.intake?.kind == .research && rig.requests.intake?.targets == [docs]
          && rig.requests.intake?.text.hasPrefix("Review the documents in docs and its subfolders") == true, "a research of a folder targets the folder")
    rig.flow.newResearch()
    check(rig.requests.intake?.kind == .research && rig.requests.intake?.targets == nil, "New Research opens the sheet for the open document")

    rig.tabs.activeTab = OpenTab(url: doc)
    check(rig.flow.researchDefaultTargets == [doc], "a research starts with the open document when it is in the project")
    rig.tabs.activeTab = OpenTab(url: URL(fileURLWithPath: "/elsewhere/a.md"))
    check(rig.flow.researchDefaultTargets.isEmpty, "a document outside the project is not a default target")
    rig.tabs.activeTab = OpenTab(url: doc, isFileBacked: false)
    check(rig.flow.researchDefaultTargets.isEmpty, "a tab with no file is not a default target")
}

// MARK: Showing a feature

@MainActor
func showing() {
    print("-- showing a feature")
    let rig = Rig()
    let features = rig.flow.features
    let created = rig.folder.appendingPathComponent("docs/features/new-idea/overview.md")
    rig.flow.showCreatedProject(rig.folder, specification: "new-idea")
    check(features.activeSlug == "new-idea" && rig.layout.leftPanel == "issues" && rig.layout.issuesFeature == "new-idea"
          && rig.layout.featureStage == .explore && rig.layout.navigatorTab == .feature && rig.chrome.showTOC && rig.chrome.showFileTree,
          "a created project shows its specification in the Issues list at Explore")
    check(rig.tabs.opened == [created], "and puts the overview in the editor")

    rig.tabs.opened = []
    let before = rig.project.treeRefreshes
    rig.flow.featureWritten("from-prototype", overview: rig.folder.appendingPathComponent("o.md"))
    check(rig.layout.featureStage == .build && features.activeSlug == "from-prototype", "a feature the prototype wrote opens at Build")
    check(rig.project.treeRefreshes == before + 1 && rig.tabs.opened.count == 1, "the file tree reads the folder again and the overview opens")

    rig.flow.intakeFinished(.quickFeature, outcome: FeatureAssistant.IntakeOutcome(file: rig.folder.appendingPathComponent("q.md"), feature: "quick"))
    check(rig.layout.featureStage == .build && features.activeSlug == "quick", "a quick feature opens at Build")
    rig.flow.intakeFinished(.feature, outcome: FeatureAssistant.IntakeOutcome(file: nil, feature: "full"))
    check(rig.layout.featureStage == .explore && features.activeSlug == "full", "a feature opens at Explore")

    let rig2 = Rig()
    rig2.chrome.showTOC = false
    rig2.flow.intakeFinished(.bug, outcome: FeatureAssistant.IntakeOutcome(file: rig2.folder.appendingPathComponent("bug.md")))
    check(rig2.chrome.showTOC && rig2.layout.navigatorTab == .feature && rig2.tabs.opened.count == 1 && rig2.flow.features.activeSlug == nil,
          "a bug report opens in the editor and its questions in the Feature tab")

    let rig3 = Rig()
    rig3.chrome.terminalVisible = false
    rig3.flow.showFeatureContext("ctx")
    check(rig3.flow.features.activeSlug == "ctx" && rig3.layout.issuesFeature == "ctx" && rig3.chrome.showTOC && rig3.chrome.terminalVisible,
          "the feature context keeps the task beside its documents with the terminal")
    rig3.flow.showFeatureContext(nil)
    check(rig3.layout.issuesFeature == "ctx", "no slug leaves the selected task alone")
}

// MARK: Actions on selected text

@MainActor
func selectionActions() async {
    print("-- actions on selected text")
    let rig = Rig()
    let doc = rig.folder.appendingPathComponent("docs/features/f1/overview.md")
    rig.flow.features.setup(root: rig.folder)
    rig.flow.features.features = [Feature(slug: "f1", folder: rig.folder.appendingPathComponent("docs/features/f1"))]
    rig.tabs.activeTab = OpenTab(url: doc)
    rig.flow.runFeatureAction("ask", text: "selected", question: "why?")
    check(await waitUntil { !rig.flow.features.assistant.performed.isEmpty }, "an action on selected text reaches the assistant")
    let performed = rig.flow.features.assistant.performed.first
    check(performed?.action == .ask && performed?.selection == "selected" && performed?.question == "why?" && performed?.feature == "f1",
          "with the selection, the question and the feature the document belongs to")
    check(performed?.document == "docs/features/f1/overview.md" && rig.layout.navigatorTab == .feature && rig.chrome.showTOC,
          "the document's project path is given and the Feature tab shows the answer")
    rig.flow.runFeatureAction("nonsense", text: "x", question: "")
    await settle(0.1)
    check(rig.flow.features.assistant.performed.count == 1, "an unknown action is ignored")
    rig.flow.runFeatureAction("comment", text: "passage", question: "tighten this")
    check(rig.research.jobs.comments.count == 1 && rig.research.jobs.comments[0].file == doc && rig.research.jobs.comments[0].passage == "passage",
          "a comment on a document goes to the research jobs, which revise that section")
}

// MARK: Hand-offs to the assistant

@MainActor
func implementation() {
    print("-- implement with AI")
    let rig = Rig()
    rig.project.aiProject = rig.folder
    let url = rig.folder.appendingPathComponent("docs/features/f1")
    rig.flow.implementWithAI(url)
    check(rig.requests.doneRequest == url && rig.assistants.sent.isEmpty, "in a project the person sees the definition of done first; nothing is sent")

    let alone = Rig()
    alone.project.aiProject = nil
    let folder = alone.folder.appendingPathComponent("docs/features/f1")
    alone.flow.features.features = [Feature(slug: "f1", folder: folder)]
    alone.flow.implementWithAI(folder)
    check(alone.requests.doneRequest == nil && alone.assistants.sent.count == 1, "without a project folder the standard definition of done is used at once")
    check(alone.assistants.sent.first?.prompt.contains("LIFECYCLE-BLOCK(f1)") == true && alone.assistants.sent.first?.submit == true,
          "the prompt carries the lifecycle block of the feature and is submitted")
    check(alone.flow.features.implementing.map(\.slug) == ["f1"] && alone.flow.features.implementing.first?.handoff == claude.displayName,
          "after the prompt went out the feature is marked implementing, by the tool that got it")
    check(alone.flow.features.implementationStarts.map(\.slug) == ["f1"] && alone.flow.features.implementationStarts.first?.directory == alone.folder,
          "and the implementation start is recorded with the terminal's folder")

    let refused = Rig()
    let target = refused.folder.appendingPathComponent("docs/features/f2")
    refused.flow.features.features = [Feature(slug: "f2", folder: target)]
    refused.assistants.sends = false
    refused.flow.startImplementation(target, done: .standard)
    check(refused.flow.features.implementing.isEmpty && refused.flow.features.implementationStarts.isEmpty,
          "a hand-off that failed leaves the feature alone")

    let plain = Rig()
    plain.flow.startImplementation(plain.folder.appendingPathComponent("notes.md"), done: .standard)
    check(plain.assistants.sent.count == 1 && plain.flow.features.implementing.isEmpty && !plain.assistants.sent[0].prompt.contains("LIFECYCLE-BLOCK"),
          "a document that is no feature is handed over with nothing to mark")
}

@MainActor
func bugFix() {
    print("-- fix a bug with AI")
    let rig = Rig()
    let report = rig.folder.appendingPathComponent("docs/bugs/BUG-001.md")
    rig.flow.features.bugs = [BugReport(url: report, key: "BUG-001")]
    rig.flow.fixBugWithAI(report)
    check(rig.assistants.sent.count == 1 && rig.assistants.sent[0].prompt.contains("docs/bugs/BUG-001.md")
          && rig.assistants.sent[0].prompt.contains("LIFECYCLE-BLOCK(BUG-001)"), "the report and the lifecycle block go to the assistant")
    check(rig.flow.features.lifecycle.started.count == 1 && rig.flow.features.lifecycle.started[0].key == "BUG-001"
          && rig.flow.features.lifecycle.started[0].actor == .human("Boris") && rig.flow.features.lifecycle.started[0].surface,
          "after the prompt went out the report is marked fixing, as the person's hand-off")

    let failed = Rig()
    failed.flow.features.bugs = [BugReport(url: report, key: "BUG-001")]
    failed.assistants.sends = false
    failed.flow.fixBugWithAI(report)
    check(failed.flow.features.lifecycle.started.isEmpty, "a hand-off that failed leaves the report open")

    let closed = Rig()
    closed.flow.features.bugs = [BugReport(url: report, key: "BUG-001")]
    closed.flow.features.lifecycle.notStartable = ["BUG-001"]
    closed.flow.fixBugWithAI(report)
    check(closed.assistants.sent.isEmpty && closed.flow.features.lastError?.contains("BUG-001 is fixed") == true,
          "a bug the lifecycle does not let start is not handed over, and the person is told why")

    let other = Rig()
    let terminal = TerminalSession(directory: other.folder, profile: .assistant(CLITool(rawValue: "codex")!))
    other.flow.fixBugWithAI(other.folder.appendingPathComponent("docs/bugs/loose.md"), in: terminal)
    check(other.assistants.sent.count == 1 && other.assistants.sent[0].terminal === terminal, "an agent that names a terminal gets the prompt there")
}

@MainActor
func bugBasket() {
    print("-- the bug basket")
    func bugs(_ keys: String...) -> [BasketBug] {
        keys.map { BasketBug(path: "docs/bugs/\($0).md", key: $0, title: "Title \($0)", status: "open") }
    }
    let rig = Rig()
    rig.flow.features.setup(root: rig.folder)
    rig.flow.bugBatch.eligible = bugs("BUG-1", "BUG-2", "BUG-3")
    rig.flow.fixBasketWithAI()
    let sent = rig.assistants.sent.first?.prompt ?? ""
    check(rig.assistants.sent.count == 1 && sent.contains("BUG-1") && sent.contains("BUG-3"), "the open bugs of the basket go out in one prompt")
    check(rig.flow.features.lifecycle.started.map(\.key) == ["BUG-1", "BUG-2", "BUG-3"] && rig.flow.features.lifecycle.started.allSatisfy { !$0.surface },
          "each bug in the prompt is marked fixing, one record each, without a message of its own")
    check(rig.flow.bugBatch.clears == 1 && rig.flow.bugBatch.notice == nil, "the basket is emptied when every bug started")

    let left = Rig()
    left.flow.features.setup(root: left.folder)
    left.flow.features.lifecycle.notStartable = ["BUG-2"]
    left.flow.bugBatch.eligible = bugs("BUG-1", "BUG-2", "BUG-3")
    left.flow.fixBasketWithAI()
    let leftPrompt = left.assistants.sent.first?.prompt ?? ""
    check(leftPrompt.contains("BUG-1") && leftPrompt.contains("BUG-3") && !leftPrompt.contains("Title BUG-2"), "a bug the lifecycle does not let start is left out of the prompt")
    check(left.flow.features.lifecycle.started.map(\.key) == ["BUG-1", "BUG-3"] && left.flow.bugBatch.notice?.contains("BUG-2") == true,
          "only the bugs in the prompt are marked, and the person is told about the one left out")

    let notSent = Rig()
    notSent.flow.features.setup(root: notSent.folder)
    notSent.assistants.sends = false
    notSent.flow.bugBatch.eligible = bugs("BUG-1", "BUG-2")
    notSent.flow.fixBasketWithAI()
    check(notSent.flow.features.lifecycle.started.isEmpty && notSent.flow.bugBatch.clears == 0 && notSent.flow.bugBatch.notice != nil,
          "a prompt that could not be sent marks nothing and keeps the basket (BUG-032)")

    let one = Rig()
    one.flow.features.setup(root: one.folder)
    one.flow.bugBatch.eligible = bugs("BUG-1")
    one.flow.fixBasketWithAI()
    check(one.assistants.sent.isEmpty && one.flow.bugBatch.reconciles == 1, "one bug is not a batch; the basket is checked against the reports first")

    let busy = Rig()
    busy.flow.features.setup(root: busy.folder)
    busy.assistants.assistantIsBusy = true
    busy.flow.bugBatch.eligible = bugs("BUG-1", "BUG-2")
    busy.flow.fixBasketWithAI()
    check(busy.assistants.sent.isEmpty, "a batch is not started while the assistant is working")
}

@MainActor
func conflicts() {
    print("-- conflicts")
    let rig = Rig()
    rig.flow.resolveConflictsWithAI()
    check(rig.assistants.sent.isEmpty, "with no conflict nothing is sent")

    rig.gitClient.branch = "feature"
    rig.gitClient.operationInProgress = "merge"
    rig.gitClient.repoStatus = GitRepoStatus.parse("u UU N... 100644 100644 100644 100644 aaaa bbbb cccc src/a.swift\0u UU N... 100644 100644 100644 100644 aaaa bbbb cccc src/b.swift\0")
    rig.assistants.assistantIsBusy = true
    rig.flow.resolveConflictsWithAI()
    check(rig.assistants.sent.isEmpty && rig.gitClient.lastError?.contains("still working") == true, "a busy assistant is told to wait, and the person is told so")

    rig.assistants.assistantIsBusy = false
    rig.flow.resolveConflictsWithAI()
    let prompt = rig.assistants.sent.first?.prompt ?? ""
    check(prompt.contains("src/a.swift") && prompt.contains("src/b.swift") && prompt.contains("merge") && prompt.contains("feature"),
          "the conflicted files, the operation and the branch go to the assistant")
}

// MARK: Resuming a hand-off

@MainActor
func resuming() async {
    print("-- resume a hand-off")
    let rig = Rig()
    let root = rig.folder
    try? FileManager.default.createDirectory(at: root.appendingPathComponent("docs/folder"), withIntermediateDirectories: true)
    try? "a".write(to: root.appendingPathComponent("docs/a.md"), atomically: true, encoding: .utf8)
    let outside = temporaryFolder()
    try? "o".write(to: outside.appendingPathComponent("o.md"), atomically: true, encoding: .utf8)
    try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("docs/link.md"), withDestinationURL: outside.appendingPathComponent("o.md"))
    rig.flow.features.setup(root: root)
    rig.flow.resumeHandoff(slug: "f1", title: "Feature one",
                           linkedFiles: ["docs/a.md", "docs/gone.md", "docs/folder", "/etc/hosts", "../escape.md", "docs/link.md", "docs//a.md", ""])
    check(await waitUntil { rig.requests.handoffResume != nil }, "the offer to resume appears")
    let resume = rig.requests.handoffResume
    check(resume?.slug == "f1" && resume?.title == "Feature one", "it names the feature")
    check(rig.tabs.opened.map(\.path) == [root.appendingPathComponent("docs/a.md").path], "only the linked file that is a regular file inside the project opens")
    check(resume?.missingFiles == ["docs/gone.md", "docs/folder", "/etc/hosts", "../escape.md", "docs/link.md", "docs//a.md", ""],
          "a missing file, a folder, an absolute path, a `..` path, a link out of the project and an empty segment all count as missing")
    check(rig.layout.workspaceArea == .files, "the files area comes forward")

    // The folder changes while the disk is read: the answer is dropped.
    let late = Rig()
    late.flow.features.setup(root: late.folder)
    late.flow.resumeHandoff(slug: "f1", title: "t", linkedFiles: ["a.md"])
    late.flow.cancelWork()
    await settle(0.3)
    check(late.requests.handoffResume == nil && late.tabs.opened.isEmpty, "opening another folder cancels a resume that is still reading the disk")
    let moved = Rig()
    moved.flow.features.setup(root: moved.folder)
    moved.flow.resumeHandoff(slug: "f1", title: "t", linkedFiles: ["a.md"])
    moved.flow.features.setup(root: temporaryFolder())
    await settle(0.3)
    check(moved.requests.handoffResume == nil, "a resume for a folder that is no longer the open one is dropped")
    let nothing = Rig()
    nothing.flow.resumeHandoff(slug: "f1", title: "t", linkedFiles: ["a.md"])
    await settle(0.1)
    check(nothing.requests.handoffResume == nil, "without a feature folder there is nothing to resume")
}

// MARK: GitHub

@MainActor
func gitHubTabs() async {
    print("-- GitHub tabs and issues")
    let rig = Rig()
    rig.chrome.showCenter = false
    rig.flow.openGitHubTab(.run(id: 3, repo: "o/r", title: "run"))
    check(rig.layout.gitSection == .actions && rig.layout.workSection == .git && rig.layout.workspaceArea == .files && rig.chrome.showCenter,
          "a run opens in the Actions section of the Git area")
    check(rig.tabs.githubTabs.count == 1 && rig.tabs.githubTabs[0].root == rig.folder, "and in a tab of the project")
    rig.flow.openGitHubTab(.issue(number: 4, repo: "o/r", title: "#4"))
    check(rig.layout.gitSection == .issues, "an issue opens in Issues")
    rig.flow.openGitHubTab(.pullRequest(number: 5, repo: "o/r", title: "#5"))
    check(rig.layout.gitSection == .pullRequests, "a pull request opens in Pull Requests")

    let closed = Rig(open: false)
    closed.flow.openGitHubTab(.issue(number: 4, repo: "o/r", title: "#4"))
    check(closed.tabs.githubTabs.isEmpty, "with no folder there is no GitHub tab")

    let repo = GitHubRepo(slug: "o/r", remote: "origin", isUpstream: false)
    let linked = Rig()
    linked.flow.gitHub.reposFound = [repo]
    linked.flow.gitHub.setup(root: linked.folder)
    linked.flow.openGitHubIssue(12)
    check(linked.tabs.githubTabs.first?.item == .issue(number: 12, repo: "o/r", title: "#12"), "with the integration on, an issue opens in its tab")

    // Without the integration the page opens in the browser; the lookup of the remote is the window's work and stops with it.
    let browser = Rig(folder: await repository())
    browser.flow.openGitHubIssue(12)
    browser.flow.reset()
    await settle(0.6)
    check(browser.tabs.githubTabs.isEmpty, "with the integration off no tab opens (the page goes to the browser)")
}

@MainActor
func gitHubCheckout() async {
    print("-- check out a pull request")
    let clean = Rig(folder: await repository())
    clean.gitClient.workingDirectory = clean.folder
    let error = await clean.flow.checkoutPullRequest(5)
    check(error == nil && clean.flow.gitHub.performed == ["Checkout #5"], "a clean working tree is checked out through GitHub")
    check(clean.gitClient.refreshes == 1 && clean.project.treeRefreshes == 1, "and the Git status and the file tree are read again")

    let dirty = Rig(folder: await repository())
    dirty.gitClient.workingDirectory = dirty.folder
    try? "edited\n".write(to: dirty.folder.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    let refused = await dirty.flow.checkoutPullRequest(6)
    check(refused?.contains("uncommitted changes") == true && refused?.contains("#6") == true && dirty.flow.gitHub.performed.isEmpty,
          "a tracked change refuses the checkout and nothing is run")

    _ = await git(["checkout", "--", "tracked.txt"], in: dirty.folder)
    try? "new\n".write(to: dirty.folder.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
    check(await dirty.flow.checkoutPullRequest(7) == nil, "an untracked file does not block a checkout")

    let none = Rig(open: false)
    check(await none.flow.checkoutPullRequest(1) == "No folder open.", "without a folder there is nothing to check out")

    let failing = Rig(folder: await repository())
    failing.flow.gitHub.performError = "Checkout #8: nope"
    check(await failing.flow.checkoutPullRequest(8) == "Checkout #8: nope", "the error GitHub gives is returned to show")
}

@MainActor
func gitHubStartIssue() async {
    print("-- start an issue with AI")
    let rig = Rig(folder: await repository())
    rig.flow.gitHub.reposFound = [GitHubRepo(slug: "o/r", remote: "origin", isUpstream: false)]
    rig.flow.gitHub.setup(root: rig.folder)
    let fix = issue(12, title: "Fix the Crash on Save!", body: "It crashes.\nSteps: save.", comments: 12)
    let error = await rig.flow.startIssueWithAI(fix)
    check(error == nil && rig.gitClient.refreshes == 1, "an issue starts and the Git status is read again")
    check(await currentBranch(rig.folder) == "issue-12-fix-the-crash-on-save", "a branch named for the issue and its first six words is made and checked out")
    let prompt = rig.assistants.sent.first?.prompt ?? ""
    check(prompt.hasPrefix("Work on GitHub issue #12 of o/r: Fix the Crash on Save!") && prompt.contains("It crashes.\nSteps: save.")
          && prompt.contains("You are on branch issue-12-fix-the-crash-on-save"), "the issue's text and the branch go to the assistant")
    check(!prompt.contains("- user0:") && !prompt.contains("- user1:") && prompt.contains("- user2: comment 2") && prompt.contains("- user11: comment 11"),
          "only the last ten comments go along")

    _ = await git(["switch", "-q", "main"], in: rig.folder)
    let again = await rig.flow.startIssueWithAI(fix)
    let onBranch = await currentBranch(rig.folder)
    check(again == nil && onBranch == "issue-12-fix-the-crash-on-save", "starting it again switches to the branch that exists")
    let branches = await git(["branch", "--list", "issue-12*"], in: rig.folder).stdout.split(separator: "\n")
    check(branches.count == 1, "and makes no second one")

    let bare = Rig(folder: await repository())
    let empty = await bare.flow.startIssueWithAI(issue(3, title: "!!!", body: nil))
    let bareBranch = await currentBranch(bare.folder)
    check(empty == nil && bareBranch == "issue-3", "an issue whose title has no letters gets a branch of its number")
    check(bare.assistants.sent.first?.prompt.contains("(no description)") == true, "an issue with no text says so")

    let notRepo = Rig()
    let failed = await notRepo.flow.startIssueWithAI(issue(1, title: "t", body: nil))
    check(failed?.hasPrefix("Could not switch to issue-1-t:") == true && notRepo.assistants.sent.isEmpty, "a folder that is no repository gives the reason and sends nothing")
    check(await Rig(open: false).flow.startIssueWithAI(issue(1, title: "t", body: nil)) == "No folder open.", "without a folder there is nothing to start")
}

@MainActor
func gitHubFixes() async {
    print("-- fixes with AI from GitHub")
    let rig = Rig()
    let withoutGitHub = await rig.flow.fixInPullRequest(14, prompt: "Please fix.")
    check(withoutGitHub == nil && rig.assistants.sent.first?.prompt == "Please fix.\n\nNote: this is pull request #14; its branch may not be the one checked out here.",
          "without the integration the request goes out with a note that the branch may differ")
    let plain = Rig()
    _ = await plain.flow.fixInPullRequest(nil, prompt: "Review it.")
    check(plain.assistants.sent.first?.prompt == "Review it.", "a request about no pull request goes out as it is")

    let run: GHRun = decode(#"{"databaseId":1,"number":1,"displayTitle":"CI","workflowName":"CI","status":"completed","conclusion":"failure","headBranch":"other","event":"push","createdAt":"2026-01-01T00:00:00Z","url":"https://example.invalid/1"}"#)
    let model = GitHubRunModel()
    model.run = run
    model.loadDelay = 50_000_000
    let runRig = Rig()
    runRig.gitClient.branch = "main"
    runRig.flow.fixRunWithAI(model)
    check(await waitUntil { !runRig.assistants.sent.isEmpty }, "the failed run's logs go to the assistant once they are loaded")
    let prompt = runRig.assistants.sent.first?.prompt ?? ""
    check(prompt.hasPrefix("The run failed in step Build.") && prompt.contains("the run was on branch other; the working copy is on main")
          && prompt.hasSuffix("Find the cause in this repository and fix it."), "with a note when the working copy is on another branch")

    let stopped = Rig()
    model.loadDelay = 400_000_000
    stopped.flow.fixRunWithAI(model)
    stopped.flow.close()
    await settle(0.7)
    check(stopped.assistants.sent.isEmpty, "closing the window cancels the fix that is still loading logs")
}

@MainActor
func branches() async {
    print("-- branches")
    let rig = Rig()
    rig.gitClient.branchError = nil
    let error = await rig.flow.switchBranch("topic")
    check(error == nil && rig.gitClient.switched == ["topic"], "a branch is switched through the Git client")
    let reloaded = await waitUntil { rig.tabs.reloads == [true] }
    check(rig.project.treeRefreshes == 1 && reloaded, "the file tree and every open tab take the new branch's files")
    let created = await rig.flow.createBranch("new", from: "main")
    check(created == nil && rig.gitClient.created.first?.name == "new" && rig.gitClient.created.first?.base == "main", "a branch is created from its base")
    rig.gitClient.branchError = "already exists"
    check(await rig.flow.switchBranch("x") == "already exists", "the Git client's error is returned to show")
}

// MARK: Setup, the GitHub setting and the window's life

@MainActor
func lifecycle() async {
    print("-- setup, reset and the Settings switch")
    UserDefaults.standard.removeObject(forKey: GitHubSettings.enabledKey)
    let repo = GitHubRepo(slug: "o/r", remote: "origin", isUpstream: false)
    let rig = Rig()
    rig.flow.gitHub.reposFound = [repo]
    let a = rig.folder
    rig.flow.setUp(at: a)
    check(rig.flow.features.setups == [a] && rig.flow.bugBatch.resets == 1, "a folder sets the features up and starts the basket empty")
    check(rig.flow.features.assistant.project === rig.project, "the feature assistant reads the window's project")
    check(rig.flow.gitHub.setups.isEmpty && rig.flow.gitHub.resets == 1, "GitHub stays off until the Settings switch turns it on")
    rig.flow.setUp(at: a)
    check(rig.flow.bugBatch.resets == 1, "the same folder again keeps the basket")
    check(rig.flow.features.assistant.gitHubClient() == nil, "the assistant has no GitHub client while the repository is not known")
    check(rig.flow.gitHub.onPoll != nil && rig.gitClient.onBranch != nil, "the lifecycle poll and the branch of the Git client are wired to GitHub")

    let before = rig.flow.gitHub.resets
    UserDefaults.standard.set(true, forKey: GitHubSettings.enabledKey)
    check(await waitUntil { rig.flow.gitHub.setups == [a] }, "turning the switch on sets GitHub up for the open folder")
    check(rig.flow.features.assistant.gitHubClient()?.repo.slug == "o/r", "and the assistant gets its client")
    rig.gitClient.onBranch?("topic")
    check(rig.flow.gitHub.branches == ["topic"], "the branch the Git client reports reaches GitHub")

    UserDefaults.standard.set(false, forKey: GitHubSettings.enabledKey)
    check(await waitUntil { rig.flow.gitHub.resets == before + 1 }, "turning it off resets GitHub")

    rig.flow.close()
    let resets = rig.flow.gitHub.resets
    UserDefaults.standard.set(true, forKey: GitHubSettings.enabledKey)
    await settle(0.3)
    check(rig.flow.gitHub.setups == [a] && rig.flow.gitHub.resets == resets, "a window that closed no longer follows the Settings switch")

    rig.flow.reset()
    check(rig.flow.features.resets == 1 && rig.flow.gitHub.resets == resets + 1 && rig.flow.features.root == nil,
          "closing the folder resets both stores")
    UserDefaults.standard.removeObject(forKey: GitHubSettings.enabledKey)

    let other = Rig()
    other.flow.setUp(at: other.folder)
    other.flow.cancelWork()
    other.flow.setUp(at: temporaryFolder())
    check(other.flow.bugBatch.resets == 2, "another folder empties the basket")
}

@MainActor
func activation() async {
    print("-- activate GitHub after a publish")
    UserDefaults.standard.removeObject(forKey: GitHubSettings.enabledKey)
    let repo = GitHubRepo(slug: "o/r", remote: "origin", isUpstream: false)
    let rig = Rig()
    rig.flow.gitHub.reposFound = [repo]
    check(!GitHubSettings.enabled, "the integration is off before")
    let result = await rig.flow.activateGitHub(expecting: "O/R", in: rig.folder)
    check(result == nil && GitHubSettings.enabled, "it is turned on for every window and the repository is found, whatever its case")
    check(rig.flow.gitHub.setups == [rig.folder] && rig.flow.gitHub.resets >= 1, "after GitHub looked at the folder again")
    UserDefaults.standard.removeObject(forKey: GitHubSettings.enabledKey)
}

@main
@MainActor
enum FeatureFlowCoordinatorChecks {
    static func main() async {
        intake()
        showing()
        await selectionActions()
        implementation()
        bugFix()
        bugBasket()
        conflicts()
        await resuming()
        await gitHubTabs()
        await gitHubCheckout()
        await gitHubStartIssue()
        await gitHubFixes()
        await branches()
        await lifecycle()
        await activation()
        for folder in temporaryFolders { try? FileManager.default.removeItem(at: folder) }
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        UserDefaults.standard.removeObject(forKey: GitHubSettings.enabledKey)
        print("Feature flow coordinator summary: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
