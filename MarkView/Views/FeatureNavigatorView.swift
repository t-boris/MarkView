import SwiftUI

/// Left panel: the file tree, or — for a folder — the feature navigator.
struct LeftPanelView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @AppStorage("layout.leftPanel") private var mode = "files"

    var body: some View {
        VStack(spacing: 0) {
            if workspaceManager.rootNode != nil {
                HStack(spacing: 0) {
                    VSDarkTabButton(title: "Files", isSelected: mode != "feature") { mode = "files" }
                    VSDarkTabButton(title: "Feature", isSelected: mode == "feature") { mode = "feature" }
                }
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(VSDark.bg)
                Divider().background(VSDark.border)
            }
            if mode == "feature", workspaceManager.rootNode != nil {
                FeatureNavigatorView(store: workspaceManager.features)
            } else {
                FileTreeView()
            }
        }
        .background(VSDark.bgSidebar)
    }
}

/// Sidebar sections of the active feature (spec §3, §29): each object opens its Markdown file.
struct FeatureNavigatorView: View {
    @ObservedObject var store: FeatureStore
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var expanded: Set<String> = ["requirement", "question", "decision"]
    @State private var history: [String] = []
    @State private var showHistory = false
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            FeaturePicker(store: store, creating: $creating)
            Divider().background(VSDark.border)
            if creating || store.features.isEmpty {
                NewFeatureForm(store: store, creating: $creating)
                Spacer()
            } else if let feature = store.active {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header(feature)
                        row(icon: "doc.text", title: "Overview", detail: nil) { open(feature.overviewURL) }
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

    private func header(_ feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(feature.title).font(.system(size: 12, weight: .semibold)).foregroundColor(VSDark.textBright).lineLimit(2)
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

/// Feature switcher with "New Feature".
struct FeaturePicker: View {
    @ObservedObject var store: FeatureStore
    @Binding var creating: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 10)).foregroundColor(VSDark.blue)
            Menu {
                ForEach(store.features) { feature in
                    Button(feature.title) { store.activeSlug = feature.slug; creating = false }
                }
                if !store.features.isEmpty { Divider() }
                Button("New Feature…") { creating = true }
            } label: {
                Text(store.active?.title ?? "No features").font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Button(action: { creating = true }) {
                Image(systemName: "plus").font(.system(size: 10)).foregroundColor(VSDark.textDim)
            }.buttonStyle(.plain).help("New feature")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

/// Create a feature from an idea (spec §6); guided discovery starts right away.
struct NewFeatureForm: View {
    @ObservedObject var store: FeatureStore
    @Binding var creating: Bool
    @State private var title = ""
    @State private var idea = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New feature").font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.textBright)
            TextField("Name, e.g. WhatsApp Mirroring", text: $title)
                .textFieldStyle(.plain).font(.system(size: 11))
                .padding(5).background(VSDark.bgInput).cornerRadius(4)
            Text("The idea, in your own words").font(.system(size: 10)).foregroundColor(VSDark.textDim)
            TextEditor(text: $idea)
                .font(.system(size: 11)).frame(minHeight: 90, maxHeight: 160)
                .scrollContentBackground(.hidden).background(VSDark.bgInput).cornerRadius(4)
            HStack {
                if creating && !store.features.isEmpty { Button("Cancel") { creating = false }.buttonStyle(.link).font(.system(size: 11)) }
                Spacer()
                Button("Create & Explore") {
                    guard let slug = store.createFeature(title: title.trimmingCharacters(in: .whitespaces),
                                                         idea: idea.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                    creating = false
                    title = ""; idea = ""
                    UserDefaults.standard.set(FeatureStage.explore.rawValue, forKey: FeatureStage.storageKey)
                    Task { await store.assistant.exploreNext(slug) }
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                .font(.system(size: 11))
            }
            Text("Stored as Markdown in docs/features/<name>/ — overview, requirements, questions, decisions…")
                .font(.system(size: 9)).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
    }
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
            Text(footnote).font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failed { Text(failed).font(.caption).foregroundColor(.red).textSelection(.enabled) }
            HStack {
                if working {
                    ProgressView().scaleEffect(0.6)
                    Text(kind == .understand ? "Researching the project… this can take a few minutes." : "Analyzing…")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(kind == .understand ? "Research" : "Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
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
        case .understand: return "The answer is written to docs/research/RES-nnn-….md and opened."
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
        working = true
        failed = nil
        Task {
            let outcome: FeatureAssistant.IntakeOutcome?
            switch kind {
            case .feature: outcome = await assistant.newFeature(from: input, attachments: attachments, linkedIssue: linkedIssue)
            case .bug: outcome = await assistant.newBug(from: input, attachments: attachments, linkedIssue: linkedIssue,
                                                        commentOnIssue: commentOnIssue)
            case .understand: outcome = await assistant.understand(input, attachments: attachments)
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
