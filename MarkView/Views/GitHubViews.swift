import SwiftUI
import AppKit

// MARK: - Shared pieces

/// Icon and color of an outcome (runs, jobs, steps, checks).
func gitHubOutcomeIcon(_ outcome: GHOutcome?) -> (name: String, color: Color) {
    switch outcome {
    case .success: return ("checkmark.circle.fill", VSDark.green)
    case .failure: return ("xmark.circle.fill", VSDark.red)
    case .running: return ("circle.dotted", VSDark.yellow)
    case .neutral: return ("minus.circle", VSDark.textDim)
    case nil: return ("circle", VSDark.textDim)
    }
}

struct GitHubOutcomeIcon: View {
    let outcome: GHOutcome?
    var size: CGFloat = 10

    var body: some View {
        let icon = gitHubOutcomeIcon(outcome)
        Image(systemName: icon.name).font(.system(size: size)).foregroundColor(icon.color)
    }
}

/// Small toolbar of a Git tab section: pickers on the left, search, refresh.
private struct SectionBar<Leading: View>: View {
    @Binding var search: String
    let loading: Bool
    let refresh: () -> Void
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                leading()
                Spacer(minLength: 0)
                if loading { ProgressView().scaleEffect(0.4).frame(width: 12, height: 12) }
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10)).foregroundColor(VSDark.textDim)
                }.buttonStyle(.plain).help("Refresh")
            }
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                TextField("Filter", text: $search).textFieldStyle(.plain).font(.system(size: 11))
                if !search.isEmpty {
                    Button(action: { search = "" }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(VSDark.bgInput).cornerRadius(4)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

private func matches(_ search: String, _ fields: String...) -> Bool {
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return true }
    return fields.contains { $0.lowercased().contains(query) }
}

private func openInBrowser(_ link: String) {
    if let url = URL(string: link), url.scheme == "https" { NSWorkspace.shared.open(url) }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private func showError(_ title: String, _ message: String?) {
    guard let message else { return }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.runModal()
}

private func errorBanner(_ text: String?) -> some View {
    Group {
        if let text {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 9)).foregroundColor(VSDark.red)
                Text(text).font(.system(size: 9)).foregroundColor(VSDark.red).lineLimit(3).textSelection(.enabled)
                Spacer()
            }.padding(.horizontal, 10).padding(.vertical, 4).background(VSDark.red.opacity(0.1))
        }
    }
}

/// A sheet asking for one text (review comment, pull request comment…).
struct GitHubTextSheet: View {
    let title: String
    let placeholder: String
    let action: String
    /// An empty text is allowed (e.g. Approve without a comment).
    var allowsEmpty = false
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(minWidth: 380, minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(VSDark.border))
            Text(placeholder).font(.caption).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) { onDone(text); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allowsEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }
}

// MARK: - Git tab sections

enum GitSection: String, CaseIterable {
    case changes = "Changes"
    case pullRequests = "PRs"
    case issues = "Issues"
    case actions = "Actions"
}

/// The section picker under the Git tab's branch header, with the repository picker when the
/// folder is a fork (origin and upstream).
struct GitHubSectionPicker: View {
    @ObservedObject var gitHub: GitHubStore
    @Binding var section: GitSection

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(GitSection.allCases, id: \.self) { item in
                    VSDarkTabButton(title: title(item), isSelected: section == item) { section = item }
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            if gitHub.repos.count > 1 {
                HStack(spacing: 4) {
                    Image(systemName: "shippingbox").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                    Picker("", selection: Binding(get: { gitHub.selectedRepo }, set: { gitHub.selectedRepo = $0 })) {
                        ForEach(gitHub.repos, id: \.self) { repo in
                            Text(repo.slug + (repo.isUpstream ? " (upstream)" : "")).tag(Optional(repo))
                        }
                    }
                    .labelsHidden().controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.bottom, 3)
            }
        }
        .background(VSDark.bg)
    }

    private func title(_ item: GitSection) -> String {
        switch item {
        case .pullRequests where gitHub.prState == "open" && !gitHub.pullRequests.isEmpty:
            return "PRs \(gitHub.pullRequests.count)"
        case .issues where gitHub.issueState == "open" && !gitHub.issues.isEmpty:
            return "Issues \(gitHub.issues.count)"
        case .actions where gitHub.runs.contains(where: \.isActive):
            return "Actions ●"
        default: return item.rawValue
        }
    }
}

/// The current branch's CI, next to its name in the Git tab.
struct GitHubBranchStatus: View {
    @ObservedObject var gitHub: GitHubStore
    let onTap: () -> Void

    var body: some View {
        if let outcome = gitHub.branchOutcome {
            Button(action: onTap) {
                HStack(spacing: 2) {
                    GitHubOutcomeIcon(outcome: outcome, size: 9)
                    Text("CI").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                }
            }
            .buttonStyle(.plain)
            .help(gitHub.branchRuns.map { "\($0.workflowName): \($0.conclusion ?? $0.status)" }.joined(separator: "\n"))
        }
    }
}

// MARK: Pull requests

struct GitHubPullRequestsView: View {
    @ObservedObject var gitHub: GitHubStore
    let workspaceManager: WorkspaceManager
    @State private var search = ""
    @State private var textAction: TextAction?
    @State private var confirm: Confirm?
    @State private var showNewPR = false

    struct TextAction: Identifiable {
        let id = UUID()
        let pr: GHPullRequest
        /// approve | request-changes | comment
        let kind: String
    }

    struct Confirm: Identifiable {
        let id = UUID()
        let pr: GHPullRequest
        /// merge | squash | rebase | close
        let kind: String
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionBar(search: $search, loading: gitHub.loadingPRs, refresh: gitHub.refreshPullRequests) {
                Picker("", selection: $gitHub.prState) {
                    Text("Open").tag("open"); Text("Closed").tag("closed"); Text("Merged").tag("merged")
                }.labelsHidden().controlSize(.small).fixedSize()
                Picker("", selection: $gitHub.prFilter) {
                    ForEach(GitHubClient.PRFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().controlSize(.small).fixedSize()
                Button(action: { showNewPR = true }) {
                    Image(systemName: "plus").font(.system(size: 10)).foregroundColor(VSDark.blue)
                }.buttonStyle(.plain).help("New pull request from the current branch")
            }
            errorBanner(gitHub.lastError)
            Divider().background(VSDark.border)
            let list = gitHub.pullRequests.filter { matches(search, "#\($0.number)", $0.title, $0.author?.login ?? "", $0.headRefName) }
            if list.isEmpty {
                emptyList(gitHub.loadingPRs ? "Loading…" : "No pull requests")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list) { pr in row(pr); Divider().background(VSDark.border) }
                    }
                }
            }
        }
        .onAppear { if gitHub.pullRequests.isEmpty { gitHub.refreshPullRequests() } }
        .sheet(item: $textAction) { action in
            GitHubTextSheet(title: sheetTitle(action), placeholder: "Markdown is supported.",
                            action: action.kind == "approve" ? "Approve" : action.kind == "comment" ? "Comment" : "Request changes",
                            allowsEmpty: action.kind == "approve") { text in
                Task {
                    let error = await gitHub.perform("#\(action.pr.number)") { client in
                        if action.kind == "comment" { try await client.commentPR(action.pr.number, body: text) }
                        else { try await client.review(action.pr.number, action: action.kind, body: text) }
                    }
                    showError("GitHub", error)
                    gitHub.refreshPullRequests()
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { item in
            Button(item.kind == "close" ? "Close pull request" : "Merge", role: item.kind == "close" ? .destructive : nil) {
                Task {
                    let error = await gitHub.perform("#\(item.pr.number)") { client in
                        if item.kind == "close" { try await client.closePR(item.pr.number) }
                        else { try await client.merge(item.pr.number, method: item.kind) }
                    }
                    showError("GitHub", error)
                    gitHub.refreshPullRequests()
                }
            }
        }
        .sheet(isPresented: $showNewPR) {
            GitHubNewPRSheet(gitHub: gitHub, git: workspaceManager.gitClient)
        }
    }

    private var confirmTitle: String {
        guard let confirm else { return "" }
        switch confirm.kind {
        case "close": return "Close #\(confirm.pr.number) without merging?"
        case "squash": return "Squash and merge #\(confirm.pr.number) into \(confirm.pr.baseRefName)?"
        case "rebase": return "Rebase and merge #\(confirm.pr.number) into \(confirm.pr.baseRefName)?"
        default: return "Merge #\(confirm.pr.number) into \(confirm.pr.baseRefName)?"
        }
    }

    private func sheetTitle(_ action: TextAction) -> String {
        switch action.kind {
        case "approve": return "Approve #\(action.pr.number)"
        case "comment": return "Comment on #\(action.pr.number)"
        default: return "Request changes on #\(action.pr.number)"
        }
    }

    private func row(_ pr: GHPullRequest) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("#\(pr.number)").font(.system(size: 10, design: .monospaced)).foregroundColor(VSDark.blue)
                Text(pr.title).font(.system(size: 11, weight: .medium)).foregroundColor(VSDark.text).lineLimit(2)
                Spacer(minLength: 4)
                if let outcome = pr.checksOutcome {
                    HStack(spacing: 2) {
                        GitHubOutcomeIcon(outcome: outcome, size: 9)
                        Text("\(pr.passedChecks)/\(pr.checks.count)").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                    }.help(pr.checks.map { "\($0.title): \($0.conclusion ?? $0.state ?? $0.status ?? "")" }.joined(separator: "\n"))
                }
                if let count = pr.comments?.count, count > 0 {
                    HStack(spacing: 1) {
                        Image(systemName: "bubble.left").font(.system(size: 8))
                        Text("\(count)").font(.system(size: 9))
                    }.foregroundColor(VSDark.textDim)
                }
            }
            HStack(spacing: 4) {
                if pr.isDraft == true { Text("draft").font(.system(size: 8)).padding(.horizontal, 3).background(VSDark.bgInput).cornerRadius(2) }
                decisionBadge(pr.reviewDecision)
                Text("\(pr.author?.login ?? "") · \(pr.headRefName) → \(pr.baseRefName) · \(GHDate.ago(pr.updatedAt))")
                    .font(.system(size: 9)).foregroundColor(VSDark.textDim).lineLimit(1)
            }
            HStack(spacing: 10) {
                Button(action: { workspaceManager.reviewPullRequest(pr.number) }) {
                    Label("Review", systemImage: "sparkles").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundColor(VSDark.blue)
                .help("Open this pull request in the PR X-Ray and start the AI review")
                if pr.state.uppercased() == "OPEN" {
                    Button(action: {
                        Task { showError("Checkout #\(pr.number)", await workspaceManager.checkoutPullRequest(pr.number)) }
                    }) {
                        Label("Checkout", systemImage: "arrow.down.to.line").font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundColor(VSDark.textDim)
                    .help("Check out the branch of this pull request (refused while there are uncommitted changes)")
                }
                Spacer()
                menu(pr)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func menu(_ pr: GHPullRequest) -> some View {
        Menu {
            Button("Open on GitHub") { openInBrowser(pr.url) }
            Button("Copy Link") { copyToPasteboard(pr.url) }
            if pr.state.uppercased() == "OPEN" {
                Divider()
                Button("Approve…") { textAction = TextAction(pr: pr, kind: "approve") }
                Button("Request Changes…") { textAction = TextAction(pr: pr, kind: "request-changes") }
                Button("Comment…") { textAction = TextAction(pr: pr, kind: "comment") }
                Divider()
                Menu("Merge") {
                    Button("Squash and Merge…") { confirm = Confirm(pr: pr, kind: "squash") }
                    Button("Create a Merge Commit…") { confirm = Confirm(pr: pr, kind: "merge") }
                    Button("Rebase and Merge…") { confirm = Confirm(pr: pr, kind: "rebase") }
                }
                Button("Close…") { confirm = Confirm(pr: pr, kind: "close") }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 11)).foregroundColor(VSDark.textDim)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    @ViewBuilder
    private func decisionBadge(_ decision: String?) -> some View {
        switch decision {
        case "APPROVED": Text("approved").font(.system(size: 8)).foregroundColor(VSDark.green)
        case "CHANGES_REQUESTED": Text("changes requested").font(.system(size: 8)).foregroundColor(VSDark.red)
        default: EmptyView()
        }
    }
}

private func emptyList(_ text: String) -> some View {
    VStack {
        Spacer()
        Text(text).font(.system(size: 11)).foregroundColor(VSDark.textDim)
        Spacer()
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
}

/// New pull request from the current branch: pushes it, then `gh pr create`.
struct GitHubNewPRSheet: View {
    @ObservedObject var gitHub: GitHubStore
    @ObservedObject var git: GitClient
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var base = "main"
    @State private var draft = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Pull Request").font(.headline)
            Text("From \(git.branch) into:").font(.caption).foregroundColor(.secondary)
            TextField("Base branch", text: $base).textFieldStyle(.roundedBorder)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $bodyText)
                .font(.system(size: 12)).frame(minWidth: 420, minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(VSDark.border))
            Toggle("Draft", isOn: $draft)
            if let error { Text(error).font(.caption).foregroundColor(.red).textSelection(.enabled) }
            HStack {
                if working { ProgressView().scaleEffect(0.6) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Push & Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || title.trimmingCharacters(in: .whitespaces).isEmpty || git.branch == base)
            }
        }
        .padding(16)
        .onAppear {
            if title.isEmpty { title = git.commitLog.first?.message ?? "" }
        }
    }

    private func create() {
        guard let root = gitHub.root, let repo = gitHub.selectedRepo else { return }
        working = true
        error = nil
        let branch = git.branch
        Task {
            defer { working = false }
            // The branch must be on GitHub first (always to origin: our fork or the repo).
            let push = await GitHubClient.execute(["push", "-u", "origin", "HEAD"], in: root, git: true)
            guard push.status == 0 else {
                error = "Push failed: " + push.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            var head = branch
            if repo.isUpstream, let origin = gitHub.repos.first(where: { !$0.isUpstream }) {
                head = (origin.slug.split(separator: "/").first.map(String.init) ?? "") + ":" + branch
            }
            do {
                let url = try await GitHubClient(root: root, repo: repo)
                    .createPR(title: title, body: bodyText, base: base, head: head, draft: draft)
                gitHub.refreshPullRequests()
                dismiss()
                openInBrowser(url)
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: Issues

struct GitHubIssuesView: View {
    @ObservedObject var gitHub: GitHubStore
    let workspaceManager: WorkspaceManager
    @State private var search = ""
    @State private var showNew = false

    var body: some View {
        VStack(spacing: 0) {
            SectionBar(search: $search, loading: gitHub.loadingIssues, refresh: gitHub.refreshIssues) {
                Picker("", selection: $gitHub.issueState) {
                    Text("Open").tag("open"); Text("Closed").tag("closed")
                }.labelsHidden().controlSize(.small).fixedSize()
                Picker("", selection: $gitHub.issueFilter) {
                    ForEach(GitHubClient.IssueFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().controlSize(.small).fixedSize()
                Button(action: { showNew = true }) {
                    Image(systemName: "plus").font(.system(size: 10)).foregroundColor(VSDark.blue)
                }.buttonStyle(.plain).help("New issue")
            }
            errorBanner(gitHub.lastError)
            Divider().background(VSDark.border)
            let list = gitHub.issues.filter { issue in
                matches(search, "#\(issue.number)", issue.title, issue.author?.login ?? "",
                        (issue.labels ?? []).map(\.name).joined(separator: " "))
            }
            if list.isEmpty {
                emptyList(gitHub.loadingIssues ? "Loading…" : "No issues")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list) { issue in
                            Button(action: {
                                guard let repo = gitHub.selectedRepo?.slug else { return }
                                workspaceManager.openGitHubTab(.issue(number: issue.number, repo: repo, title: "#\(issue.number) \(issue.title)"))
                            }) { row(issue) }
                            .buttonStyle(.plain)
                            Divider().background(VSDark.border)
                        }
                    }
                }
            }
        }
        .onAppear { if gitHub.issues.isEmpty { gitHub.refreshIssues() } }
        .sheet(isPresented: $showNew) { GitHubNewIssueSheet(gitHub: gitHub) }
    }

    private func row(_ issue: GHIssue) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: issue.isOpen ? "circle.circle" : "checkmark.circle")
                    .font(.system(size: 9)).foregroundColor(issue.isOpen ? VSDark.green : VSDark.purple)
                Text("#\(issue.number)").font(.system(size: 10, design: .monospaced)).foregroundColor(VSDark.blue)
                Text(issue.title).font(.system(size: 11, weight: .medium)).foregroundColor(VSDark.text).lineLimit(2)
                Spacer(minLength: 4)
                if let count = issue.comments?.count, count > 0 {
                    HStack(spacing: 1) {
                        Image(systemName: "bubble.left").font(.system(size: 8))
                        Text("\(count)").font(.system(size: 9))
                    }.foregroundColor(VSDark.textDim)
                }
            }
            HStack(spacing: 4) {
                ForEach((issue.labels ?? []).prefix(4), id: \.self) { GitHubLabelChip(label: $0) }
                Text("\(issue.author?.login ?? "") · \(GHDate.ago(issue.updatedAt))")
                    .font(.system(size: 9)).foregroundColor(VSDark.textDim).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct GitHubLabelChip: View {
    let label: GHLabel

    var body: some View {
        let color = Color(hex: Int(label.color ?? "", radix: 16) ?? 0x808080)
        Text(label.name)
            .font(.system(size: 8, weight: .medium))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.25))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.6), lineWidth: 0.5))
            .cornerRadius(3)
            .foregroundColor(VSDark.text)
    }
}

struct GitHubNewIssueSheet: View {
    @ObservedObject var gitHub: GitHubStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var chosen: Set<String> = []
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Issue").font(.headline)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $bodyText)
                .font(.system(size: 12)).frame(minWidth: 420, minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(VSDark.border))
            if !gitHub.labels.isEmpty {
                Menu(chosen.isEmpty ? "Labels" : chosen.sorted().joined(separator: ", ")) {
                    ForEach(gitHub.labels, id: \.self) { label in
                        Button((chosen.contains(label.name) ? "✓ " : "") + label.name) {
                            if chosen.contains(label.name) { chosen.remove(label.name) } else { chosen.insert(label.name) }
                        }
                    }
                }.fixedSize()
            }
            if let error { Text(error).font(.caption).foregroundColor(.red).textSelection(.enabled) }
            HStack {
                if working { ProgressView().scaleEffect(0.6) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .onAppear { gitHub.loadIssueMetadata() }
    }

    private func create() {
        guard let client = gitHub.client else { return }
        working = true
        Task {
            defer { working = false }
            do {
                _ = try await client.createIssue(title: title, body: bodyText, labels: chosen.sorted())
                gitHub.refreshIssues()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: Actions

struct GitHubActionsView: View {
    @ObservedObject var gitHub: GitHubStore
    let workspaceManager: WorkspaceManager
    @State private var search = ""
    @State private var showDispatch = false

    var body: some View {
        VStack(spacing: 0) {
            SectionBar(search: $search, loading: gitHub.loadingRuns, refresh: {
                gitHub.refreshRuns(); gitHub.refreshWorkflows()
            }) {
                Picker("", selection: $gitHub.runWorkflow) {
                    Text("All workflows").tag(Int?.none)
                    ForEach(gitHub.workflows) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().controlSize(.small).fixedSize()
                Picker("", selection: $gitHub.runBranch) {
                    Text("All branches").tag("")
                    if !gitHub.branch.isEmpty { Text(gitHub.branch).tag(gitHub.branch) }
                }.labelsHidden().controlSize(.small).fixedSize()
                workflowMenu
            }
            errorBanner(gitHub.lastError)
            Divider().background(VSDark.border)
            let list = gitHub.runs.filter { matches(search, $0.workflowName, $0.displayTitle, $0.headBranch, $0.event, "#\($0.number)") }
            if list.isEmpty {
                emptyList(gitHub.loadingRuns ? "Loading…" : "No workflow runs")
            } else {
                // Redrawn every few seconds so running durations move.
                TimelineView(.periodic(from: .now, by: gitHub.runs.contains(where: \.isActive) ? 5 : 3600)) { _ in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(list) { run in
                                Button(action: {
                                    guard let repo = gitHub.selectedRepo?.slug else { return }
                                    workspaceManager.openGitHubTab(.run(id: run.databaseId, repo: repo, title: "⚙ \(run.workflowName) #\(run.number)"))
                                }) { row(run) }
                                .buttonStyle(.plain)
                                Divider().background(VSDark.border)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if gitHub.runs.isEmpty { gitHub.refreshRuns() }
            if gitHub.workflows.isEmpty { gitHub.refreshWorkflows() }
        }
        .sheet(isPresented: $showDispatch) { GitHubDispatchSheet(gitHub: gitHub) }
    }

    private var workflowMenu: some View {
        Menu {
            Button("Run Workflow…") { showDispatch = true }
            if !gitHub.workflows.isEmpty {
                Divider()
                Menu("Edit Workflow File") {
                    ForEach(gitHub.workflows) { workflow in
                        Button(workflow.name) { openWorkflowFile(workflow) }
                    }
                }
            }
        } label: {
            Image(systemName: "play.circle").font(.system(size: 11)).foregroundColor(VSDark.blue)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Run a workflow, or edit a workflow file")
    }

    private func openWorkflowFile(_ workflow: GHWorkflow) {
        guard let root = gitHub.root, !workflow.path.split(separator: "/").contains("..") else { return }
        let url = root.appendingPathComponent(workflow.path)
        if FileManager.default.fileExists(atPath: url.path) {
            workspaceManager.openFile(url)
        } else if let web = gitHub.selectedRepo?.webURL {
            openInBrowser(web.absoluteString + "/blob/HEAD/" + workflow.path)
        }
    }

    private func row(_ run: GHRun) -> some View {
        HStack(alignment: .top, spacing: 6) {
            GitHubOutcomeIcon(outcome: run.outcome, size: 11).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(run.workflowName).font(.system(size: 11, weight: .medium)).foregroundColor(VSDark.text).lineLimit(1)
                    Text("#\(run.number)").font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                    Spacer(minLength: 4)
                    Text(GHDate.duration(run.duration)).font(.system(size: 9, design: .monospaced))
                        .foregroundColor(run.isActive ? VSDark.yellow : VSDark.textDim)
                }
                Text(run.displayTitle).font(.system(size: 10)).foregroundColor(VSDark.text).lineLimit(1)
                Text("\(run.headBranch) · \(run.event) · \(run.isActive ? "running" : GHDate.ago(run.createdAt))")
                    .font(.system(size: 9)).foregroundColor(VSDark.textDim).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// "Run workflow…": a `workflow_dispatch` workflow, the branch, and its inputs.
struct GitHubDispatchSheet: View {
    @ObservedObject var gitHub: GitHubStore
    @Environment(\.dismiss) private var dismiss
    @State private var workflowId: Int?
    @State private var ref = ""
    @State private var inputs: [GHWorkflowInput] = []
    @State private var values: [String: String] = [:]
    @State private var dispatchable = true
    @State private var loading = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run Workflow").font(.headline)
            Picker("Workflow", selection: $workflowId) {
                Text("Choose…").tag(Int?.none)
                ForEach(gitHub.workflows.filter { $0.state == "active" }) { Text($0.name).tag(Optional($0.id)) }
            }
            TextField("Branch or tag", text: $ref).textFieldStyle(.roundedBorder)
            if loading { ProgressView().scaleEffect(0.6) }
            if !dispatchable {
                Text("This workflow has no `workflow_dispatch` trigger, so it cannot be started by hand. Add one to its file to run it from here.")
                    .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(inputs, id: \.name) { input in inputField(input) }
            if let error { Text(error).font(.caption).foregroundColor(.red).textSelection(.enabled) }
            HStack {
                if working { ProgressView().scaleEffect(0.6) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || workflowId == nil || !dispatchable || ref.isEmpty || missingRequired)
            }
        }
        .padding(16)
        .frame(minWidth: 420)
        .onAppear { if ref.isEmpty { ref = gitHub.branch } }
        .onChange(of: workflowId) { _ in loadInputs() }
    }

    private var missingRequired: Bool {
        inputs.contains { $0.required && (values[$0.name] ?? "").isEmpty }
    }

    @ViewBuilder
    private func inputField(_ input: GHWorkflowInput) -> some View {
        let binding = Binding(get: { values[input.name] ?? "" }, set: { values[input.name] = $0 })
        VStack(alignment: .leading, spacing: 2) {
            switch input.type {
            case "boolean":
                Toggle(input.name, isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" }))
            case "choice":
                Picker(input.name + (input.required ? " *" : ""), selection: binding) {
                    ForEach(input.options, id: \.self) { Text($0).tag($0) }
                }
            default:
                TextField(input.name + (input.required ? " *" : ""), text: binding).textFieldStyle(.roundedBorder)
            }
            if let description = input.description, !description.isEmpty {
                Text(description).font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    /// Read the inputs from the workflow file (the local copy, else GitHub's).
    private func loadInputs() {
        inputs = []; values = [:]; dispatchable = true
        guard let id = workflowId, let workflow = gitHub.workflows.first(where: { $0.id == id }),
              let root = gitHub.root, let client = gitHub.client else { return }
        loading = true
        Task {
            defer { loading = false }
            var text = (try? String(contentsOf: root.appendingPathComponent(workflow.path), encoding: .utf8)) ?? ""
            if text.isEmpty { text = (try? await client.workflowFile(workflow.path)) ?? "" }
            let parsed = GHWorkflowFile.dispatchInputs(text)
            guard workflowId == id else { return }
            dispatchable = text.isEmpty || parsed.dispatchable
            inputs = parsed.inputs
            for input in parsed.inputs {
                values[input.name] = input.defaultValue ?? (input.type == "choice" ? input.options.first ?? "" : input.type == "boolean" ? "false" : "")
            }
        }
    }

    private func run() {
        guard let id = workflowId, let client = gitHub.client else { return }
        working = true
        error = nil
        let chosen = values.filter { !$0.value.isEmpty }
        Task {
            defer { working = false }
            do {
                try await client.dispatch(workflow: id, ref: ref, inputs: chosen)
                // The new run appears after a moment.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                gitHub.refreshRuns()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Editor tabs

/// The editor-area view of a GitHub tab (drawn over the editor like terminal tabs).
struct GitHubTabView: View {
    let item: GitHubItem
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        Group {
            switch item {
            case .run(let id, let repo, _):
                if let model = workspaceManager.gitHub.runModel(id, repo: repo) {
                    GitHubRunView(model: model)
                } else { unavailable }
            case .issue(let number, let repo, _):
                if let model = workspaceManager.gitHub.issueModel(number, repo: repo) {
                    GitHubIssueView(model: model, gitHub: workspaceManager.gitHub)
                } else { unavailable }
            }
        }
        .background(VSDark.bg)
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundColor(VSDark.textDim)
            Text("The GitHub integration is off or this folder has no \(item.repo) repository.")
                .font(.system(size: 12)).foregroundColor(VSDark.textDim)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Run

struct GitHubRunView: View {
    @ObservedObject var model: GitHubRunModel
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var expanded: Set<Int> = []
    @State private var search = ""
    @State private var confirmCancel = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.error { errorBanner(error) }
            if model.explaining || !model.explanation.isEmpty { explanationBox }
            Divider().background(VSDark.border)
            HStack(spacing: 0) {
                jobList.frame(width: 220)
                Divider().background(VSDark.border)
                stepsAndLog
            }
        }
    }

    /// Seconds between redraws: every second while the run is going (durations move).
    private var tick: TimeInterval { model.isLive ? 1 : 3600 }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: tick)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    GitHubOutcomeIcon(outcome: model.run?.outcome, size: 14)
                    Text(model.run.map { "\($0.workflowName) #\($0.number)" } ?? "Run \(model.runId)")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(VSDark.textBright)
                    if let run = model.run {
                        Text(run.displayTitle).font(.system(size: 12)).foregroundColor(VSDark.text).lineLimit(1)
                    }
                    Spacer()
                    if model.busy { ProgressView().scaleEffect(0.5) }
                }
                if let run = model.run {
                    Text("\(run.conclusion ?? run.status) · \(run.headBranch) · \(run.event) · \(GHDate.duration(run.duration))"
                         + ((run.attempt ?? 1) > 1 ? " · attempt \(run.attempt!)" : ""))
                        .font(.system(size: 11)).foregroundColor(VSDark.textDim)
                }
                HStack(spacing: 12) {
                    if let run = model.run {
                        if run.isActive {
                            Button("Cancel Run") { confirmCancel = true }
                        } else {
                            if run.outcome == .failure { Button("Re-run Failed Jobs") { model.rerun(failedOnly: true) } }
                            Button("Re-run All Jobs") { model.rerun(failedOnly: false) }
                        }
                        Button("Open on GitHub") { openInBrowser(run.url) }
                        if run.outcome == .failure {
                            Button(action: { model.explainFailure(db: workspaceManager.semanticDatabase) }) {
                                Label("Explain Failure", systemImage: "sparkles")
                            }.disabled(model.explaining)
                            Button(action: { workspaceManager.fixRunWithAI(model) }) {
                                Label("Fix with AI", systemImage: "sparkles")
                            }.help("Send the failed steps' logs to the AI terminal")
                        }
                    }
                    Spacer()
                    Button(action: { model.refresh() }) { Image(systemName: "arrow.clockwise") }.help("Refresh")
                }
                .buttonStyle(.link).font(.system(size: 11)).disabled(model.busy)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .confirmationDialog("Cancel this run?", isPresented: $confirmCancel) {
            Button("Cancel Run", role: .destructive) { model.cancel() }
        }
    }

    private var explanationBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(model.explaining ? "Reading the failure…" : "Why it failed", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.blue)
                Spacer()
            }
            ScrollView {
                Text(model.explanation.isEmpty ? "…" : model.explanation)
                    .font(.system(size: 12)).foregroundColor(VSDark.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
        }
        .padding(10).background(VSDark.bgSidebar)
    }

    private var jobList: some View {
        TimelineView(.periodic(from: .now, by: tick)) { _ in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Jobs").font(.system(size: 10, weight: .bold)).foregroundColor(VSDark.textDim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    ForEach(model.jobs) { job in
                        Button(action: { model.select(job) }) {
                            HStack(spacing: 6) {
                                GitHubOutcomeIcon(outcome: job.outcome, size: 10)
                                Text(job.name).font(.system(size: 11)).foregroundColor(VSDark.text).lineLimit(2)
                                Spacer(minLength: 4)
                                Text(GHDate.duration(job.duration)).font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(model.selected?.databaseId == job.databaseId ? VSDark.selection.opacity(0.35) : Color.clear)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .background(VSDark.bgSidebar)
    }

    @ViewBuilder
    private var stepsAndLog: some View {
        if let job = model.selected {
            let log = model.logs[job.databaseId]
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(job.name).font(.system(size: 12, weight: .semibold)).foregroundColor(VSDark.textBright)
                    if model.loadingLog.contains(job.databaseId) { ProgressView().scaleEffect(0.4) }
                    Spacer()
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundColor(VSDark.textDim)
                    TextField("Search log", text: $search).textFieldStyle(.plain).font(.system(size: 11)).frame(width: 180)
                    if let url = job.url { Button("Open on GitHub") { openInBrowser(url) }.buttonStyle(.link).font(.system(size: 11)) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider().background(VSDark.border)
                TimelineView(.periodic(from: .now, by: job.outcome == .running ? 1 : 3600)) { _ in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if job.outcome == .running {
                                Text("The log appears when the job finishes; steps update live.")
                                    .font(.system(size: 10)).foregroundColor(VSDark.textDim).padding(8)
                            }
                            ForEach(job.steps ?? [], id: \.number) { step in
                                stepRow(step, job: job, lines: log?[step.number] ?? [])
                            }
                        }
                    }
                }
            }
            .onAppear { expandFailed(job) }
            .onChange(of: job.databaseId) { _ in expandFailed(job) }
        } else {
            emptyList(model.run == nil ? "Loading…" : "No jobs")
        }
    }

    private func expandFailed(_ job: GHJob) {
        for step in job.steps ?? [] where step.outcome == .failure { expanded.insert(job.databaseId * 1000 + step.number) }
    }

    @ViewBuilder
    private func stepRow(_ step: GHStep, job: GHJob, lines: [GHLogLine]) -> some View {
        let key = job.databaseId * 1000 + step.number
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = query.isEmpty ? lines : lines.filter { $0.text.lowercased().contains(query) }
        let isOpen = expanded.contains(key) || (!query.isEmpty && !shown.isEmpty)
        if query.isEmpty || !shown.isEmpty {
            Button(action: { if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) } }) {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 8)).foregroundColor(VSDark.textDim)
                        .frame(width: 10)
                    GitHubOutcomeIcon(outcome: step.outcome, size: 10)
                    Text(step.name).font(.system(size: 11)).foregroundColor(VSDark.text)
                    if !query.isEmpty { Text("\(shown.count)").font(.system(size: 9)).foregroundColor(VSDark.yellow) }
                    Spacer()
                    Text(GHDate.duration(step.duration)).font(.system(size: 10, design: .monospaced)).foregroundColor(VSDark.textDim)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if isOpen {
                if lines.isEmpty {
                    Text(job.outcome == .running ? "Running…" : model.loadingLog.contains(job.databaseId) ? "Loading log…" : "No output")
                        .font(.system(size: 10)).foregroundColor(VSDark.textDim).padding(.leading, 40).padding(.vertical, 2)
                } else {
                    ForEach(shown.suffix(query.isEmpty ? 5000 : 2000), id: \.index) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(line.isError ? VSDark.red : line.isWarning ? VSDark.yellow : VSDark.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 40).padding(.trailing, 12)
                            .background(line.isError ? VSDark.red.opacity(0.08) : Color.clear)
                    }
                }
            }
        }
    }
}

// MARK: Issue

struct GitHubIssueView: View {
    @ObservedObject var model: GitHubIssueModel
    @ObservedObject var gitHub: GitHubStore
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var comment = ""
    @State private var starting = false

    var body: some View {
        VStack(spacing: 0) {
            if let issue = model.issue {
                header(issue)
                if let error = model.error { errorBanner(error) }
                Divider().background(VSDark.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        post(author: issue.author?.login, date: issue.createdAt, body: issue.body ?? "")
                        ForEach(Array((issue.comments ?? []).enumerated()), id: \.offset) { _, c in
                            post(author: c.author?.login, date: c.createdAt, body: c.body)
                        }
                        commentBox(issue)
                    }
                    .padding(16)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let error = model.error {
                errorBanner(error)
                Spacer()
            } else {
                emptyList("Loading…")
            }
        }
    }

    private func header(_ issue: GHIssue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(issue.title).font(.system(size: 16, weight: .semibold)).foregroundColor(VSDark.textBright)
                    .textSelection(.enabled)
                Text("#\(issue.number)").font(.system(size: 14)).foregroundColor(VSDark.textDim)
                Spacer()
                if model.busy || starting { ProgressView().scaleEffect(0.5) }
            }
            HStack(spacing: 6) {
                Text(issue.isOpen ? "Open" : "Closed")
                    .font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(issue.isOpen ? VSDark.green.opacity(0.25) : VSDark.purple.opacity(0.25)).cornerRadius(8)
                Text("\(issue.author?.login ?? "") opened \(GHDate.ago(issue.createdAt))")
                    .font(.system(size: 11)).foregroundColor(VSDark.textDim)
                ForEach(issue.labels ?? [], id: \.self) { GitHubLabelChip(label: $0) }
                if let assignees = issue.assignees, !assignees.isEmpty {
                    Text("→ " + assignees.map(\.login).joined(separator: ", ")).font(.system(size: 11)).foregroundColor(VSDark.textDim)
                }
            }
            HStack(spacing: 12) {
                Button(action: startWithAI) { Label("Start with AI", systemImage: "sparkles") }
                    .help("Create a branch for the issue and hand it to the AI terminal")
                    .disabled(starting)
                Button(issue.isOpen ? "Close Issue" : "Reopen Issue") {
                    model.act(issue.isOpen ? "Close" : "Reopen") { try await $0.setIssueOpen(issue.number, open: !issue.isOpen) }
                }
                labelsMenu(issue)
                assigneesMenu(issue)
                Button("Open on GitHub") { openInBrowser(issue.url) }
                Spacer()
                Button(action: { model.refresh() }) { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
            .buttonStyle(.link).font(.system(size: 11)).disabled(model.busy)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func labelsMenu(_ issue: GHIssue) -> some View {
        let current = Set((issue.labels ?? []).map(\.name))
        return Menu("Labels") {
            ForEach(gitHub.labels, id: \.self) { label in
                Button((current.contains(label.name) ? "✓ " : "") + label.name) {
                    let has = current.contains(label.name)
                    model.act("Labels") { client in
                        try await client.editIssue(issue.number, addLabels: has ? [] : [label.name], removeLabels: has ? [label.name] : [])
                    }
                }
            }
            if gitHub.labels.isEmpty { Text("No labels in this repository") }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func assigneesMenu(_ issue: GHIssue) -> some View {
        let current = Set((issue.assignees ?? []).map(\.login))
        let me = gitHub.account?.login
        return Menu("Assignees") {
            if let me, !current.contains(me) {
                Button("Assign Me") { model.act("Assign") { try await $0.editIssue(issue.number, addAssignees: ["@me"]) } }
                Divider()
            }
            ForEach(gitHub.assignableUsers, id: \.self) { user in
                Button((current.contains(user) ? "✓ " : "") + user) {
                    let has = current.contains(user)
                    model.act("Assignees") { client in
                        try await client.editIssue(issue.number, addAssignees: has ? [] : [user], removeAssignees: has ? [user] : [])
                    }
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func post(author: String?, date: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(author ?? "someone").font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.text)
                Text(GHDate.ago(date)).font(.system(size: 10)).foregroundColor(VSDark.textDim)
            }
            Text(markdown(body.isEmpty ? "_No description._" : body))
                .font(.system(size: 13)).foregroundColor(VSDark.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(VSDark.bgSidebar)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(VSDark.border))
        .cornerRadius(6)
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func commentBox(_ issue: GHIssue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $comment)
                .font(.system(size: 12)).frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(VSDark.border))
            HStack {
                Spacer()
                Button("Comment") {
                    let text = comment
                    comment = ""
                    model.act("Comment") { try await $0.commentIssue(issue.number, body: text) }
                }
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            }
        }
    }

    private func startWithAI() {
        guard let issue = model.issue else { return }
        starting = true
        Task {
            let error = await workspaceManager.startIssueWithAI(issue)
            starting = false
            showError("Start with AI", error)
        }
    }
}

// MARK: - Settings

/// Settings → GitHub: the switch, the account `gh` uses, and how the integration behaves.
struct GitHubSettingsSection: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @AppStorage(GitHubSettings.enabledKey) private var enabled = false
    @AppStorage(GitHubSettings.idleIntervalKey) private var idleInterval: Double = 300
    @AppStorage(GitHubSettings.activeIntervalKey) private var activeInterval: Double = 30
    @AppStorage(GitHubSettings.notifyKey) private var notify = true
    @AppStorage(GitHubSettings.autoReviewKey) private var autoReview = true
    @State private var account: GitHubClient.Account?
    @State private var accountError: String?
    @State private var checking = false

    var body: some View {
        GroupBox("GitHub") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable GitHub integration", isOn: $enabled)
                    .onChange(of: enabled) { _ in
                        // Every window follows the setting itself (WorkspaceManager observes it).
                        if enabled { checkAccount() }
                    }
                Text("Pull requests, issues and Actions in the Git tab, and GitHub actions in the PR X-Ray. Uses the GitHub CLI (gh) and its sign-in; off, MarkView never contacts GitHub.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if enabled {
                    Divider()
                    accountRow
                    HStack {
                        Text("Repository:").font(.caption.bold())
                        Text(repositoryText).font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 16) {
                        Picker("Check Actions every", selection: $idleInterval) {
                            Text("1 min").tag(60.0); Text("5 min").tag(300.0); Text("15 min").tag(900.0)
                        }.fixedSize()
                        Picker("while running", selection: $activeInterval) {
                            Text("15 s").tag(15.0); Text("30 s").tag(30.0); Text("1 min").tag(60.0)
                        }.fixedSize()
                    }
                    Toggle("Notify when a run on my branches finishes", isOn: $notify)
                    Toggle("Start the AI review when opening a pull request for review", isOn: $autoReview)
                }
            }
            .padding(8)
        }
        .onAppear { if enabled { checkAccount() } }
    }

    private var repositoryText: String {
        if let repo = workspaceManager.gitHub.selectedRepo {
            return repo.slug + (workspaceManager.gitHub.repos.count > 1 ? " (+ \(workspaceManager.gitHub.repos.count - 1) more)" : "")
        }
        return workspaceManager.rootNode == nil ? "Open a folder with a GitHub remote." : "This folder has no GitHub remote."
    }

    private var accountRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Account:").font(.caption.bold())
                if checking {
                    ProgressView().scaleEffect(0.5)
                } else if let account {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(account.login + " (via gh)").font(.caption)
                } else {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text(accountError ?? "Not signed in").font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer()
                Button(account == nil ? "Sign In…" : "Switch Account…") { GitHubSettingsSection.openLoginInTerminal() }
                Button("Check") { checkAccount() }
            }
            if let account {
                let missing = ["repo", "workflow"].filter { !account.scopes.contains($0) }
                Text("Scopes: " + (account.scopes.isEmpty ? "—" : account.scopes.joined(separator: ", ")))
                    .font(.caption2).foregroundColor(.secondary)
                if !missing.isEmpty {
                    Text("Missing \(missing.joined(separator: ", ")): run `gh auth refresh -s \(missing.joined(separator: ","))` to run workflows and edit pull requests.")
                        .font(.caption2).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func checkAccount() {
        checking = true
        Task {
            do {
                account = try await GitHubClient.account(root: URL(fileURLWithPath: NSHomeDirectory()))
                accountError = nil
            } catch {
                account = nil
                accountError = error.localizedDescription
            }
            checking = false
        }
    }

    /// `gh auth login` in Terminal.app, like the AI CLIs' login (a `.command` file, no Apple Events).
    static func openLoginInTerminal() {
        guard let gh = GitHubClient.ghPath() else {
            showError("GitHub CLI not found", "Install it with `brew install gh`, then sign in.")
            return
        }
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MarkView", isDirectory: true)
        let script = directory.appendingPathComponent("login-github.command")
        let body = """
            #!/bin/zsh
            export PATH="\(CLIToolLocator.subprocessPath(toolPath: gh))"
            echo "Signing in to GitHub (repo, workflow and read:org access)…"
            "\(gh)" auth login --web --git-protocol https --scopes repo,workflow,read:org
            echo
            echo "Done. You can close this window."

            """
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            showError("Could not prepare the login script", error.localizedDescription)
        }
    }
}
