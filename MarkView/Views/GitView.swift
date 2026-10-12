import SwiftUI

/// Git tab — status, stage, commit, push/pull, history
struct GitView: View {
    @ObservedObject var git: GitClient
    let workspaceManager: WorkspaceManager
    @State private var commitMessage = ""
    @State private var selectedFile: String?
    @State private var diffText = ""
    @State private var filter = ""
    @State private var collapsed: Set<GitStatusGroup> = []
    /// Height of the status rows: the list takes what it needs, up to 260 points.
    @State private var listHeight: CGFloat = 0
    /// GitHub sections, shown only when the integration is on and the folder is on GitHub.
    @ObservedObject var gitHub: GitHubStore
    /// This window's Git section (BUG-004: not shared between windows).
    @ObservedObject var layout: PanelLayout

    init(git: GitClient, workspaceManager: WorkspaceManager) {
        self.git = git
        self.workspaceManager = workspaceManager
        self.gitHub = workspaceManager.gitHub
        self.layout = workspaceManager.layout
    }

    var body: some View {
        VStack(spacing: 0) {
            if !git.isGitRepo {
                noRepoView
            } else {
                // Branch header
                branchHeader
                progressLine

                if gitHub.isAvailable {
                    GitHubSectionPicker(gitHub: gitHub, section: $layout.gitSection)
                    Divider().background(VSDark.border)
                    switch layout.gitSection {
                    case .changes: localChanges
                    case .pullRequests: GitHubPullRequestsView(gitHub: gitHub, workspaceManager: workspaceManager)
                    case .issues: GitHubIssuesView(gitHub: gitHub, workspaceManager: workspaceManager)
                    case .actions: GitHubActionsView(gitHub: gitHub, workspaceManager: workspaceManager)
                    }
                } else {
                    localChanges
                }
            }
        }
        .background(VSDark.bgSidebar)
        .onAppear { Task { await git.refresh() } }
    }

    /// Changes, diff, commit and history — the Git tab without GitHub.
    @ViewBuilder
    private var localChanges: some View {
                // Changed files
                changedFilesView

                // Diff view (if file selected)
                if !diffText.isEmpty {
                    diffView
                }

                Divider().background(VSDark.border)

                // Commit bar
                commitBar

                Divider().background(VSDark.border)

                // History
                historyView
    }

    /// What is running right now: a Git operation, or GitHub loading its lists. Without it a slow
    /// network call looks like nothing happened.
    private var progressText: String? {
        if let activity = git.activity { return activity }
        guard gitHub.isAvailable else { return nil }
        switch layout.gitSection {
        case .pullRequests where gitHub.loadingPRs: return "Loading pull requests from GitHub…"
        case .issues where gitHub.loadingIssues: return "Loading issues from GitHub…"
        case .actions where gitHub.loadingRuns: return "Loading workflow runs from GitHub…"
        default: return nil
        }
    }

    @ViewBuilder private var progressLine: some View {
        if let text = progressText {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    Text(text).uiFont(size: 10).foregroundColor(VSDark.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                ProgressView().progressViewStyle(.linear).controlSize(.mini).tint(VSDark.blue)
            }
            .background(VSDark.bgInput)
        }
    }

    // MARK: - No Repo

    private var noRepoView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.triangle.branch").uiFont(size: 24).foregroundColor(VSDark.textDim)
            Text("Not a Git repository").uiFont(size: 12).foregroundColor(VSDark.textDim)
            Button("Initialize Git Repo") {
                Task { await git.initRepo() }
            }
            .buttonStyle(.borderedProminent).tint(VSDark.blue)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    // MARK: - Branch

    private var branchHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").uiFont(size: 10).foregroundColor(VSDark.blue)
            GitBranchMenu(git: git, workspaceManager: workspaceManager)
            if gitHub.isAvailable {
                GitHubBranchStatus(gitHub: gitHub) {
                    gitHub.runBranch = git.branch
                    layout.gitSection = .actions
                }
            }
            Spacer()
            if !gitHub.isAvailable {
                // Not connected (no GitHub remote, or the integration is off): create or connect
                // a repository and publish (REQ-003).
                Button(action: { workspaceManager.gitHubPublishRequested = true }) {
                    Image(systemName: "icloud.and.arrow.up").uiFont(size: 10).foregroundColor(VSDark.textDim)
                }.buttonStyle(.plain).help("Publish to GitHub…")
            }
            if git.isOperating {
                ProgressView().scaleEffect(0.4)
            }
            Button(action: { Task { await git.refresh() } }) {
                Image(systemName: "arrow.clockwise").uiFont(size: 10).foregroundColor(VSDark.textDim)
            }.buttonStyle(.plain)
            Button(action: { Task { await git.pull() } }) {
                Image(systemName: "arrow.down.circle").uiFont(size: 10).foregroundColor(VSDark.textDim)
            }.buttonStyle(.plain).help("Pull")
            Button(action: { Task { await git.push() } }) {
                Image(systemName: "arrow.up.circle").uiFont(size: 10).foregroundColor(VSDark.textDim)
            }.buttonStyle(.plain).help("Push")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(VSDark.bgActive)
    }

    // MARK: - Repository status

    private var visibleGroups: [GitStatusGroup] {
        GitStatusGroup.allCases.filter { group in
            switch group {
            case .ignored: return git.showIgnored
            case .tracked: return git.showTracked
            default: return true
            }
        }
    }

    private func matches(_ path: String) -> Bool {
        filter.isEmpty || path.localizedCaseInsensitiveContains(filter)
    }

    private func paths(in group: GitStatusGroup) -> [String] {
        group == .tracked ? git.cleanTracked.filter(matches) : git.repoStatus.entries(in: group).map(\.path).filter(matches)
    }

    private var changedFilesView: some View {
        VStack(spacing: 0) {
            statusSummary
            let clean = git.repoStatus.entries.allSatisfy { $0.special == .ignored }
            if clean && !git.showIgnored && !git.showTracked {
                HStack {
                    Image(systemName: "checkmark.circle").uiFont(size: 10).foregroundColor(VSDark.green)
                    Text("Working tree clean").uiFont(size: 10).foregroundColor(VSDark.textDim)
                    Spacer()
                }.padding(.horizontal, 10).padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleGroups) { group in groupSection(group) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { listHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { listHeight = $0 }
                    })
                }
                .frame(height: min(max(listHeight, 1), 260))
            }

            if let error = git.lastError {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle").uiFont(size: 9).foregroundColor(VSDark.red)
                    Text(error).uiFont(size: 9).foregroundColor(VSDark.red).lineLimit(6)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: { git.lastError = nil }) {
                        Image(systemName: "xmark").uiFont(size: 8).foregroundColor(VSDark.textDim)
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 10).padding(.vertical, 4).background(VSDark.red.opacity(0.1))
            }
        }
    }

    /// Counts per group, where the branch stands against its upstream, and what to list besides changes.
    private var statusSummary: some View {
        let status = git.repoStatus
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ForEach([GitStatusGroup.conflicts, .staged, .changes, .untracked], id: \.self) { group in
                    let count = status.count(group)
                    if count > 0 || group != .conflicts {
                        Text("\(count) \(group.rawValue.lowercased())").uiFont(size: 9, weight: .medium)
                            .foregroundColor(count == 0 ? VSDark.textDim : color(for: group))
                    }
                }
                Spacer(minLength: 0)
                if status.upstream != nil {
                    Text("↑\(status.ahead) ↓\(status.behind)").uiFont(size: 9, weight: .medium, design: .monospaced)
                        .foregroundColor(status.behind > 0 ? VSDark.orange : VSDark.textDim)
                        .help(status.behind > 0 ? "\(status.behind) commit(s) on \(status.upstream ?? "") not here yet: pull before pushing"
                              : "Ahead of \(status.upstream ?? "") by \(status.ahead) commit(s)")
                } else if !status.head.isEmpty {
                    Text("no upstream").uiFont(size: 9).foregroundColor(VSDark.textDim)
                }
                if git.stashCount > 0 {
                    Text("\(git.stashCount) stash").uiFont(size: 9).foregroundColor(VSDark.textDim)
                }
            }
            HStack(spacing: 8) {
                Toggle("Ignored", isOn: $git.showIgnored).toggleStyle(.checkbox)
                    .help("List the paths Git ignores (.gitignore)")
                Toggle("Tracked", isOn: $git.showTracked).toggleStyle(.checkbox)
                    .help("List the files Git tracks that have no change")
                Spacer(minLength: 0)
                if status.count(.changes) + status.count(.untracked) > 0 {
                    Button("Stage All") { git.stageAll() }.uiFont(size: 9).buttonStyle(.plain).foregroundColor(VSDark.blue)
                }
            }
            .uiFont(size: 9)
            TextField("Filter paths", text: $filter).textFieldStyle(.plain).uiFont(size: 10)
                .padding(.horizontal, 6).padding(.vertical, 3).background(VSDark.bgInput).cornerRadius(4)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    @ViewBuilder
    private func groupSection(_ group: GitStatusGroup) -> some View {
        let list = paths(in: group)
        if !list.isEmpty || (group == .ignored || group == .tracked) {
            Button(action: { if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) } }) {
                HStack(spacing: 4) {
                    Image(systemName: collapsed.contains(group) ? "chevron.right" : "chevron.down").uiFont(size: 8).frame(width: 10)
                    Text("\(group.rawValue) (\(list.count))").uiFont(size: 10, weight: .bold)
                    Spacer()
                }.foregroundColor(color(for: group))
            }
            .buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 4)
            .help(help(for: group))
            .contextMenu { groupMenu(group, list) }
            if group == .conflicts && !list.isEmpty {
                HStack(spacing: 6) {
                    Button(action: { workspaceManager.resolveConflictsWithAI() }) {
                        Label("Resolve with AI", systemImage: "sparkles").uiFont(size: 10, weight: .medium)
                    }
                    .buttonStyle(.borderedProminent).tint(VSDark.blue).controlSize(.small)
                    .help("Hand the conflicted files to the assistant: it resolves and stages them, you review and commit")
                    Text(git.operationInProgress.map { "\($0) in progress" } ?? "").uiFont(size: 9).foregroundColor(VSDark.textDim)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 10).padding(.vertical, 2)
            }
            if !collapsed.contains(group) {
                ForEach(group == .tracked ? list.map { GitStatusEntry(path: $0) } : git.repoStatus.entries(in: group).filter { matches($0.path) }) { entry in
                    // The group is part of the identity: a file that moves between groups is a new row.
                    fileRow(entry, group: group).id(group.rawValue + ":" + entry.path)
                }
            }
        }
    }

    @ViewBuilder
    private func groupMenu(_ group: GitStatusGroup, _ list: [String]) -> some View {
        switch group {
        case .changes, .untracked:
            Button("Stage All \(group.rawValue)") { git.stage(list) }
            Button("Commit All \(group.rawValue)…") { commitPaths(list) }
        case .staged:
            Button("Unstage All") { git.unstage(list) }
        default:
            EmptyView()
        }
    }

    private func help(for group: GitStatusGroup) -> String {
        switch group {
        case .conflicts: return "Unmerged paths: fix them, then stage to mark them resolved"
        case .staged: return "In the index: part of the next commit"
        case .changes: return "Tracked files changed in the work tree, not staged"
        case .untracked: return "New files Git does not track yet"
        case .ignored: return "Paths matched by .gitignore (a directory counts as one entry)"
        case .tracked: return "Files Git tracks that have no change"
        }
    }

    private func color(for group: GitStatusGroup) -> Color {
        switch group {
        case .conflicts: return VSDark.red
        case .staged: return VSDark.green
        case .changes: return VSDark.orange
        case .untracked: return VSDark.blue
        case .ignored, .tracked: return VSDark.textDim
        }
    }

    private func color(for state: GitFileState) -> Color {
        switch state {
        case .modified, .typeChanged: return VSDark.orange
        case .added, .copied: return VSDark.green
        case .deleted, .conflicted: return VSDark.red
        case .renamed: return VSDark.blue
        case .untracked: return VSDark.blue
        case .ignored, .tracked: return VSDark.textDim
        }
    }

    private func fileRow(_ entry: GitStatusEntry, group: GitStatusGroup) -> some View {
        let state = group == .tracked ? .tracked : entry.state(in: group) ?? .tracked
        let dim = group == .ignored || group == .tracked
        let selection = group.rawValue + ":" + entry.path
        return HStack(spacing: 6) {
            switch group {
            case .staged:
                Button(action: { git.unstageFile(entry.path) }) {
                    Image(systemName: "checkmark.square.fill").uiFont(size: 10).foregroundColor(VSDark.green)
                }.buttonStyle(.plain).help("Unstage")
            case .changes, .untracked, .conflicts:
                Button(action: { git.stageFile(entry.path) }) {
                    Image(systemName: "square").uiFont(size: 10).foregroundColor(VSDark.textDim)
                }.buttonStyle(.plain).help(group == .conflicts ? "Mark as resolved (stage)" : "Stage")
            case .ignored, .tracked:
                Color.clear.frame(width: 10, height: 10)
            }

            Text(state.letter).uiFont(size: 9, weight: .bold, design: .monospaced)
                .foregroundColor(color(for: state)).frame(width: 12).help(state.title)

            Button(action: {
                selectedFile = selection
                if group == .staged || group == .changes {
                    Task { diffText = await git.diff(file: entry.path, staged: group == .staged) }
                } else {
                    diffText = ""
                    if !entry.isDirectory { openFile(entry.path) }
                }
            }) {
                Text(entry.origin.map { "\($0) → \(entry.path)" } ?? entry.path)
                    .uiFont(size: 10).foregroundColor(dim ? VSDark.textDim : VSDark.text)
                    .italic(group == .ignored).lineLimit(1).truncationMode(.middle)
            }.buttonStyle(.plain)

            Spacer(minLength: 0)

            if !entry.isDirectory && entry.state(in: group) != .deleted && group != .conflicts || group == .conflicts {
                Button(action: { openFile(entry.path) }) {
                    Image(systemName: "doc.text").uiFont(size: 8).foregroundColor(VSDark.blue)
                }.buttonStyle(.plain).help("Open")
            }
            if group == .changes {
                Button(action: { git.discardChanges(entry.path) }) {
                    Image(systemName: "arrow.uturn.backward").uiFont(size: 8).foregroundColor(VSDark.red)
                }.buttonStyle(.plain).help("Discard changes in the work tree")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(selectedFile == selection ? VSDark.bgActive : Color.clear)
        .contentShape(Rectangle())
        .contextMenu { rowMenu(entry, group: group) }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func rowMenu(_ entry: GitStatusEntry, group: GitStatusGroup) -> some View {
        let path = entry.path
        let isDirectory = entry.isDirectory
        switch group {
        case .untracked:
            Button("Stage (Track)") { git.stage([path]) }
            Button("Commit This \(isDirectory ? "Folder" : "File")…") { commitPaths([path]) }
            Button("Add to .gitignore") { Task { await git.ignore(path, isDirectory: isDirectory) } }
        case .changes:
            Button("Stage") { git.stage([path]) }
            Button("Commit This File…") { commitPaths([path]) }
            Button("Discard Changes", role: .destructive) { git.discardChanges(path) }
            Divider()
            Button("Stop Tracking (Keep File)") { git.untrack(path) }
            Button("Add to .gitignore") { Task { await git.ignore(path, isDirectory: isDirectory) } }
        case .staged:
            Button("Unstage") { git.unstage([path]) }
            Button("Commit This File…") { commitPaths([path]) }
            Divider()
            Button("Stop Tracking (Keep File)") { git.untrack(path) }
            Button("Add to .gitignore") { Task { await git.ignore(path, isDirectory: isDirectory) } }
        case .conflicts:
            Button("Mark as Resolved (Stage)") { git.stage([path]) }
            Button("Take Ours") { Task { await git.resolve(path, taking: "ours") } }
            Button("Take Theirs") { Task { await git.resolve(path, taking: "theirs") } }
        case .tracked:
            Button("Stop Tracking (Keep File)") { git.untrack(path) }
            Button("Add to .gitignore") { Task { await git.ignore(path, isDirectory: isDirectory) } }
        case .ignored:
            Text("Ignored by .gitignore")
        }
        Divider()
        if !isDirectory && entry.state(in: group) != .deleted {
            Button("Open") { openFile(path) }
        }
        Button("Show in Finder") {
            if let root = git.workingDirectory { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(path)]) }
        }
        Button("Copy Relative Path") { copy(path) }
        Button("Copy Full Path") { if let root = git.workingDirectory { copy(root.appendingPathComponent(path).path) } }
        if group == .untracked || group == .ignored {
            Divider()
            Button("Move to Trash", role: .destructive) { trash(path) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func trash(_ path: String) {
        guard let root = git.workingDirectory else { return }
        do {
            try FileManager.default.trashItem(at: root.appendingPathComponent(path), resultingItemURL: nil)
        } catch {
            git.lastError = "Couldn't move to the Trash: \(error.localizedDescription)"
        }
        Task { await git.refresh() }
    }

    /// Ask for a message, then stage and commit just these paths.
    private func commitPaths(_ paths: [String]) {
        let alert = NSAlert()
        alert.messageText = "Commit \(paths.count == 1 ? paths[0] : "\(paths.count) paths")"
        alert.informativeText = "Only this will be committed; other staged changes stay as they are."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "Commit message"
        input.stringValue = commitMessage
        alert.accessoryView = input
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let message = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        Task { _ = await git.commit(paths: paths, message: message) }
    }

    // MARK: - Diff

    private var diffView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedFile.map { String($0.drop(while: { $0 != ":" }).dropFirst()) } ?? "")
                    .uiFont(size: 9, weight: .bold).foregroundColor(VSDark.blue)
                Spacer()
                Button(action: { diffText = ""; selectedFile = nil }) {
                    Image(systemName: "xmark").uiFont(size: 8).foregroundColor(VSDark.textDim)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 10).padding(.vertical, 3)

            ScrollView {
                Text(diffText)
                    .uiFont(size: 10, design: .monospaced)
                    .foregroundColor(VSDark.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
            }
            .frame(maxHeight: 200)
            .background(VSDark.bg)
        }
    }

    // MARK: - Commit

    private var commitBar: some View {
        VStack(spacing: 4) {
            TextField("Commit message...", text: $commitMessage)
                .textFieldStyle(.plain)
                .uiFont(size: 11)
                .foregroundColor(VSDark.text)
                .padding(.horizontal, 10).padding(.top, 6)

            let staged = git.changedFiles.filter { $0.isStaged }.count
            HStack(spacing: 8) {
                Button(action: {
                    Task {
                        if await git.commit(message: commitMessage) { commitMessage = "" }
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle").uiFont(size: 10)
                        Text("Commit (\(staged))").uiFont(size: 10)
                    }.foregroundColor(commitMessage.isEmpty || staged == 0 ? VSDark.textDim : VSDark.green)
                }
                .buttonStyle(.plain)
                .disabled(commitMessage.isEmpty || staged == 0)

                Button(action: {
                    Task {
                        if await git.commit(message: commitMessage) {
                            commitMessage = ""
                            _ = await git.push()
                        }
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.circle").uiFont(size: 10)
                        Text("Commit & Push").uiFont(size: 10)
                    }.foregroundColor(commitMessage.isEmpty || staged == 0 ? VSDark.textDim : VSDark.blue)
                }
                .buttonStyle(.plain)
                .disabled(commitMessage.isEmpty || staged == 0)

                Spacer()
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
        }
        .background(VSDark.bgInput)
    }

    // MARK: - History

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History").uiFont(size: 10, weight: .bold).foregroundColor(VSDark.textDim)
                .padding(.horizontal, 10).padding(.vertical, 4)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(git.commitLog) { commit in
                        HStack(spacing: 6) {
                            Text(commit.hash)
                                .uiFont(size: 9, design: .monospaced)
                                .foregroundColor(VSDark.blue)
                            Text(commit.message)
                                .uiFont(size: 10)
                                .foregroundColor(VSDark.text)
                                .lineLimit(1)
                            Spacer()
                            Text(commit.date)
                                .uiFont(size: 8)
                                .foregroundColor(VSDark.textDim)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func openFile(_ relativePath: String) {
        guard let root = git.workingDirectory else { return }
        let url = root.appendingPathComponent(relativePath)
        workspaceManager.openFile(url)
    }
}

// MARK: - Branch Menu

/// The current branch as a menu: switch to a local or remote branch, or create a new one.
struct GitBranchMenu: View {
    @ObservedObject var git: GitClient
    let workspaceManager: WorkspaceManager
    var fontSize: CGFloat = 11
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 5) {
            menu
            if git.worktrees.count > 1 {
                Text("+\(git.worktrees.count - 1) copies").uiFont(size: fontSize - 2).foregroundColor(VSDark.textDim)
                    .help("Other working copies of this repository (worktrees), each on its own branch: open the branch menu to see them.")
            }
        }
    }

    private var menu: some View {
        Menu {
            Section("Switch to") {
                ForEach(git.localBranches, id: \.self) { name in
                    // A branch checked out in another working copy cannot be checked out here: open that copy.
                    let elsewhere = git.worktrees.first { $0.branch == name && !sameFolder($0.path) }
                    Button((name == git.branch ? "✓ " : "") + name + (elsewhere.map { " — in \($0.folderName)" } ?? "")) {
                        if let elsewhere { workspaceManager.openFolder(URL(fileURLWithPath: elsewhere.path)) }
                        else { run { await workspaceManager.switchBranch(name) } }
                    }
                    .disabled(name == git.branch)
                }
            }
            if !git.remoteBranches.isEmpty {
                Menu("Remote Branches") {
                    ForEach(git.remoteBranches, id: \.self) { name in
                        Button(name) { run { await workspaceManager.switchBranch(name) } }
                    }
                }
            }
            if !git.worktrees.isEmpty {
                Menu("Other Working Copies (\(git.worktrees.count - 1))") {
                    ForEach(git.worktrees) { copy in
                        let here = sameFolder(copy.path)
                        Button((here ? "✓ " : "") + copy.branchLabel + " — " + copy.folderName
                               + (copy.changes.map { $0 > 0 ? " (\($0) changes)" : "" } ?? "")) {
                            workspaceManager.openFolder(URL(fileURLWithPath: copy.path))
                        }
                        .disabled(here || copy.isBare)
                    }
                }
            }
            Divider()
            Menu("Compare This Branch With") {
                compareList(reverse: false)
            }
            Menu("Show What Another Branch Adds") {
                compareList(reverse: true)
            }
            Divider()
            Button("New Branch…") { creating = true }
        } label: {
            HStack(spacing: 3) {
                Text(git.branch).uiFont(size: fontSize, weight: .semibold)
                Image(systemName: "chevron.down").uiFont(size: fontSize - 3, weight: .semibold)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(git.isOperating)
        .help("Switch or create a branch. Uncommitted changes move along unless the switch would overwrite them. \"copies\" are other working copies of this repository (worktrees), each on its own branch.")
        .popover(isPresented: $creating, arrowEdge: .bottom) {
            GitNewBranchForm(git: git) { name, base in
                creating = false
                run { await workspaceManager.createBranch(name, from: base) }
            }
        }
        .alert("Branch", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func run(_ operation: @escaping () async -> String?) {
        Task { error = await operation() }
    }

    private func sameFolder(_ path: String) -> Bool {
        guard let open = git.workingDirectory else { return false }
        return open.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The other branches to compare with, local first, then remote ones (opened in the PR X-Ray).
    @ViewBuilder
    private func compareList(reverse: Bool) -> some View {
        let others = git.localBranches.filter { $0 != git.branch }
        ForEach(others, id: \.self) { name in
            Button(name) { workspaceManager.compareBranch(name, reverse: reverse) }
        }
        if !git.remoteBranches.isEmpty {
            Menu("Remote Branches") {
                ForEach(git.remoteBranches, id: \.self) { name in
                    Button(name) { workspaceManager.compareBranch(name, reverse: reverse) }
                }
            }
        }
        if others.isEmpty && git.remoteBranches.isEmpty { Text("No other branches") }
    }
}

/// Name and starting point of a new branch; the branch is checked out once created.
private struct GitNewBranchForm: View {
    @ObservedObject var git: GitClient
    let create: (_ name: String, _ base: String?) -> Void
    @State private var name = ""
    /// Empty means the current commit.
    @State private var base = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var exists: Bool { git.localBranches.contains(trimmed) }
    private var canCreate: Bool { GitClient.isPlausibleBranchName(trimmed) && !exists }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Branch").uiFont(.headline)
            TextField("feat/my-change", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canCreate { submit() } }
            if exists {
                Text("A branch with this name already exists.").uiFont(.caption).foregroundColor(.secondary)
            } else if !trimmed.isEmpty && !canCreate {
                Text("Not a valid branch name.").uiFont(.caption).foregroundColor(.secondary)
            }
            Picker("From", selection: $base) {
                Text("Current (\(git.branch))").tag("")
                ForEach(git.localBranches.filter { $0 != git.branch }, id: \.self) { Text($0).tag($0) }
                ForEach(git.remoteBranches, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Spacer()
                Button("Create and Switch", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func submit() { create(trimmed, base.isEmpty ? nil : base) }
}
