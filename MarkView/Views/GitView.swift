import SwiftUI

/// Git tab — status, stage, commit, push/pull, history
struct GitView: View {
    @ObservedObject var git: GitClient
    let workspaceManager: WorkspaceManager
    @State private var commitMessage = ""
    @State private var selectedFile: String?
    @State private var diffText = ""
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

    // MARK: - Changed Files

    private var changedFilesView: some View {
        Group {
            if git.changedFiles.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle").uiFont(size: 10).foregroundColor(VSDark.green)
                    Text("Working tree clean").uiFont(size: 10).foregroundColor(VSDark.textDim)
                    Spacer()
                }.padding(.horizontal, 10).padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("Changes (\(git.changedFiles.count))").uiFont(size: 10, weight: .bold).foregroundColor(VSDark.textDim)
                        Spacer()
                        Button("Stage All") { git.stageAll() }
                            .uiFont(size: 9).buttonStyle(.plain).foregroundColor(VSDark.blue)
                    }.padding(.horizontal, 10).padding(.vertical, 4)

                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(git.changedFiles) { file in
                                fileRow(file)
                            }
                        }
                    }.frame(maxHeight: 150)
                }
            }

            if let error = git.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle").uiFont(size: 9).foregroundColor(VSDark.red)
                    Text(error).uiFont(size: 9).foregroundColor(VSDark.red).lineLimit(2)
                    Spacer()
                }.padding(.horizontal, 10).padding(.vertical, 4).background(VSDark.red.opacity(0.1))
            }
        }
    }

    private func fileRow(_ file: GitClient.GitFileStatus) -> some View {
        HStack(spacing: 6) {
            // Stage/unstage checkbox
            Button(action: {
                if file.isStaged { git.unstageFile(file.file) } else { git.stageFile(file.file) }
            }) {
                Image(systemName: file.isStaged ? "checkmark.square.fill" : "square")
                    .uiFont(size: 10)
                    .foregroundColor(file.isStaged ? VSDark.green : VSDark.textDim)
            }.buttonStyle(.plain)

            // Status icon
            Image(systemName: file.statusIcon)
                .uiFont(size: 9)
                .foregroundColor(file.statusColor == "orange" ? VSDark.orange :
                                file.statusColor == "green" ? VSDark.green :
                                file.statusColor == "red" ? VSDark.red : VSDark.textDim)

            // Filename (clickable for diff)
            Button(action: {
                selectedFile = file.file
                Task { diffText = await git.diff(file: file.file) }
            }) {
                Text(file.file).uiFont(size: 10).foregroundColor(VSDark.text).lineLimit(1)
            }.buttonStyle(.plain)

            Spacer()

            // Open in editor
            Button(action: { openFile(file.file) }) {
                Image(systemName: "doc.text").uiFont(size: 8).foregroundColor(VSDark.blue)
            }.buttonStyle(.plain)

            // Discard changes
            Button(action: { git.discardChanges(file.file) }) {
                Image(systemName: "arrow.uturn.backward").uiFont(size: 8).foregroundColor(VSDark.red)
            }.buttonStyle(.plain).help("Discard changes")
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(selectedFile == file.file ? VSDark.bgActive : Color.clear)
    }

    // MARK: - Diff

    private var diffView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedFile ?? "").uiFont(size: 9, weight: .bold).foregroundColor(VSDark.blue)
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
        Menu {
            Section("Switch to") {
                ForEach(git.localBranches, id: \.self) { name in
                    Button((name == git.branch ? "✓ " : "") + name) { run { await workspaceManager.switchBranch(name) } }
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
        .help("Switch or create a branch. Uncommitted changes move along unless the switch would overwrite them.")
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
