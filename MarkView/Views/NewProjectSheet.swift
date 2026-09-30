import SwiftUI

// MARK: - Start a Project from Scratch

/// Idea → clarification → confirmed brief → destination → local project → optional GitHub
/// (docs/features/start-a-project-from-scratch). Closing the sheet keeps the draft; the welcome
/// screen resumes or discards it (DEC-015).
struct NewProjectSheet: View {
    @ObservedObject var workspaceManager: WorkspaceManager
    @StateObject private var flow: NewProjectFlow
    @Environment(\.dismiss) private var dismiss
    @State private var idea = ""
    @State private var attachments: [URL] = []
    @State private var editorFocused = false
    @State private var confirmingDiscard = false
    @State private var publisher: GitHubPublisher?

    init(request: NewProjectRequest, workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        _flow = StateObject(wrappedValue: NewProjectFlow(resume: request.resume))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch flow.step {
            case .idea: ideaStep
            case .clarify: ClarifyStep(flow: flow, store: flow.store, workspaceManager: workspaceManager)
            case .destination: destinationStep
            case .github(let url): githubStep(url)
            }
            if let error = flow.error {
                Text(error).uiFont(.caption).foregroundColor(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .frame(width: 680)
        .frame(minHeight: 460)
        .confirmationDialog("Discard this project draft?", isPresented: $confirmingDiscard) {
            Button("Discard Draft", role: .destructive) {
                Task { await flow.discard(); dismiss() }
            }
        } message: {
            Text("The idea and everything clarified so far are deleted. No project folder was created.")
        }
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sparkles.rectangle.stack").foregroundColor(VSDark.blue)
                Text(flow.draft.map { $0.title.isEmpty ? "New Project" : $0.title } ?? "New Project").uiFont(.headline)
                Spacer()
            }
            HStack(spacing: 4) {
                ForEach(Array(["Idea", "Clarify", "Create", "GitHub"].enumerated()), id: \.offset) { index, name in
                    Text("\(index + 1) \(name)")
                        .uiFont(size: 10, weight: index == stepIndex ? .bold : .regular)
                        .foregroundColor(index == stepIndex ? VSDark.textBright : index < stepIndex ? VSDark.green : VSDark.textDim)
                    if index < 3 { Image(systemName: "chevron.right").uiFont(size: 8).foregroundColor(VSDark.textDim) }
                }
            }
        }
    }

    private var stepIndex: Int {
        switch flow.step {
        case .idea: return 0
        case .clarify: return 1
        case .destination: return 2
        case .github: return 3
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if flow.working {
                ProgressView().scaleEffect(0.6)
                Text(flow.step == .destination ? "Creating the project…" : "Analyzing the idea…").uiFont(.caption).foregroundColor(.secondary)
            }
            if flow.draft != nil, flow.step == .clarify || flow.step == .destination {
                Button("Discard Draft…") { confirmingDiscard = true }.disabled(flow.working)
            }
            Spacer()
            switch flow.step {
            case .idea:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") { Task { await flow.start(idea: idea, attachments: attachments) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.working || idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .clarify:
                Button("Continue Later") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Confirm Brief") { Task { await flow.confirm() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canConfirm || flow.working || assistantBusy)
                    .help(flow.canConfirm ? "The brief is clear: choose where to create the project" : "Answer the blocking questions first")
            case .destination:
                Button("Back to Clarification") { Task { await flow.reopenClarification() } }
                    .disabled(flow.working || flow.creationLocked)
                Button("Continue Later") { dismiss() }.keyboardShortcut(.cancelAction).disabled(flow.working)
                Button(flow.creationLocked ? "Retry" : "Create Project") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.working || destinationProblem != nil)
            case .github:
                if publisher == nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    private var assistantBusy: Bool { !flow.assistant.running.isEmpty || !flow.assistant.preparing.isEmpty }

    // MARK: 1 Idea (REQ-001)

    private var ideaStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe what you want to build — a sentence is enough. MarkView asks what it needs to know, you confirm the brief, and only then is a project folder created. GitHub is optional.")
                .uiFont(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            IntakeTextEditor(text: $idea, focused: $editorFocused, attach: { urls in
                attachments += urls.filter { !attachments.contains($0) }
            }, failed: { flow.error = $0 })
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(VSDark.border, lineWidth: 1))
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { url in
                            HStack(spacing: 2) {
                                IntakeAttachmentThumbnail(url: url)
                                Text(url.lastPathComponent).uiFont(.caption).lineLimit(1)
                                Button(action: { attachments.removeAll { $0 == url } }) { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 5).padding(.vertical, 2).background(VSDark.bgInput).cornerRadius(4)
                        }
                    }
                }
            }
            Text("The draft is kept on this Mac until the project is created; you can continue it later from the welcome screen.")
                .uiFont(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: 3 Destination (REQ-004, DEC-009)

    private var destination: URL { flow.parentFolder.appendingPathComponent(flow.folderName, isDirectory: true) }

    private var destinationProblem: String? {
        if let problem = ProjectNaming.folderNameProblem(flow.folderName) { return problem }
        if flow.draft?.createdPath != destination.path, FileManager.default.fileExists(atPath: destination.path) {
            return "“\(flow.folderName)” already exists there. Choose another name or location — nothing in it will be changed."
        }
        return nil
    }

    private var destinationStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let feature = flow.feature {
                BriefSummary(feature: feature, goal: flow.goal, compact: true)
            }
            Divider()
            HStack {
                Text("Create in").frame(width: 80, alignment: .leading)
                Text(flow.parentFolder.path).uiFont(size: 11, design: .monospaced).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseParent() }.disabled(flow.working || flow.creationLocked)
            }
            HStack {
                Text("Folder name").frame(width: 80, alignment: .leading)
                TextField("project-name", text: $flow.folderName).textFieldStyle(.roundedBorder)
                    .disabled(flow.working || flow.creationLocked)
            }
            if let problem = destinationProblem {
                Text(problem).uiFont(.caption).foregroundColor(VSDark.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(destination.path).uiFont(size: 10, design: .monospaced).foregroundColor(.secondary).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("MarkView creates:").uiFont(.caption, weight: .semibold)
                Group {
                    Text("• README.md — the brief, with a link to the specification")
                    if let feature = flow.feature {
                        Text("• docs/features/\(feature.slug)/ — the brief, \(Self.count(feature.list(.decision).count, "decision")), \(Self.count(feature.activeRequirements.count, "requirement")), \(Self.count(flow.openQuestions.count, "open question"))")
                    }
                    Text("• .gitignore — keeps MarkView's local .dde/ folder out of Git")
                    Text("• a local Git repository; nothing is committed until you publish")
                }
                .uiFont(.caption).foregroundColor(.secondary)
            }
            if let draft = flow.draft, let created = draft.createdPath {
                Text("Creation stopped at \(created). Retry continues in that folder; nothing else is touched.")
                    .uiFont(.caption).foregroundColor(VSDark.orange).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = flow.parentFolder
        panel.prompt = "Choose"
        panel.message = "Choose the folder the new project is created in"
        if panel.runModal() == .OK, let url = panel.url { flow.parentFolder = url }
    }

    private func create() {
        Task {
            guard let slug = flow.draft?.slug, let url = await flow.create() else { return }
            workspaceManager.openCreatedProject(url, specification: slug)
        }
    }

    // MARK: 4 GitHub (REQ-003)

    @ViewBuilder
    private func githubStep(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundColor(VSDark.green)
                Text("Project created").uiFont(size: 13, weight: .semibold)
            }
            Text(url.path).uiFont(size: 11, design: .monospaced).textSelection(.enabled)
            Text("It is open in this window with its specification. A local Git repository is initialized; the files are not committed yet.")
                .uiFont(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if let publisher {
                GitHubPublishView(publisher: publisher) { self.publisher = nil; dismiss() }
            } else {
                Text("Connect it to GitHub? (optional)").uiFont(size: 12, weight: .semibold)
                Text("You choose the owner, the name and the visibility, and review the first commit before anything is published. You can also do this later: Git tab › Publish to GitHub…, or File › Publish to GitHub….")
                    .uiFont(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Connect to GitHub…") {
                    let manager = workspaceManager
                    let publisher = GitHubPublisher(root: url) { [weak manager] slug in
                        // nil from activateGitHub is success: only a missing window is an error here.
                        guard let manager else { return "The window was closed." }
                        return await manager.activateGitHub(expecting: slug, in: url)
                    }
                    self.publisher = publisher
                    Task { await publisher.prepare() }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Step 2: the adaptive dialogue (REQ-002) — the brief so far, the current question with the
/// discovery's own card, and what still blocks confirmation (DEC-016).
private struct ClarifyStep: View {
    @ObservedObject var flow: NewProjectFlow
    @ObservedObject var store: FeatureStore
    let workspaceManager: WorkspaceManager

    var body: some View {
        if let feature = flow.feature {
            ClarifyContent(flow: flow, store: store, assistant: flow.assistant, feature: feature)
                .environmentObject(flow.assistant)
                .environmentObject(workspaceManager)
        } else if flow.working {
            VStack(spacing: 8) {
                Spacer()
                ProgressView()
                Text("Reading your idea and preparing the first questions…").uiFont(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("The idea is saved, but it has not been analyzed yet.").uiFont(.caption)
                Text(flow.draft?.idea ?? "").uiFont(.caption).foregroundColor(.secondary).lineLimit(6)
                Button("Analyze Again") { Task { await flow.analyze() } }
                Spacer()
            }
        }
    }
}

private struct ClarifyContent: View {
    @ObservedObject var flow: NewProjectFlow
    @ObservedObject var store: FeatureStore
    @ObservedObject var assistant: FeatureAssistant
    let feature: Feature

    private var slug: String { feature.slug }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                BriefSummary(feature: feature, goal: flow.goal, compact: false)
                if let error = assistant.error {
                    Text(error).uiFont(.caption).foregroundColor(.red).textSelection(.enabled)
                }
                if assistant.isRunning("decide:" + slug) {
                    Working(text: "AI is deciding the remaining questions…")
                } else if assistant.isRunning("explore:" + slug) {
                    Working(text: "Looking at what is still unclear…")
                } else if !feature.openQuestions.isEmpty {
                    // What blocks the brief comes first (DEC-016); the round answers all at once.
                    QuestionRound(store: store, feature: feature, questions: feature.openQuestions)
                } else if !feature.isUnderstood {
                    HStack {
                        Text("No open question.").uiFont(size: 10).foregroundColor(VSDark.textDim)
                        Spacer()
                        SmallButton(title: "Ask more questions", icon: "sparkles", prominent: true) {
                            Task { await assistant.exploreNext(slug) }
                        }
                    }
                } else {
                    HStack {
                        Text("The project is clear enough to confirm.").uiFont(size: 10).foregroundColor(VSDark.green)
                        Spacer()
                        SmallButton(title: "Ask more questions", icon: "sparkles") {
                            Task { await assistant.exploreNext(slug) }
                        }
                    }
                }
                confirmation
            }
            .padding(.trailing, 6)
        }
        .frame(minHeight: 320)
    }

    @ViewBuilder
    private var confirmation: some View {
        let blockers = ProjectConfirmation.blockers(flow.openQuestions)
        let later = flow.openQuestions.count - blockers.count
        VStack(alignment: .leading, spacing: 4) {
            if flow.goal.isEmpty {
                Text("The goal is not written yet.").uiFont(size: 10).foregroundColor(VSDark.orange)
            }
            if !blockers.isEmpty {
                Text("Answer before confirming (needed for the brief):").uiFont(size: 10, weight: .semibold).foregroundColor(VSDark.orange)
                ForEach(blockers, id: \.id) { q in
                    Text("• \(q.id) \(q.title)").uiFont(size: 10).foregroundColor(VSDark.text)
                }
            }
            if later > 0 {
                Text("\(later) open question\(later == 1 ? "" : "s") can wait — \(later == 1 ? "it goes" : "they go") into the project for later.")
                    .uiFont(size: 10).foregroundColor(VSDark.textDim)
            }
            if !feature.isUnderstood && !assistant.isRunning("decide:" + slug) {
                HStack(alignment: .top, spacing: 6) {
                    Text("Enough questions? AI decides the rest as proposed decisions you can review in the project.")
                        .uiFont(size: 9).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    SmallButton(title: "Decide the rest", icon: "flag.checkered") {
                        Task { await assistant.decideRest(slug) }
                    }
                }
            }
        }
        .padding(8).background(VSDark.bgInput.opacity(0.5)).cornerRadius(5)
    }
}

/// The brief as it will be confirmed: goal, problem, scope, requirements and decisions.
private struct BriefSummary: View {
    let feature: Feature
    let goal: String
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Brief").uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.textBright)
            field("Goal", goal)
            if !compact {
                field("Problem", ProjectFoundation.section("Problem", of: feature.overviewBody))
                field("Scope", ProjectFoundation.section("Scope", of: feature.overviewBody))
                let requirements = feature.activeRequirements
                if !requirements.isEmpty {
                    Text("Requirements").uiFont(size: 10, weight: .semibold).foregroundColor(VSDark.text)
                    ForEach(requirements, id: \.id) { r in
                        Text("• \(r.id) \(r.title)").uiFont(size: 10).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
                let decisions = feature.list(.decision).filter { $0.status != "superseded" && $0.status != "cancelled" }
                if !decisions.isEmpty {
                    Text("Decisions").uiFont(size: 10, weight: .semibold).foregroundColor(VSDark.text)
                    ForEach(decisions, id: \.id) { d in
                        Text("• \(d.id) \(d.title)" + (d.status == "proposed" ? " (proposed)" : ""))
                            .uiFont(size: 10).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(VSDark.bgInput.opacity(0.5)).cornerRadius(5)
    }

    @ViewBuilder
    private func field(_ title: String, _ text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).uiFont(size: 10, weight: .semibold).foregroundColor(VSDark.text)
                Text(text).uiFont(size: 10).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Publish to GitHub

/// Create or connect a GitHub repository and publish the project (REQ-003): shown after
/// bootstrap and, for any folder, from the Git tab or File › Publish to GitHub….
struct GitHubPublishView: View {
    @ObservedObject var publisher: GitHubPublisher
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch publisher.phase {
            case .loading:
                HStack { ProgressView().scaleEffect(0.6); Text("Checking GitHub…").uiFont(.caption) }
            case .needsSignIn(let message):
                Text(message).uiFont(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Sign In to GitHub…") { GitHubSettingsSection.openLoginInTerminal() }
                    Button("Check Again") { Task { await publisher.prepare() } }
                    Spacer()
                    Button("Close", action: close)
                }
            case .blocked(let message):
                Text(message).uiFont(.caption).foregroundColor(VSDark.orange).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Close", action: close) }
            case .choose, .checking:
                choices
            case .confirm:
                confirmation
            case .publishing:
                HStack { ProgressView().scaleEffect(0.6); Text(publisher.progress).uiFont(.caption) }
            case .done(let slug):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(VSDark.green)
                    Text("Connected to github.com/\(slug)").uiFont(size: 12, weight: .semibold)
                }
                Text("The first commit is pushed, the branch tracks origin, and MarkView's GitHub features are on for this folder (Git tab).")
                    .uiFont(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open on GitHub") { if let url = URL(string: "https://github.com/\(slug)") { NSWorkspace.shared.open(url) } }
                    Spacer()
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Text(message).uiFont(.caption).foregroundColor(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("What already happened is kept: Retry continues with the same repository and never creates a second one.")
                    .uiFont(.caption2).foregroundColor(.secondary)
                HStack {
                    Spacer()
                    Button("Close", action: close)
                    Button("Retry") { Task { await publisher.retry() } }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signed in as \(publisher.account)").uiFont(.caption).foregroundColor(.secondary)
            HStack {
                Text("Owner").frame(width: 70, alignment: .leading)
                Picker("", selection: $publisher.owner) {
                    ForEach(publisher.owners, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 220)
                .disabled(publisher.lockedTarget)
                Spacer()
            }
            HStack {
                Text("Name").frame(width: 70, alignment: .leading)
                TextField("repository", text: $publisher.name).textFieldStyle(.roundedBorder)
                    .disabled(publisher.lockedTarget)
            }
            if publisher.lockedTarget {
                Text("MarkView already created this repository for the project; publishing continues with it.")
                    .uiFont(.caption).foregroundColor(.secondary)
            }
            HStack(alignment: .top) {
                Text("Visibility").frame(width: 70, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    visibilityOption("private", "Private — only you and people you invite can see it")
                    visibilityOption("public", "Public — anyone on the internet can see it")
                }
            }
            if let problem = publisher.targetProblem {
                Text(problem).uiFont(.caption).foregroundColor(VSDark.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if publisher.phase == .checking { ProgressView().scaleEffect(0.6); Text("Checking \(publisher.slug)…").uiFont(.caption) }
                Spacer()
                Button("Close", action: close)
                Button("Continue") { Task { await publisher.check() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(publisher.phase == .checking || publisher.name.isEmpty)
            }
        }
    }

    private func visibilityOption(_ value: String, _ label: String) -> some View {
        Button(action: { publisher.visibility = value }) {
            HStack(spacing: 5) {
                Image(systemName: publisher.visibility == value ? "largecircle.fill.circle" : "circle")
                Text(label).uiFont(.caption)
            }
        }
        .buttonStyle(.plain)
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Publish to github.com/\(publisher.slug)").uiFont(size: 12, weight: .semibold)
            VStack(alignment: .leading, spacing: 3) {
                switch publisher.target {
                case .new?:
                    Text("• Create the \(publisher.visibility ?? "") repository \(publisher.slug)")
                case .existing(let visibility, let ours)?:
                    Text("• Use the existing \(visibility) repository \(publisher.slug)" + (ours ? " (created by MarkView for this project)" : ""))
                case nil:
                    EmptyView()
                }
                if publisher.files.isEmpty || !publisher.commitChanges {
                    Text("• No new commit — the current commits are pushed")
                } else {
                    Text("• Commit \(publisher.files.count) file\(publisher.files.count == 1 ? "" : "s"):")
                }
            }
            .uiFont(.caption)
            if publisher.hasCommits && !publisher.files.isEmpty {
                Toggle("Also commit the \(publisher.files.count) uncommitted file\(publisher.files.count == 1 ? "" : "s") below", isOn: $publisher.commitChanges)
                    .uiFont(.caption)
            }
            if !publisher.files.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(publisher.files, id: \.self) { Text($0).uiFont(size: 10, design: .monospaced) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .padding(4).background(VSDark.bgInput).cornerRadius(4)
                if publisher.commitChanges {
                    HStack {
                        Text("Message").uiFont(.caption)
                        TextField("Commit message", text: $publisher.commitMessage).textFieldStyle(.roundedBorder)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(publisher.originSet ? "• Push \(publisher.branch) to origin" : "• Add it as origin and push \(publisher.branch)")
                Text("• Turn on MarkView's GitHub integration (Settings › GitHub — it applies to every window)")
            }
            .uiFont(.caption)
            HStack {
                Button("Back") { publisher.back() }
                Spacer()
                Button("Close", action: close)
                Button("Publish") { Task { await publisher.publish() } }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// File › Publish to GitHub… and the Git tab's button, for the open folder.
struct GitHubPublishSheet: View {
    @ObservedObject var workspaceManager: WorkspaceManager
    @StateObject private var publisher: GitHubPublisher
    @Environment(\.dismiss) private var dismiss

    init(root: URL, workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        _publisher = StateObject(wrappedValue: GitHubPublisher(root: root) { [weak workspaceManager] slug in
            // nil from activateGitHub is success: only a missing window is an error here.
            guard let workspaceManager else { return "The window was closed." }
            return await workspaceManager.activateGitHub(expecting: slug, in: root)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "icloud.and.arrow.up").foregroundColor(VSDark.blue)
                Text("Publish to GitHub").uiFont(.headline)
            }
            GitHubPublishView(publisher: publisher) { dismiss() }
        }
        .padding(16)
        .frame(width: 560)
        .task { await publisher.prepare() }
    }
}

// MARK: - Welcome screen

/// Unfinished new projects on the welcome screen: Resume or Discard (DEC-015).
struct ProjectDraftList: View {
    @ObservedObject var drafts: ProjectDraftStore
    let resume: (UUID) -> Void
    @State private var discarding: ProjectDraft?

    var body: some View {
        if !drafts.drafts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unfinished projects").uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.textDim)
                ForEach(drafts.drafts) { draft in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(draft.displayTitle).uiFont(size: 12).foregroundColor(VSDark.textBright)
                            Text(draft.resumeDescription).uiFont(size: 10).foregroundColor(VSDark.textDim)
                        }
                        Spacer()
                        Button("Resume") { resume(draft.id) }
                        Button("Discard…") { discarding = draft }
                    }
                    .padding(6).background(VSDark.bgInput.opacity(0.6)).cornerRadius(5)
                }
            }
            .frame(width: 420)
            .confirmationDialog("Discard “\(discarding?.displayTitle ?? "")”?", isPresented: Binding(
                get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
                Button("Discard Draft", role: .destructive) {
                    if let id = discarding?.id { Task { await drafts.remove(id) } }
                    discarding = nil
                }
            } message: {
                Text("The idea and everything clarified so far are deleted. A folder already created for it is left as it is.")
            }
        }
    }
}
