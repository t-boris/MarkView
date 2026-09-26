import SwiftUI

/// Left panel: the file tree, or — when the project has docs/features or docs/bugs — its issues:
/// features and bugs, each with its GitHub issue.
struct LeftPanelView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        LeftPanelContent(store: workspaceManager.features)
    }
}

private struct LeftPanelContent: View {
    @ObservedObject var store: FeatureStore
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @AppStorage("layout.leftPanel") private var mode = "files"
    /// The feature opened from the Issues list ("" = the list); kept so "New Feature" can open it.
    @AppStorage("layout.issuesFeature") private var openFeatureSlug = ""
    private var openFeature: String? {
        get { openFeatureSlug.isEmpty ? nil : openFeatureSlug }
        nonmutating set { openFeatureSlug = newValue ?? "" }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.hasIssues {
                HStack(spacing: 0) {
                    VSDarkTabButton(title: "Files", isSelected: mode != "issues") { mode = "files" }
                    VSDarkTabButton(title: "Issues", isSelected: mode == "issues") { mode = "issues" }
                }
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(VSDark.bg)
                Divider().background(VSDark.border)
            }
            if mode == "issues", store.hasIssues {
                if let slug = openFeature, store.feature(slug) != nil {
                    FeatureNavigatorView(store: store, onBack: { openFeature = nil })
                } else {
                    IssuesListView(store: store) { slug in
                        store.activeSlug = slug
                        openFeature = slug
                    }
                }
            } else {
                FileTreeView()
            }
        }
        .background(VSDark.bgSidebar)
    }
}

/// Features (docs/features/*) and bugs (docs/bugs/*.md) of the project.
struct IssuesListView: View {
    @ObservedObject var store: FeatureStore
    let open: (String) -> Void
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var filter = ""
    @State private var showFeatures = true
    @State private var showBugs = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                TextField("Filter", text: $filter).textFieldStyle(.plain).font(.system(size: 11))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider().background(VSDark.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let features = store.features.filter { matches($0.title + " " + $0.slug) }
                    sectionHeader("Features", count: features.count, expanded: $showFeatures, kind: .feature)
                    if showFeatures {
                        ForEach(features) { feature in
                            Button(action: { open(feature.slug) }) {
                                HStack(spacing: 5) {
                                    Image(systemName: feature.isStructured ? "square.stack.3d.up" : "doc.text")
                                        .font(.system(size: 9)).foregroundColor(VSDark.blue).frame(width: 12)
                                    Text(feature.title).font(.system(size: 11)).foregroundColor(VSDark.text).lineLimit(1)
                                    Spacer(minLength: 2)
                                    IssueLinks(numbers: feature.issueNumbers)
                                    Text(FeatureVocabulary.label(feature.status)).font(.system(size: 8)).foregroundColor(VSDark.textDim)
                                }
                                .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(feature.slug)
                        }
                    }
                    let bugs = store.bugs.filter { matches($0.title + " " + $0.key) }
                    sectionHeader("Bugs", count: bugs.count, expanded: $showBugs, kind: .bug)
                    if showBugs {
                        ForEach(bugs) { bug in
                            Button(action: { workspaceManager.openFile(bug.url) }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "ladybug").font(.system(size: 9))
                                        .foregroundColor(["critical", "high"].contains(bug.severity) ? VSDark.red : VSDark.orange).frame(width: 12)
                                    Text(bug.key).font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                                    Text(bug.title).font(.system(size: 11)).foregroundColor(bug.status == "open" ? VSDark.text : VSDark.textDim).lineLimit(1)
                                    Spacer(minLength: 2)
                                    IssueLinks(numbers: bug.issueNumbers)
                                }
                                .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(bug.key) · \(bug.status)\(bug.severity.isEmpty ? "" : " · \(bug.severity)")")
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }

    private func matches(_ text: String) -> Bool {
        filter.isEmpty || text.localizedCaseInsensitiveContains(filter)
    }

    private func sectionHeader(_ title: String, count: Int, expanded: Binding<Bool>, kind: IntakeKind) -> some View {
        HStack(spacing: 5) {
            Button(action: { expanded.wrappedValue.toggle() }) {
                HStack(spacing: 5) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 8)).foregroundColor(VSDark.textDim).frame(width: 10)
                    Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundColor(VSDark.textDim)
                    Text("\(count)").font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                }
            }.buttonStyle(.plain)
            Spacer()
            Button(action: { workspaceManager.intake = IntakeRequest(kind: kind) }) {
                Image(systemName: "plus").font(.system(size: 9)).foregroundColor(VSDark.textDim)
            }.buttonStyle(.plain).help(kind.title)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}

/// "#12 #40": the GitHub issues something refers to, each opening the issue.
struct IssueLinks: View {
    let numbers: [Int]
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        HStack(spacing: 3) {
            ForEach(numbers.prefix(3), id: \.self) { number in
                Button("#\(number)") { workspaceManager.openGitHubIssue(number) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(VSDark.blue)
                    .help("Open GitHub issue #\(number)")
            }
        }
    }
}

/// Sidebar sections of the active feature (spec §3, §29): each object opens its Markdown file.
struct FeatureNavigatorView: View {
    @ObservedObject var store: FeatureStore
    var onBack: (() -> Void)? = nil
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var expanded: Set<String> = ["requirement", "question", "decision", "documents"]
    @State private var history: [String] = []
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 9))
                        Text("Issues").font(.system(size: 11))
                        Spacer()
                    }
                    .foregroundColor(VSDark.blue)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider().background(VSDark.border)
            }
            if let feature = store.active {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header(feature)
                        if feature.isStructured {
                            row(icon: "doc.text", title: "Overview", detail: nil) { open(feature.overviewURL) }
                        }
                        documentsSection(feature)
                        ForEach(FeatureObjectKind.allCases, id: \.self) { kind in section(kind, feature) }
                        row(icon: "hammer", title: "Implementation", detail: feature.planIssues.isEmpty ? nil : "\(feature.planIssues.count)") {
                            if FileManager.default.fileExists(atPath: feature.planURL.path) { open(feature.planURL) }
                        }
                        row(icon: "bubble.left.and.bubble.right", title: "Discussion", detail: nil) {
                            if FileManager.default.fileExists(atPath: feature.discussionURL.path) { open(feature.discussionURL) }
                        }
                        historySection(feature)
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .background(VSDark.bgSidebar)
    }

    @ViewBuilder
    private func documentsSection(_ feature: Feature) -> some View {
        if !feature.documents.isEmpty {
            let isExpanded = expanded.contains("documents")
            Button(action: { if isExpanded { expanded.remove("documents") } else { expanded.insert("documents") } }) {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 8)).foregroundColor(VSDark.textDim).frame(width: 10)
                    Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(VSDark.blue).frame(width: 14)
                    Text("Documents").font(.system(size: 11, weight: .medium)).foregroundColor(VSDark.text)
                    Spacer()
                    Text("\(feature.documents.count)").font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if isExpanded {
                ForEach(feature.documents, id: \.self) { url in
                    Button(action: { open(url) }) {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                            Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 11))
                                .foregroundColor(isActive(url) ? VSDark.textBright : VSDark.text).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 28).padding(.trailing, 8).padding(.vertical, 2)
                        .background(isActive(url) ? VSDark.selection.opacity(0.35) : Color.clear)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func header(_ feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(feature.title).font(.system(size: 12, weight: .semibold)).foregroundColor(VSDark.textBright).lineLimit(2)
            if !feature.issueNumbers.isEmpty { IssueLinks(numbers: feature.issueNumbers) }
            HStack(spacing: 6) {
                FeatureStatusMenu(store: store, feature: feature)
                Spacer()
                Text("\(feature.readiness)%").font(.system(size: 10, design: .monospaced)).foregroundColor(VSDark.textDim)
            }
            ReadinessBar(value: feature.readiness)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder
    private func section(_ kind: FeatureObjectKind, _ feature: Feature) -> some View {
        let objects = feature.list(kind)
        let openCount = objects.filter { !$0.isClosed }.count
        let isExpanded = expanded.contains(kind.rawValue)
        Button(action: {
            if isExpanded { expanded.remove(kind.rawValue) } else { expanded.insert(kind.rawValue) }
        }) {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 8)).foregroundColor(VSDark.textDim).frame(width: 10)
                Image(systemName: kind.icon).font(.system(size: 10)).foregroundColor(VSDark.blue).frame(width: 14)
                Text(kind.title).font(.system(size: 11, weight: .medium)).foregroundColor(VSDark.text)
                Spacer()
                if !objects.isEmpty {
                    Text(openCount > 0 && openCount != objects.count ? "\(openCount)/\(objects.count)" : "\(objects.count)")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if isExpanded {
            ForEach(objects) { object in
                Button(action: { open(object.url) }) {
                    HStack(spacing: 5) {
                        FeatureStatusDot(object: object)
                        Text(object.id).font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                        Text(object.title).font(.system(size: 11)).foregroundColor(isActive(object.url) ? VSDark.textBright : VSDark.text).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 28).padding(.trailing, 8).padding(.vertical, 2)
                    .background(isActive(object.url) ? VSDark.selection.opacity(0.35) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(object.id) · \(object.status)")
            }
        }
    }

    private func row(icon: String, title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Color.clear.frame(width: 10)
                Image(systemName: icon).font(.system(size: 10)).foregroundColor(VSDark.blue).frame(width: 14)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(VSDark.text)
                Spacer()
                if let detail { Text(detail).font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim) }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func historySection(_ feature: Feature) -> some View {
        Button(action: {
            showHistory.toggle()
            if showHistory { Task { history = await store.history(of: feature.folder, limit: 25) } }
        }) {
            HStack(spacing: 5) {
                Image(systemName: showHistory ? "chevron.down" : "chevron.right").font(.system(size: 8)).foregroundColor(VSDark.textDim).frame(width: 10)
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 10)).foregroundColor(VSDark.blue).frame(width: 14)
                Text("History").font(.system(size: 11, weight: .medium)).foregroundColor(VSDark.text)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if showHistory {
            if history.isEmpty {
                Text("No commits yet").font(.system(size: 10)).foregroundColor(VSDark.textDim).padding(.leading, 28)
            }
            ForEach(history, id: \.self) { line in
                Text(line).font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                    .lineLimit(2).padding(.leading, 28).padding(.trailing, 8).padding(.vertical, 1)
                    .textSelection(.enabled)
            }
        }
    }

    private func isActive(_ url: URL) -> Bool {
        workspaceManager.activeTab?.url.standardizedFileURL == url.standardizedFileURL
    }

    private func open(_ url: URL) { workspaceManager.openFile(url) }
}

struct FeatureStatusMenu: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature

    var body: some View {
        Menu {
            ForEach(FeatureVocabulary.featureStatuses, id: \.self) { status in
                Button((status == feature.status ? "✓ " : "") + FeatureVocabulary.label(status)) {
                    store.updateFeature(feature.slug) { front, _ in front.set("status", status) }
                }
            }
        } label: {
            Text(FeatureVocabulary.label(feature.status)).font(.system(size: 10, weight: .semibold))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Feature status — how mature the specification is")
    }
}

struct ReadinessBar: View {
    let value: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(VSDark.bgInput)
                RoundedRectangle(cornerRadius: 2).fill(value >= 80 ? VSDark.green : value >= 50 ? VSDark.yellow : VSDark.orange)
                    .frame(width: geometry.size.width * CGFloat(value) / 100)
            }
        }
        .frame(height: 4)
    }
}

/// Status of an object as a coloured dot.
struct FeatureStatusDot: View {
    let object: FeatureObject

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }

    private var color: Color {
        switch object.status {
        case "approved", "accepted", "answered", "resolved": return VSDark.green
        case "rejected", "dismissed", "superseded": return VSDark.textDim
        case "deferred", "accepted-risk": return VSDark.purple
        case "review", "discussing", "proposed": return VSDark.yellow
        default:
            if object.kind == .finding {
                return ["blocker", "high"].contains(object.front.string("severity")) ? VSDark.red : VSDark.orange
            }
            if object.isBlocking { return VSDark.red }
            return VSDark.blue
        }
    }
}

/// "New Feature / New Bug / I Need to Understand": write everything you know, add files,
/// the AI does the rest (feature files + GitHub issue, bug report + GitHub issue, researched answer).
struct IntakeSheet: View {
    let request: IntakeRequest
    private var kind: IntakeKind { request.kind }
    @ObservedObject var workspaceManager: WorkspaceManager
    @ObservedObject var assistant: FeatureAssistant
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var attachments: [URL] = []
    @State private var working = false
    @State private var failed: String?
    @State private var dropping = false
    /// Started from an existing GitHub issue (no new issue is filed).
    @State private var linkedIssue: Int?
    @State private var commentOnIssue = false
    @State private var picking = false
    @State private var issueFilter = ""
    @State private var loadingSource = false

    init(request: IntakeRequest, workspaceManager: WorkspaceManager) {
        self.request = request
        self.workspaceManager = workspaceManager
        self.assistant = workspaceManager.features.assistant
        _text = State(initialValue: request.text)
        _attachments = State(initialValue: request.attachments)
        _linkedIssue = State(initialValue: request.linkedIssue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).foregroundColor(VSDark.blue)
                Text(kind.title).font(.headline)
            }
            Text(kind.prompt).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minWidth: 560, minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(dropping ? VSDark.blue : VSDark.border, lineWidth: dropping ? 2 : 1))
                .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            if let url { Task { @MainActor in attachments.append(url) } }
                        }
                    }
                    return true
                }
            if kind != .understand, workspaceManager.gitHub.isAvailable {
                HStack(spacing: 8) {
                    Button("From GitHub Issue…") {
                        picking = true
                        if workspaceManager.gitHub.issues.isEmpty { workspaceManager.gitHub.refreshIssues() }
                    }
                    .popover(isPresented: $picking) { issuePicker }
                    if let linkedIssue {
                        HStack(spacing: 3) {
                            Text("Linked to #\(linkedIssue) — no new issue is filed").font(.caption)
                            Button(action: { self.linkedIssue = nil }) { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundColor(.secondary)
                        }
                        if kind == .bug { Toggle("Add the analysis to #\(linkedIssue) as a comment", isOn: $commentOnIssue).font(.caption) }
                    }
                    Spacer()
                }
            }
            if kind != .understand {
            HStack(spacing: 6) {
                Button("Add Files…") { chooseFiles() }
                ForEach(attachments, id: \.self) { url in
                    HStack(spacing: 2) {
                        Text(url.lastPathComponent).font(.caption).lineLimit(1)
                        Button(action: { attachments.removeAll { $0 == url } }) { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2).background(VSDark.bgInput).cornerRadius(4)
                }
                Spacer()
            }
            }
            Text(footnote).font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failed { Text(failed).font(.caption).foregroundColor(.red).textSelection(.enabled) }
            HStack {
                if loadingSource {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading \(request.loadIssue.map { "#\($0)" } ?? request.loadPullRequest.map { "PR #\($0)" } ?? "")…")
                        .font(.caption).foregroundColor(.secondary)
                }
                if working {
                    ProgressView().scaleEffect(0.6)
                    Text("Analyzing…")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(kind == .understand ? "Show in X-Ray" : "Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || loadingSource || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .task { await loadRequestedSource() }
    }

    /// The issue or pull request the sheet was opened from: its text becomes the material.
    private func loadRequestedSource() async {
        guard let client = workspaceManager.gitHub.client else { return }
        if let number = request.loadIssue {
            loadingSource = true
            defer { loadingSource = false }
            do {
                let issue = try await client.issue(number)
                var material = "GitHub issue #\(number): \(issue.title)\n\n\(issue.body ?? "")"
                let comments = issue.comments ?? []
                if !comments.isEmpty {
                    material += "\n\nComments:\n\n" + comments.map { "\($0.author?.login ?? "someone"): \($0.body)" }.joined(separator: "\n\n")
                }
                text = material
            } catch { failed = "Could not read #\(number): \(error.localizedDescription)" }
        } else if let number = request.loadPullRequest {
            loadingSource = true
            defer { loadingSource = false }
            let body = (try? await client.gh(["pr", "view", String(number), "-R", client.repo.slug, "--json", "body", "-q", ".body"])) ?? ""
            if !body.isEmpty { text += "\n\n" + body }
        }
    }

    /// Open issues of the repository; picking one puts its text and comments into the editor.
    private var issuePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter issues", text: $issueFilter).textFieldStyle(.roundedBorder)
            let issues = workspaceManager.gitHub.issues.filter {
                issueFilter.isEmpty || "#\($0.number) \($0.title)".localizedCaseInsensitiveContains(issueFilter)
            }
            if issues.isEmpty {
                Text(workspaceManager.gitHub.loadingIssues ? "Loading…" : "No open issues").font(.caption).foregroundColor(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(issues) { issue in
                        Button(action: { load(issue.number) }) {
                            HStack(spacing: 5) {
                                Text("#\(issue.number)").font(.system(size: 11, design: .monospaced)).foregroundColor(VSDark.blue)
                                Text(issue.title).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 420, height: 280)
        }
        .padding(10)
    }

    /// The issue's text and comments become the material; the result links to the issue.
    private func load(_ number: Int) {
        picking = false
        guard let client = workspaceManager.gitHub.client else { return }
        Task {
            do {
                let issue = try await client.issue(number)
                var material = "GitHub issue #\(number): \(issue.title)\n\n\(issue.body ?? "")"
                let comments = issue.comments ?? []
                if !comments.isEmpty {
                    material += "\n\nComments:\n\n" + comments.map { "\($0.author?.login ?? "someone"): \($0.body)" }.joined(separator: "\n\n")
                }
                text = material + (text.isEmpty ? "" : "\n\n---\n\n" + text)
                linkedIssue = number
            } catch {
                failed = "Could not read #\(number): \(error.localizedDescription)"
            }
        }
    }

    private var icon: String {
        switch kind { case .feature: return "sparkles"; case .bug: return "ladybug"; case .understand: return "magnifyingglass" }
    }

    private var footnote: String {
        let github = workspaceManager.gitHub.isAvailable
        switch kind {
        case .feature: return "Creates docs/features/<name>/ (overview, first requirements and questions, your text as a source)" + (github ? " and a GitHub issue." : ". Turn on the GitHub integration to also file an issue.")
        case .bug: return "Writes docs/bugs/BUG-nnn-….md with reproduction steps and the suspected code" + (github ? ", and files it on GitHub." : ". Turn on the GitHub integration to also file it on GitHub.")
        case .understand: return "Opens the X-Ray: related parts are marked in every view, the answer and the places are on the right; a file opened from there shows the places inside it."
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        attachments += panel.urls
    }

    private func submit() {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .understand {
            dismiss()
            workspaceManager.understandInXRay(input)
            return
        }
        working = true
        failed = nil
        Task {
            let outcome: FeatureAssistant.IntakeOutcome?
            switch kind {
            case .feature: outcome = await assistant.newFeature(from: input, attachments: attachments, linkedIssue: linkedIssue)
            case .bug: outcome = await assistant.newBug(from: input, attachments: attachments, linkedIssue: linkedIssue,
                                                        commentOnIssue: commentOnIssue)
            case .understand: outcome = nil
            }
            working = false
            guard let outcome else {
                failed = assistant.error ?? "The assistant did not answer."
                return
            }
            dismiss()
            workspaceManager.intakeFinished(kind, outcome: outcome)
        }
    }
}
