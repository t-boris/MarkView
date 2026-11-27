import AppKit
import Combine
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What the feature flow needs of the window's tabs (`AR-14` step 9): the tab the person looks at, a file shown, the tab of a GitHub item,
/// and the open tabs taking what changed on disk. `WorkspaceManager` conforms.
@MainActor
protocol FeatureFlowTabs: AnyObject {
    /// The tab the person is looking at; nil on the Welcome tab.
    var activeTab: OpenTab? { get }
    /// Shows `url` in a tab of the window.
    func openFile(_ url: URL)
    /// Shows the tab of a GitHub issue, pull request or workflow run of the project at `root`, or returns to it.
    func showGitHubTab(_ item: GitHubItem, root: URL)
    /// Open tabs take the text of files that changed on disk (after a branch switch, or what an assistant wrote).
    func reloadChangedOpenFiles(all: Bool) async
}

/// The feature flow of one window (`AR-14` step 9): the feature workspaces and the folder's GitHub repository that feed it, the intake
/// that starts a feature, a bug or a research, "Implement with AI" and "Fix with AI" with the hand-off that marks the issue, the batch of
/// bugs, and what GitHub offers the AI (an issue to start on, a failed run, a pull request to check out). It owns the stores of that flow
/// (`features`, `gitHub`, `bugBatch`) and what is wired between them and the folder's Git client. The status of an issue changes only
/// through the lifecycle of `features` (`IssueLifecycleCoordinator`); this object decides when a hand-off counts as a start.
///
/// The open project is read through `ProjectProviding`, the assistants are reached through `AssistantProviding` and `AssistantPrompting` and the tabs through
/// `FeatureFlowTabs`; the window's panels and sheet requests are the window's own state objects. Work it starts is in its own `TaskBag`:
/// cancelled when the folder switches (`reset`) and when the window closes (`close`).
@MainActor
final class FeatureFlowCoordinator: ObservableObject {
    /// Feature workspaces of the folder (docs/features/<slug>/…).
    let features: FeatureStore
    /// Pull requests, issues and Actions of the folder's GitHub repository.
    let gitHub: GitHubStore
    /// This window's bug basket for batch Fix with AI (issue #31); a new folder empties it.
    private(set) lazy var bugBatch = BugBatch(store: features)

    private let project: any ProjectProviding
    private let assistants: any AssistantProviding & AssistantPrompting
    private let tabs: any FeatureFlowTabs
    private let requests: WindowRequests
    private let layout: PanelLayout
    private let chrome: WindowChrome
    private let gitClient: GitClient
    private let research: ResearchMapController
    /// The coordinator's own one-off background work (`AR-19`).
    private let tasks = TaskBag()

    /// Folder the GitHub integration works in (folders only, never a single file).
    private var gitHubRoot: URL?
    /// Watches the Settings switch (every window follows it).
    private var gitHubSettingObserver: SettingsObserver?
    /// What follows the folder's repository: the Git client's branch reaches GitHub, and each poll reaches the lifecycle of the features.
    private var branchFollower: AnyCancellable?
    private var pollFollower: AnyCancellable?

    init(project: any ProjectProviding, assistants: any AssistantProviding & AssistantPrompting, tabs: any FeatureFlowTabs,
         requests: WindowRequests, layout: PanelLayout, chrome: WindowChrome, gitClient: GitClient, research: ResearchMapController) {
        self.project = project
        self.assistants = assistants
        self.tabs = tabs
        self.requests = requests
        self.layout = layout
        self.chrome = chrome
        self.gitClient = gitClient
        self.research = research
        let gitHub = GitHubStore()
        self.gitHub = gitHub
        features = FeatureStore(gitHub: gitHub)
    }

    // MARK: - Folder and window

    /// Feature workspaces of a folder, and the folder's GitHub repository when the integration is turned on in Settings.
    func setUp(at root: URL) {
        setUpGitHub(at: root)
        let newFolder = features.root != root
        features.setup(root: root)
        if newFolder { bugBatch.reset() }
        features.assistant.project = project
    }

    /// Find the folder's GitHub repository and follow the current branch's CI, only when the integration is turned on in Settings
    /// (MarkView stays a plain viewer otherwise).
    private func setUpGitHub(at root: URL) {
        gitHubRoot = root
        branchFollower = gitClient.branchReports.sink { [weak self] branch in self?.gitHub.branchChanged(branch) }
        pollFollower = gitHub.polls.sink { [weak self] client in self?.features.syncLifecycle(with: client) }
        if gitHubSettingObserver == nil {
            // The Settings switch is one for every window: a change of its value looks again at it.
            gitHubSettingObserver = SettingsObserver([Setting.gitHubEnabled.erased]) { [weak self] in
                MainActor.assumeIsolated { self?.gitHubSettingChanged() }
            }
        }
        gitHubSettingChanged()
    }

    /// Start or stop the integration for the open folder, as the Settings switch says.
    private func gitHubSettingChanged() {
        if GitHubSettings.enabled, let root = gitHubRoot {
            gitHub.setup(root: root)
            if !gitClient.branch.isEmpty { gitHub.branchChanged(gitClient.branch) }
        } else {
            gitHub.reset()
        }
    }

    /// The folder closes: the work started for it stops and the stores start over.
    func reset() {
        tasks.cancelAll()
        gitHubRoot = nil
        gitHub.reset()
        features.reset()
    }

    /// Another folder opens in the window: work started for the old one stops. The stores are set up for the new folder by `setUp`.
    func cancelWork() {
        tasks.cancelAll()
    }

    /// The window closes: nothing started here keeps running and the Settings switch is no longer watched.
    func close() {
        gitHubSettingObserver = nil
        reset()
    }

    // MARK: - Showing a feature

    /// Shows `url` in a tab of the window: the document that a feature, a bug, an object or an issue row points at.
    func open(_ url: URL) {
        tabs.openFile(url)
    }

    /// Keep the selected task visible beside its documents in the right column.
    func showFeatureContext(_ slug: String?) {
        if let slug {
            features.activeSlug = slug
            layout.issuesFeature = slug
        }
        layout.navigatorTab = .feature
        chrome.showTOC = true
        chrome.terminalVisible = true
    }

    /// Opens feature `slug` in the Feature panel at `stage`, with its documents beside it.
    func showFeature(_ slug: String, stage: FeatureStage) {
        features.activeSlug = slug
        layout.leftPanel = "issues"
        layout.issuesFeature = slug
        layout.featureStage = stage
        chrome.showTOC = true
        chrome.showFileTree = true
        layout.navigatorTab = .feature
    }

    /// The project a new-project flow created is open: show it with its specification in front, the Issues list on it and the overview
    /// in the editor (DEC-023).
    func showCreatedProject(_ root: URL, specification slug: String) {
        features.activeSlug = slug
        layout.leftPanel = "issues"
        layout.issuesFeature = slug
        layout.featureStage = .explore
        chrome.showTOC = true
        chrome.showFileTree = true
        layout.navigatorTab = .feature
        tabs.openFile(root.appendingPathComponent(FeatureStore.folderName).appendingPathComponent(slug).appendingPathComponent("overview.md"))
    }

    /// A feature was written by the app itself (the prototype hand-off): open it at its Build stage, ready for "Implement with AI", with
    /// its overview in the editor. Nothing starts by itself.
    func featureWritten(_ slug: String, overview: URL) {
        showFeature(slug, stage: .build)
        project.refreshFileTree()
        tabs.openFile(overview)
    }

    /// An intake finished: open what it made, and for a feature show its workspace.
    func intakeFinished(_ kind: IntakeKind, outcome: FeatureAssistant.IntakeOutcome) {
        if let slug = outcome.feature {
            showFeature(slug, stage: kind == .quickFeature ? .build : .explore)
        } else if kind == .bug {
            // The report opens in the editor; its questions are answered in the Feature tab.
            chrome.showTOC = true
            layout.navigatorTab = .feature
        }
        project.refreshFileTree()
        if let file = outcome.file { tabs.openFile(file) }
    }

    /// A contextual action on text selected in the editor: the answer (or the created
    /// requirement / decision / question) appears in the right panel's Feature tab.
    func runFeatureAction(_ name: String, text: String, question: String) {
        // A comment on a research document: the AI revises that section (DEC-017).
        if name == "comment" {
            guard let url = tabs.activeTab?.url, tabs.activeTab?.isFileBacked == true, project.root != nil else { return }
            research.jobs.comment(on: text, comment: question, in: url)
            return
        }
        guard let action = FeatureAction(rawValue: name) else { return }
        guard project.root != nil else { return }
        let url = tabs.activeTab?.url
        let located = url.flatMap { features.locate($0) }
        let slug = located?.feature.slug ?? features.active?.slug
        let document = url.map { features.relativePath($0) }
        chrome.showTOC = true
        layout.navigatorTab = .feature
        tasks.store(Task { [weak self] in
            await self?.features.assistant.perform(action, selection: text, document: document, question: question, feature: slug)
        }, for: "featureAction:" + UUID().uuidString)
    }

    /// The specification hand-off the window offers to resume: its linked files that are still in the project open beside it.
    func resumeHandoff(slug: String, title: String, linkedFiles: [String]) {
        guard let root = features.root else { return }
        tasks.store(Task { [weak self] in
            let checked = await Self.checkLinkedFiles(linkedFiles, under: root)
            guard let self, !Task.isCancelled, self.features.root == root else { return }
            self.requests.handoffResume = HandoffResume(slug: slug, title: title,
                                                        linkedFiles: linkedFiles, missingFiles: checked.missing)
            for url in checked.available { self.tabs.openFile(url) }
            self.layout.workspaceArea = .files
        }, for: "resumeHandoff:" + slug)
    }

    /// Which of a hand-off's linked files are regular files inside `root` (a link that resolves outside it, an absolute path or a
    /// `..` segment counts as missing). Reads the disk off the main actor.
    private nonisolated static func checkLinkedFiles(_ linkedFiles: [String], under root: URL) async -> (available: [URL], missing: [String]) {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var available: [URL] = []
        var missing: [String] = []
        for path in linkedFiles {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                missing.append(path)
                continue
            }
            let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(base),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                missing.append(path)
                continue
            }
            available.append(url)
        }
        return (available, missing)
    }

    // MARK: - Intake

    /// "New Feature / New Bug from #n": the issue's text and comments as the material, linked.
    func startIntake(_ kind: IntakeKind, fromIssue number: Int) {
        // The sheet opens at once and loads the issue itself (with a spinner).
        requests.intake = IntakeRequest(kind: kind, linkedIssue: number, loadIssue: number)
    }

    /// "New … from this pull request": its description as the material (a new issue is filed).
    func startIntake(_ kind: IntakeKind, fromPullRequest pr: GHPullRequest) {
        requests.intake = IntakeRequest(kind: kind, text: "Pull request #\(pr.number): \(pr.title) (\(pr.headRefName) → \(pr.baseRefName))",
                                        loadPullRequest: pr.number)
    }

    /// "New … from this document": the document is the material (attached, so the AI reads it whole).
    func startIntake(_ kind: IntakeKind, fromDocument url: URL) {
        let path = project.relativePath(of: url)
        let lead: String
        switch kind {
        case .feature, .quickFeature: lead = "Build a feature from the document \(path) (attached)."
        case .bug: lead = "The document \(path) (attached) describes a problem to analyze as a bug."
        case .understand: lead = "What implements \(path) in this project, and how do the documented parts work in the code?"
        case .research: lead = "Review \(path): "
        }
        switch kind {
        case .understand: requests.intake = IntakeRequest(kind: kind, text: lead)
        case .research: requests.intake = IntakeRequest(kind: kind, text: lead, targets: [url])
        default: requests.intake = IntakeRequest(kind: kind, text: lead, attachments: [url])
        }
    }

    /// New Research (replaces the Deep Research AI tool, DEC-010): the intake sheet, with the open document as its first target.
    func newResearch() {
        requests.intake = IntakeRequest(kind: .research)
    }

    func startResearch(fromFolder folder: URL) {
        requests.intake = IntakeRequest(kind: .research, text: "Review the documents in \(project.relativePath(of: folder)) and its subfolders: ", targets: [folder])
    }

    /// The sheet's "Create" for a feature or a bug: the assistant makes it from `input`, then the window shows what it made and the sheet
    /// closes (`intakeFinished`). One at a time per window; closing the folder ends it. `finished` is told once, with why nothing was
    /// made, or with nil when something was made or the work ended with the folder.
    func submitIntake(_ kind: IntakeKind, from input: String, attachments: [URL], linkedIssue: Int?, commentOnIssue: Bool,
                      finished: @escaping @MainActor (String?) -> Void) {
        guard !tasks.contains(key: "intake") else {
            finished("A new feature or bug is already being made — wait for it to finish.")
            return
        }
        tasks.store(Task { [weak self] in
            guard let self else { return }
            let assistant = self.features.assistant
            let outcome: FeatureAssistant.IntakeOutcome?
            switch kind {
            case .feature: outcome = await assistant.newFeature(from: input, attachments: attachments, linkedIssue: linkedIssue)
            case .quickFeature: outcome = await assistant.newQuickFeature(from: input, attachments: attachments, linkedIssue: linkedIssue)
            case .bug: outcome = await assistant.newBug(from: input, attachments: attachments, linkedIssue: linkedIssue, commentOnIssue: commentOnIssue)
            case .understand, .research: outcome = nil
            }
            guard !Task.isCancelled else { return finished(nil) }
            guard let outcome else { return finished(assistant.error ?? "The assistant did not answer.") }
            self.requests.intake = nil
            self.intakeFinished(kind, outcome: outcome)
            finished(nil)
        }, for: "intake")
    }

    /// The open folder, for the sheets that suggest paths in it; nil while nothing is open.
    var projectRoot: URL? { project.root }

    /// Whether the assistant's terminal is working: a batch of bugs is not handed to it then. Read when the view draws; the terminal's
    /// activity is not observed.
    var assistantIsBusy: Bool { assistants.assistantIsBusy }

    /// Documents a new research starts with (DEC-009): the open document when it is a file in the folder.
    var researchDefaultTargets: [URL] {
        guard let root = project.root, let tab = tabs.activeTab, tab.isFileBacked,
              ResearchJobs.relative(tab.url, to: root) != nil else { return [] }
        return [tab.url]
    }

    // MARK: - Hand-offs to the assistant

    /// Implement with AI: in a project the person first sees the definition of done for this run (and may change it); without a project
    /// folder the standard one is used at once.
    func implementWithAI(_ url: URL) {
        if project.aiProject != nil { requests.doneRequest = url } else { startImplementation(url, done: .standard) }
    }

    /// What the Definition of Done sheet needs to recommend a mode (REQ-001): the feature's plan issues and approved requirements, and
    /// the delivery rules of its process. nil for a document that is not a feature folder.
    func launchOptions(for url: URL) -> ImplementationLaunchOptions? {
        guard let feature = feature(at: url) else { return nil }
        let approved = feature.list(.requirement).filter { $0.status == "approved" }.count
        return ImplementationLaunchOptions(specification: .init(planIssues: feature.planIssues.map(\.id), approvedRequirements: approved),
                                           rules: features.lifecycle.deliveryRules(.feature, feature.slug))
    }

    /// The feature a managed Cockpit run implements, with the checklist the person reviewed and where it disagrees with the project's
    /// rules (REQ-001, REQ-004), and the goal its plan is written for.
    func cockpitLaunch(for url: URL, done: DefinitionOfDone) -> (feature: CockpitFeatureContext, goal: String)? {
        guard let feature = feature(at: url) else { return nil }
        let rules = features.lifecycle.deliveryRules(.feature, feature.slug)
        let path = project.relativePath(of: feature.folder)
        let context = CockpitFeatureContext(slug: feature.slug, title: feature.title, folder: path, branch: CockpitFeatureContext.branch(for: feature.slug),
                                            done: done, mandatory: ImplementationDeliveryRules.mandatory(rules: rules),
                                            conflicts: ImplementationDeliveryRules.conflicts(done: done, rules: rules))
        return (context, "Implement what \(path) specifies and verify the implementation against the specification.")
    }

    private func feature(at url: URL) -> Feature? {
        let target = url.standardizedFileURL.path
        return features.features.first { $0.folder.standardizedFileURL.path == target } ?? features.locate(url)?.feature
    }

    /// Hand a document to the AI to implement, establishing a goal in the receiving assistant. The goal carries the definition of done.
    /// The feature is recorded as "implementation started" with the CLI that got it.
    func startImplementation(_ url: URL, done: DefinitionOfDone, in terminal: TerminalSession? = nil) {
        let path = project.relativePath(of: url)
        let target = url.standardizedFileURL.path
        let slug = features.features.first(where: { $0.folder.standardizedFileURL.path == target })?.slug
            ?? features.locate(url)?.feature.slug
        let block = slug.map { features.lifecycle.handoffBlock(.feature, [$0]) } ?? ""
        guard let session = assistants.sendToAssistant(submit: true, to: terminal, promptFor: { session in
            guard let tool = session.profile.tool else { return nil }
            let prompt = ParallelWork.parts.ask(HandoffPrompt.feature(path, tool: tool, done: done), tool: tool)
            return block.isEmpty ? prompt : prompt + "\n\n" + block
        }) else { return }
        guard let slug else { return }
        // Handed to the assistant: the feature is being implemented (BUG-008). The hand-off that went out is the start
        // evidence; a hand-off that failed above left the status alone.
        features.markImplementing(slug, handoff: session.profile.tool?.displayName ?? "AI assistant")
        if let tool = session.profile.tool {
            features.recordImplementationStarted(slug, tool: tool, directory: session.directory, runningSince: session.runningSince)
        }
    }

    /// Hand the conflicted files to the assistant (Git tab → Conflicts → Resolve with AI). It resolves and stages them; committing,
    /// pushing and aborting stay with the person.
    func resolveConflictsWithAI() {
        let files = gitClient.repoStatus.entries(in: .conflicts).map(\.path)
        guard !files.isEmpty else { return }
        guard !assistants.assistantIsBusy else {
            gitClient.lastError = "The assistant is still working. Resolve the conflicts with it when it has finished."
            return
        }
        let prompt = ConflictPrompt.make(files: files, operation: gitClient.operationInProgress, branch: gitClient.branch)
        assistants.sendToAssistant(prompt, submit: true, work: files.count > 1 ? .items : .parts)
    }

    /// Hand a bug report to the assistant in the Terminal tab to fix; the report is marked `fixing`.
    /// `terminal`: the one to fix it in (an agent driving the window names it); else the usual choice.
    func fixBugWithAI(_ url: URL, in terminal: TerminalSession? = nil) {
        let path = project.relativePath(of: url)
        let key = features.bug(at: url)?.key
        // A bug the lifecycle does not let start (already fixed or closed) is not handed over: nothing could mark it.
        if let key, !features.lifecycle.canStartByHandoff(.bug, key) {
            features.lastError = "\(key) is \(features.lifecycle.storedStatus(.bug, key) ?? "not open") and cannot be handed to the assistant to fix. Reopen it first."
            return
        }
        let block = key.map { features.lifecycle.handoffBlock(.bug, [$0]) } ?? ""
        // Build instructions for the actual receiving terminal after routing picks it, and mark the report
        // fixing only after the prompt went out: a hand-off that failed leaves it open (REQ-003, REQ-006).
        guard let session = assistants.sendToAssistant(submit: true, to: terminal, promptFor: { receiving in
            let base = ParallelWork.parts.ask(HandoffPrompt.bug(path, tool: receiving.profile.tool), tool: receiving.profile.tool)
            return block.isEmpty ? base : base + "\n\n" + block
        }), let key else { return }
        features.lifecycle.startByHandoff(.bug, key, tool: session.profile.tool?.displayName ?? "AI assistant", actor: .human(features.lifecycleActor))
    }

    /// Batch Fix with AI (issue #31): the basket's open bugs go to the assistant in one prompt — one branch made by the AI, one commit and
    /// one outcome per bug. A bug the lifecycle does not let start is left out of the prompt; once the prompt went out, each bug in it is
    /// marked `fixing` (the hand-off is the start evidence) and the basket is emptied. When too few bugs can start, or the prompt cannot
    /// be sent, nothing is marked and the basket is kept (BUG-032). The app runs no git itself (DEC-002).
    func fixBasketWithAI() {
        bugBatch.reconcile()
        let bugs = bugBatch.eligible
        guard bugs.count >= BugBasket.minimumBatch, !assistants.assistantIsBusy, features.root != nil else { return }
        var session: TerminalSession?
        let outcome = BatchStart.run(bugs, canStart: { bug in
            features.lifecycle.canStartByHandoff(.bug, bug.key)
        }, send: { startable in
            let block = features.lifecycle.handoffBlock(.bug, startable.map(\.key))
            session = assistants.sendToAssistant(submit: true, to: nil) { receiving in
                let base = ParallelWork.items.ask(BatchFixPrompt.make(startable, tool: receiving.profile.tool), tool: receiving.profile.tool)
                return block.isEmpty ? base : base + "\n\n" + block
            }
            return session != nil
        }, start: { bug in
            let tool = session?.profile.tool?.displayName ?? "AI assistant"
            let result = features.lifecycle.startByHandoff(.bug, bug.key, tool: tool, actor: .human(features.lifecycleActor), surface: false)
            return result.reachedStatus
        })
        if case .started = outcome { bugBatch.clear() }
        bugBatch.notice = BatchStart.notice(outcome)
    }

    // MARK: - GitHub

    /// Open GitHub issue #n: its tab when the GitHub integration is on, else the issue page in the browser (repository from the `origin`
    /// remote; nothing is sent to GitHub by the app).
    func openGitHubIssue(_ number: Int) {
        if let slug = gitHub.selectedRepo?.slug {
            openGitHubTab(.issue(number: number, repo: slug, title: "#\(number)"))
            return
        }
        guard let root = project.root else { return }
        tasks.store(Task {
            let remote = await GitHubClient.execute(["remote", "get-url", "origin"], in: root, git: true)
            guard !Task.isCancelled,
                  let slug = GitHubClient.slug(fromRemoteURL: remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let url = URL(string: "https://github.com/\(slug)/issues/\(number)") else { return }
            NSWorkspace.shared.open(url)
        }, for: "openIssueInBrowser")
    }

    /// Turn MarkView's GitHub integration on (a Settings switch for every window, DEC-020) and look for `slug` in this folder again. Nil
    /// when found, else why not.
    func activateGitHub(expecting slug: String, in folder: URL) async -> String? {
        // Right after bootstrap the folder may still be opening in this window.
        for _ in 0..<40 where project.root?.standardizedFileURL != folder.standardizedFileURL {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let root = project.root, root.standardizedFileURL == folder.standardizedFileURL else {
            return "This window does not show \(folder.lastPathComponent) any more. Open it and use File › Publish to GitHub… to finish."
        }
        if !GitHubSettings.enabled { Settings.standard.set(true, for: Setting.gitHubEnabled) }
        // The remote was added after the folder opened: detect again.
        gitHub.reset()
        gitHubRoot = root
        gitHubSettingChanged()
        for _ in 0..<40 {
            if gitHub.repos.contains(where: { $0.slug.lowercased() == slug.lowercased() }) { return nil }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return gitHub.lastError ?? "MarkView did not find \(slug) among this folder's remotes."
    }

    /// Open (or switch to) the editor tab of a workflow run or an issue.
    func openGitHubTab(_ item: GitHubItem) {
        guard let root = project.root ?? gitHub.root else { return }
        layout.workspaceArea = .files
        layout.workSection = .git
        switch item {
        case .issue: layout.gitSection = .issues
        case .pullRequest: layout.gitSection = .pullRequests
        case .run: layout.gitSection = .actions
        }
        chrome.showCenter = true
        tabs.showGitHubTab(item, root: root)
    }

    /// Work on a pull request's code: check its branch out, refusing when the working tree has changes (nothing is stashed or
    /// overwritten). Returns an error to show.
    func checkoutPullRequest(_ number: Int) async -> String? {
        guard let root = gitClient.workingDirectory ?? project.root else { return "No folder open." }
        // Tracked changes only: untracked files (like MarkView's own .dde) do not block a
        // checkout, and git itself refuses one that would overwrite them.
        let status = await GitHubClient.execute(["status", "--porcelain", "--untracked-files=no"], in: root, git: true)
        if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The working tree has uncommitted changes. Commit or discard them before checking out PR #\(number)."
        }
        let error = await gitHub.perform("Checkout #\(number)") { try await $0.checkout(number) }
        await gitClient.refresh()
        project.refreshFileTree()
        return error
    }

    /// Check out a branch from the branch menu. Returns an error to show.
    func switchBranch(_ name: String) async -> String? {
        let error = await gitClient.switchBranch(name)
        branchChanged()
        return error
    }

    /// Create a branch from the branch menu and check it out. Returns an error to show.
    func createBranch(_ name: String, from base: String?) async -> String? {
        let error = await gitClient.createBranch(name, from: base)
        branchChanged()
        return error
    }

    /// The working copy now holds another branch's files: show them in the tree and open tabs.
    private func branchChanged() {
        project.refreshFileTree()
        tasks.store(Task { [weak self] in await self?.tabs.reloadChangedOpenFiles(all: true) }, for: "reloadAfterBranchChange")
    }

    /// The branch a pull request comes from, when it is the one checked out.
    private func isCheckedOut(_ number: Int) async -> Bool {
        guard let client = gitHub.client, let pr = try? await client.pullRequest(number) else { return false }
        return pr.headRefName == gitClient.branch
    }

    /// Send a fix request for a pull request's code to the AI terminal, after checking its branch out when needed. Returns an error to
    /// show. `work`: one finding is a task with parts, every finding a list of items.
    func fixInPullRequest(_ number: Int?, prompt: String, work: ParallelWork) async -> String? {
        var prompt = prompt
        if let number, gitHub.client != nil {
            if !(await isCheckedOut(number)), let error = await checkoutPullRequest(number) { return error }
        } else if let number {
            // Without the GitHub integration the branch is not checked out for the AI.
            prompt += "\n\nNote: this is pull request #\(number); its branch may not be the one checked out here."
        }
        assistants.sendToAssistant(prompt, submit: true, work: work)
        return nil
    }

    /// "Start with AI" on an issue: a branch for it, then the issue to the AI terminal.
    func startIssueWithAI(_ issue: GHIssue) async -> String? {
        guard let root = gitClient.workingDirectory ?? project.root else { return "No folder open." }
        let slug = String(issue.title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            .split(separator: "-").prefix(6).joined(separator: "-")
        let branch = "issue-\(issue.number)" + (slug.isEmpty ? "" : "-" + slug)
        let exists = await GitHubClient.execute(["rev-parse", "--verify", "--quiet", branch], in: root, git: true)
        let result = await GitHubClient.execute(exists.status == 0 ? ["switch", branch] : ["switch", "-c", branch], in: root, git: true)
        if result.status != 0 {
            return "Could not switch to \(branch): " + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        await gitClient.refresh()
        var prompt = "Work on GitHub issue #\(issue.number) of \(gitHub.selectedRepo?.slug ?? "this repository"): \(issue.title)\n\n"
        prompt += (issue.body ?? "").isEmpty ? "(no description)" : issue.body!
        let comments = (issue.comments ?? []).suffix(10)
        if !comments.isEmpty {
            prompt += "\n\nComments:\n" + comments.map { "- \($0.author?.login ?? "someone"): \($0.body)" }.joined(separator: "\n")
        }
        prompt += "\n\nYou are on branch \(branch). Investigate, implement the change, and summarise what you did."
        assistants.sendToAssistant(prompt, submit: true, work: .parts)
        return nil
    }

    /// "Fix with AI" on a failed run: its failed steps' logs to the AI terminal.
    func fixRunWithAI(_ model: GitHubRunModel) {
        tasks.store(Task { [weak self] in
            await model.loadFailedLogs()
            guard let self, !Task.isCancelled else { return }
            var prompt = model.failureText()
            if let run = model.run, run.headBranch != self.gitClient.branch {
                prompt += "\nNote: the run was on branch \(run.headBranch); the working copy is on \(self.gitClient.branch)."
            }
            prompt += "\nFind the cause in this repository and fix it."
            self.assistants.sendToAssistant(prompt, submit: true, work: .parts)
        }, for: "fixRunWithAI")
    }
}
