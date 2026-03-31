import SwiftUI

/// Git tab — status, stage, commit, push/pull, history
struct GitView: View {
    @ObservedObject var git: GitClient
    let workspaceManager: WorkspaceManager
    @State private var commitMessage = ""
    @State private var selectedFile: String?
    @State private var diffText = ""

    var body: some View {
        VStack(spacing: 0) {
            if !git.isGitRepo {
                noRepoView
            } else {
                // Branch header
                branchHeader

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
        }
        .background(VSDark.bgSidebar)
        .onAppear { Task { await git.refresh() } }
    }

    // MARK: - No Repo

    private var noRepoView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.triangle.branch").font(.system(size: 24)).foregroundColor(VSDark.textDim)
            Text("Not a Git repository").font(.system(size: 12)).foregroundColor(VSDark.textDim)
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
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundColor(VSDark.blue)
            Text(git.branch).font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.text)
            Spacer()
            if git.isOperating {
                ProgressView().scaleEffect(0.4)
            }
            Button(action: { Task { await git.refresh() } }) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10)).foregroundColor(VSDark.textDim)
            }.buttonStyle(.plain)
            Button(action: { Task { await git.pull() } }) {
                Image(systemName: "arrow.down.circle").font(.system(size: 10)).foregroundColor(VSDark.textDim)
            }.buttonStyle(.plain).help("Pull")
            Button(action: { Task { await git.push() } }) {
                Image(systemName: "arrow.up.circle").font(.system(size: 10)).foregroundColor(VSDark.textDim)
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
                    Image(systemName: "checkmark.circle").font(.system(size: 10)).foregroundColor(VSDark.green)
                    Text("Working tree clean").font(.system(size: 10)).foregroundColor(VSDark.textDim)
                    Spacer()
                }.padding(.horizontal, 10).padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("Changes (\(git.changedFiles.count))").font(.system(size: 10, weight: .bold)).foregroundColor(VSDark.textDim)
                        Spacer()
                        Button("Stage All") { git.stageAll() }
                            .font(.system(size: 9)).buttonStyle(.plain).foregroundColor(VSDark.blue)
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
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 9)).foregroundColor(VSDark.red)
                    Text(error).font(.system(size: 9)).foregroundColor(VSDark.red).lineLimit(2)
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
                    .font(.system(size: 10))
                    .foregroundColor(file.isStaged ? VSDark.green : VSDark.textDim)
            }.buttonStyle(.plain)

            // Status icon
            Image(systemName: file.statusIcon)
                .font(.system(size: 9))
                .foregroundColor(file.statusColor == "orange" ? VSDark.orange :
                                file.statusColor == "green" ? VSDark.green :
                                file.statusColor == "red" ? VSDark.red : VSDark.textDim)

            // Filename (clickable for diff)
            Button(action: {
                selectedFile = file.file
                diffText = git.diff(file: file.file)
            }) {
                Text(file.file).font(.system(size: 10)).foregroundColor(VSDark.text).lineLimit(1)
            }.buttonStyle(.plain)

            Spacer()

            // Open in editor
            Button(action: { openFile(file.file) }) {
                Image(systemName: "doc.text").font(.system(size: 8)).foregroundColor(VSDark.blue)
            }.buttonStyle(.plain)

            // Discard changes
            Button(action: { git.discardChanges(file.file) }) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 8)).foregroundColor(VSDark.red)
            }.buttonStyle(.plain).help("Discard changes")
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(selectedFile == file.file ? VSDark.bgActive : Color.clear)
    }

    // MARK: - Diff

    private var diffView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedFile ?? "").font(.system(size: 9, weight: .bold)).foregroundColor(VSDark.blue)
                Spacer()
                Button(action: { diffText = ""; selectedFile = nil }) {
                    Image(systemName: "xmark").font(.system(size: 8)).foregroundColor(VSDark.textDim)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 10).padding(.vertical, 3)

            ScrollView {
                Text(diffText)
                    .font(.system(size: 10, design: .monospaced))
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
                .font(.system(size: 11))
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
                        Image(systemName: "checkmark.circle").font(.system(size: 10))
                        Text("Commit (\(staged))").font(.system(size: 10))
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
                        Image(systemName: "arrow.up.circle").font(.system(size: 10))
                        Text("Commit & Push").font(.system(size: 10))
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
            Text("History").font(.system(size: 10, weight: .bold)).foregroundColor(VSDark.textDim)
                .padding(.horizontal, 10).padding(.vertical, 4)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(git.commitLog) { commit in
                        HStack(spacing: 6) {
                            Text(commit.hash)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(VSDark.blue)
                            Text(commit.message)
                                .font(.system(size: 10))
                                .foregroundColor(VSDark.text)
                                .lineLimit(1)
                            Spacer()
                            Text(commit.date)
                                .font(.system(size: 8))
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
