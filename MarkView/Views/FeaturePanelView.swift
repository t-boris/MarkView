import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The four stages of a feature (spec §5).
enum FeatureStage: String, CaseIterable {
    case explore = "Explore", review = "Review", resolve = "Resolve", build = "Build"
    static let storageKey = "feature.stage"
}

/// Right panel "Feature" tab: stages, readiness, the AI around the open document.
struct FeaturePanelView: View {
    @ObservedObject var store: FeatureStore
    @ObservedObject var assistant: FeatureAssistant
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @AppStorage(FeatureStage.storageKey) private var stage = FeatureStage.explore
    @State private var showConditions = false

    init(store: FeatureStore) {
        self.store = store
        self.assistant = store.assistant
    }

    var body: some View {
        VStack(spacing: 0) {
            if workspaceManager.rootNode == nil {
                panelEmpty("Open a folder to work on features.")
            } else if let feature = store.active {
                header(feature)
                Divider().background(VSDark.border)
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        errors
                        if let located = openObject, located.feature.slug == feature.slug, let object = located.object {
                            ObjectContextView(store: store, feature: feature, object: object)
                        }
                        results(feature)
                        switch stage {
                        case .explore: ExploreStageView(store: store, feature: feature)
                        case .review: ReviewStageView(store: store, feature: feature)
                        case .resolve: ResolveStageView(store: store, feature: feature)
                        case .build: BuildStageView(store: store, feature: feature)
                        }
                    }
                    .padding(10)
                }
                // A new answer (discussion, contextual action) is scrolled into view.
                .onChange(of: assistant.results.first?.id) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
                }
                }
                DiscussionInput(store: store, feature: feature)
            } else {
                panelEmpty("No features yet. Use ⊞ → New Feature, or open one in the left panel (Issues).")
            }
        }
        .background(VSDark.bgSidebar)
    }

    private var openObject: (feature: Feature, object: FeatureObject?)? {
        workspaceManager.activeTab.flatMap { store.locate($0.url) }
    }

    private func header(_ feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(feature.title).font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.textBright).lineLimit(1)
                Spacer()
                FeatureStatusMenu(store: store, feature: feature)
            }
            HStack(spacing: 2) {
                ForEach(FeatureStage.allCases, id: \.self) { item in
                    Button(action: { stage = item }) {
                        Text(item.rawValue.uppercased())
                            .font(.system(size: 9, weight: stage == item ? .bold : .regular, design: .monospaced))
                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                            .foregroundColor(stage == item ? VSDark.textBright : VSDark.textDim)
                            .background(stage == item ? VSDark.bgActive : Color.clear).cornerRadius(3)
                    }.buttonStyle(.plain)
                    if item != .build { Text("→").font(.system(size: 8)).foregroundColor(VSDark.textDim) }
                }
            }
            Button(action: { showConditions.toggle() }) {
                HStack(spacing: 6) {
                    Text("Readiness").font(.system(size: 10)).foregroundColor(VSDark.textDim)
                    ReadinessBar(value: feature.readiness)
                    Text("\(feature.readiness)%").font(.system(size: 10, design: .monospaced)).foregroundColor(VSDark.text)
                }
            }.buttonStyle(.plain).help("Calculated from explicit conditions — click for details")
            if showConditions {
                ForEach(feature.readinessConditions) { c in
                    HStack(spacing: 4) {
                        Image(systemName: c.met ? "checkmark.circle.fill" : "circle").font(.system(size: 9))
                            .foregroundColor(c.met ? VSDark.green : VSDark.textDim)
                        Text(c.name).font(.system(size: 10)).foregroundColor(VSDark.text)
                        Spacer()
                        Text("\(c.done)/\(c.total)").font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(VSDark.bg)
    }

    @ViewBuilder
    private var errors: some View {
        if let error = store.lastError ?? assistant.error {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 9)).foregroundColor(VSDark.red)
                Text(error).font(.system(size: 10)).foregroundColor(VSDark.red).textSelection(.enabled)
                Spacer()
                Button(action: { store.lastError = nil; assistant.error = nil }) {
                    Image(systemName: "xmark").font(.system(size: 8)).foregroundColor(VSDark.textDim)
                }.buttonStyle(.plain)
            }
            .padding(6).background(VSDark.red.opacity(0.1)).cornerRadius(4)
        }
    }

    @ViewBuilder
    private func results(_ feature: Feature) -> some View {
        let items = assistant.results.filter { $0.feature == nil || $0.feature == feature.slug }
        ForEach(items) { item in ResultCard(store: store, result: item, feature: feature).id(item.id) }
    }

    private func panelEmpty(_ text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "square.stack.3d.up").font(.system(size: 22)).foregroundColor(VSDark.textDim)
            Text(text).font(.system(size: 11)).foregroundColor(VSDark.textDim).multilineTextAlignment(.center).padding(.horizontal, 16)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Shared pieces

struct PanelSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundColor(VSDark.textDim)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }
}

struct SmallButton: View {
    let title: String
    var icon: String? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).font(.system(size: 9)) }
                Text(title).font(.system(size: 10, weight: prominent ? .semibold : .regular))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundColor(prominent ? .white : VSDark.text)
            .background(prominent ? VSDark.badge : VSDark.bgInput)
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }
}

struct Working: View {
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
            Text(text).font(.system(size: 10)).foregroundColor(VSDark.textDim)
        }
    }
}

private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 5, content: content)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VSDark.bg)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(VSDark.border))
        .cornerRadius(5)
}

private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

/// An answer of a contextual action or of the discussion.
struct ResultCard: View {
    @ObservedObject var store: FeatureStore
    let result: FeatureResult
    let feature: Feature
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        card {
            HStack {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundColor(VSDark.blue)
                Text(result.title).font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.textBright)
                Spacer()
                if result.pending { ProgressView().scaleEffect(0.4).frame(width: 10, height: 10) }
                Button(action: { store.assistant.dismissResult(result.id) }) {
                    Image(systemName: "xmark").font(.system(size: 8)).foregroundColor(VSDark.textDim)
                }.buttonStyle(.plain)
            }
            Text(markdown(result.text.isEmpty ? "…" : result.text))
                .font(.system(size: 11)).foregroundColor(VSDark.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let diagram = result.diagram {
                SmallButton(title: "Save diagram to feature", icon: "square.and.arrow.down") {
                    if let url = store.assistant.saveDiagram(diagram, title: "Diagram", in: feature.slug) { workspaceManager.openFile(url) }
                }
            }
            if let decision = result.decision {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This discussion appears to contain a decision:").font(.system(size: 10)).foregroundColor(VSDark.yellow)
                    Text(decision.title).font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.textBright)
                    HStack {
                        SmallButton(title: "Create Decision", icon: "signpost.right", prominent: true) {
                            store.assistant.saveDecision(decision, in: feature.slug, from: result.id)
                        }
                        SmallButton(title: "Continue Discussion") { store.assistant.dismissDecision(result.id) }
                    }
                }
            }
        }
    }
}

/// Free-form discussion with the facilitator (spec §32), always at the bottom of the tab.
struct DiscussionInput: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            Divider().background(VSDark.border)
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Discuss this feature…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 11)).lineLimit(1...5)
                    .onSubmit(send)
                if store.assistant.isRunning("chat:" + feature.slug) {
                    ProgressView().scaleEffect(0.45).frame(width: 14, height: 14)
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 15)).foregroundColor(VSDark.blue) }
                        .buttonStyle(.plain).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(8)
            .background(VSDark.bgInput)
        }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        text = ""
        Task { await store.assistant.chat(feature.slug, message: message) }
    }
}

// MARK: - Explore (spec §6–7, §9–10)

struct ExploreStageView: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature
    @EnvironmentObject var workspaceManager: WorkspaceManager

    private var assistant: FeatureAssistant { store.assistant }

    /// The question guided discovery asks now: its newest open question, else any open one.
    private var current: FeatureObject? {
        let open = feature.list(.question).filter { $0.status == "open" }
        return open.last { $0.front.string("origin") == "explore" } ?? open.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelSection(title: "Feature understanding") {
                let known = feature.understanding.filter { $0.state == "known" || $0.state == "n/a" }.count
                HStack(spacing: 6) {
                    Text("\(known) of \(feature.understanding.count) clear").font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.text)
                    if let left = feature.questionsLeft {
                        Text(left == 0 ? "· ready to specify" : "· ≈\(left) question\(left == 1 ? "" : "s") left")
                            .font(.system(size: 10)).foregroundColor(left == 0 ? VSDark.green : VSDark.textDim)
                    }
                    Spacer()
                    SmallButton(title: "Enough questions → Review") {
                        UserDefaults.standard.set(FeatureStage.review.rawValue, forKey: FeatureStage.storageKey)
                        Task { await assistant.review(feature.slug) }
                    }
                    .help("Stop the questions here and review what is specified so far")
                }
                HStack(spacing: 8) {
                    ForEach(FeatureVocabulary.understandingStates, id: \.self) { state in
                        HStack(spacing: 2) {
                            Text(symbol(state)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(color(state))
                            Text(state).font(.system(size: 9)).foregroundColor(VSDark.textDim)
                        }
                    }
                }
                ForEach(feature.understanding, id: \.dimension) { item in
                    let note = feature.understandingNote(item.dimension)
                    HStack(alignment: .top, spacing: 5) {
                        Menu {
                            ForEach(FeatureVocabulary.understandingStates, id: \.self) { state in
                                Button((state == item.state ? "✓ " : "") + state) { store.setUnderstanding(feature.slug, [item.dimension: state]) }
                            }
                        } label: {
                            Text(symbol(item.state)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(color(item.state))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("\(item.dimension): \(item.state) — click to change")
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(item.dimension).font(.system(size: 10, weight: .medium)).foregroundColor(VSDark.text)
                                Text(item.state).font(.system(size: 9)).foregroundColor(color(item.state))
                            }
                            if !note.isEmpty {
                                Text(note).font(.system(size: 9)).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            if assistant.isRunning("explore:" + feature.slug) {
                Working(text: "Looking at what is still missing…")
            } else if let question = current {
                QuestionCard(store: store, feature: feature, question: question)
            } else {
                HStack {
                    Text(feature.list(.question).isEmpty ? "Start guided discovery." : "No open question.")
                        .font(.system(size: 10)).foregroundColor(VSDark.textDim)
                    Spacer()
                    SmallButton(title: "Ask next question", icon: "sparkles", prominent: true) {
                        Task { await assistant.exploreNext(feature.slug) }
                    }
                }
            }
            SourcesSection(store: store, feature: feature)
        }
    }

    private func symbol(_ state: String) -> String {
        switch state { case "known": return "✓"; case "partial": return "~"; case "n/a": return "–"; default: return "?" }
    }

    private func color(_ state: String) -> Color {
        switch state { case "known": return VSDark.green; case "partial": return VSDark.yellow; case "n/a": return VSDark.textDim; default: return VSDark.orange }
    }
}

/// A question with its options and the discovery actions (spec §7, §15).
struct QuestionCard: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let question: FeatureObject
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var answer = ""
    @State private var showDetails = false
    /// The answer just given: shown at once, until the specification is updated.
    @State private var sent: String?

    private var assistant: FeatureAssistant { store.assistant }
    private var busy: Bool {
        ["answer:", "options:", "pros:"].contains { assistant.isRunning($0 + question.id) } || assistant.isRunning("research:" + feature.slug)
    }

    var body: some View {
        card {
            HStack(spacing: 4) {
                Text(question.id).font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                if question.isBlocking { Text("BLOCKING").font(.system(size: 8, weight: .bold)).foregroundColor(VSDark.red) }
                Text(question.front.string("q_type").uppercased()).font(.system(size: 8)).foregroundColor(VSDark.textDim)
                Spacer()
                Button(action: { workspaceManager.openFile(question.url) }) {
                    Image(systemName: "doc.text").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                }.buttonStyle(.plain).help("Open \(question.id)")
            }
            Text(question.section("Question").isEmpty ? question.title : question.section("Question"))
                .font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.textBright).fixedSize(horizontal: false, vertical: true)
            let why = question.section("Why it matters")
            if !why.isEmpty {
                Text(why).font(.system(size: 10)).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
            }
            let options = question.front["options"]?.list ?? []
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let label = option["label"]?.string ?? ""
                let text = option["text"]?.string ?? ""
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 5) {
                        Text(label).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(VSDark.blue)
                        Text(text).font(.system(size: 10)).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true)
                    }
                    if showDetails {
                        ForEach(option["pros"]?.strings ?? [], id: \.self) { Text("+ " + $0).font(.system(size: 9)).foregroundColor(VSDark.green) }
                        ForEach(option["cons"]?.strings ?? [], id: \.self) { Text("− " + $0).font(.system(size: 9)).foregroundColor(VSDark.orange) }
                    }
                }
            }
            if let sent, question.status == "open" {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundColor(VSDark.green)
                    Text(sent).font(.system(size: 10, weight: .medium)).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true)
                }
                if busy {
                    Working(text: "Answer taken — updating the specification and preparing the next question…")
                } else {
                    // Finished without updating (an error is shown above): allow another try.
                    SmallButton(title: "Try again") { self.sent = nil }
                }
            } else if busy {
                Working(text: "Working on \(question.id)…")
            } else {
                FlowButtons {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        let label = option["label"]?.string ?? ""
                        SmallButton(title: "Choose \(label)", prominent: true) {
                            let text = option["text"]?.string ?? ""
                            sent = "\(label). \(text)"
                            Task { await assistant.answer(feature.slug, question: question.id, answer: "\(label). \(text)") }
                        }
                    }
                    SmallButton(title: "Suggest another approach") { Task { await assistant.moreOptions(feature.slug, question: question.id) } }
                    SmallButton(title: "Research this", icon: "globe") {
                        Task { await assistant.research(feature.slug, topic: question.title, for: question.id) }
                    }
                    SmallButton(title: showDetails ? "Hide pros/cons" : "Show pros/cons") {
                        let hasPros = options.contains { !($0["pros"]?.strings ?? []).isEmpty }
                        showDetails.toggle()
                        if showDetails && !hasPros { Task { await assistant.prosAndCons(feature.slug, question: question.id) } }
                    }
                    SmallButton(title: "Skip for now") { Task { await assistant.skip(feature.slug, question: question.id) } }
                }
                HStack(spacing: 4) {
                    TextField("Or answer in your own words…", text: $answer)
                        .textFieldStyle(.plain).font(.system(size: 10))
                        .padding(4).background(VSDark.bgInput).cornerRadius(3)
                        .onSubmit(submit)
                    SmallButton(title: "Answer", action: submit)
                }
            }
        }
    }

    private func submit() {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answer = ""
        sent = text
        Task { await assistant.answer(feature.slug, question: question.id, answer: text) }
    }
}

/// Buttons that wrap onto several lines in the narrow panel.
struct FlowButtons<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        if #available(macOS 13.0, *) {
            FlowLayout(spacing: 4) { content() }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Source material and the facts extracted from it (spec §9–10).
struct SourcesSection: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @ObservedObject private var whisper: WhisperClient
    @State private var prompt: SourcePrompt?

    init(store: FeatureStore, feature: Feature) {
        self.store = store
        self.feature = feature
        self.whisper = store.assistant.voice
    }
    @State private var dropping = false

    enum SourcePrompt: String, Identifiable { case url, issue, text; var id: String { rawValue } }

    private var assistant: FeatureAssistant { store.assistant }

    var body: some View {
        PanelSection(title: "Sources", trailing: AnyView(addMenu)) {
            if assistant.running.contains(where: { $0.hasPrefix("ingest:") }) || assistant.isRunning("add-source") {
                Working(text: "Reading the source…")
            }
            if feature.list(.source).isEmpty {
                Text("Drop files here (docs, PDFs, screenshots, audio) or add a URL, a GitHub issue, notes or a voice note. The AI proposes facts; you accept them.")
                    .font(.system(size: 9)).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(feature.list(.source).reversed()) { source in SourceCard(store: store, feature: feature, source: source) }
        }
        .padding(4)
        .background(dropping ? VSDark.selection.opacity(0.25) : Color.clear)
        .cornerRadius(4)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await assistant.ingest(.file(url), into: feature.slug) }
                }
            }
            return true
        }
        .sheet(item: $prompt) { kind in
            SourceInputSheet(kind: kind) { title, value in
                Task {
                    switch kind {
                    case .url:
                        if let url = URL(string: value.trimmingCharacters(in: .whitespaces)) { await assistant.ingest(.url(url), into: feature.slug) }
                    case .issue:
                        let digits = value.filter(\.isNumber)
                        if let number = Int(digits) { await assistant.ingest(.gitHubIssue(number), into: feature.slug) }
                    case .text:
                        await assistant.ingest(.text(title: title, text: value, kind: "notes"), into: feature.slug)
                    }
                }
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Files…") { chooseFiles() }
            Button("URL…") { prompt = .url }
            Button("GitHub Issue…") { prompt = .issue }
            Button("Notes / Conversation…") { prompt = .text }
            Divider()
            if whisper.isRecording {
                Button("Stop Voice Note") {
                    Task {
                        if let text = await whisper.stopRecording(), !text.isEmpty {
                            await assistant.ingest(.voice(text: text), into: feature.slug)
                        }
                    }
                }
            } else {
                Button("Record Voice Note") { whisper.startRecording() }
            }
        } label: {
            HStack(spacing: 2) {
                if whisper.isRecording { Circle().fill(VSDark.red).frame(width: 6, height: 6) }
                Image(systemName: "plus").font(.system(size: 9))
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Add sources to \(feature.title)"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { Task { await assistant.ingest(.file(url), into: feature.slug) } }
    }
}

struct SourceInputSheet: View {
    let kind: SourcesSection.SourcePrompt
    let onDone: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind == .url ? "Add a web page" : kind == .issue ? "Add a GitHub issue" : "Add notes or a conversation").font(.headline)
            if kind == .text {
                TextField("Title (e.g. Call with support, 12 Sep)", text: $title).textFieldStyle(.roundedBorder)
                TextEditor(text: $value).font(.system(size: 12)).frame(minWidth: 420, minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(VSDark.border))
            } else {
                TextField(kind == .url ? "https://…" : "Issue number or link", text: $value).textFieldStyle(.roundedBorder).frame(minWidth: 380)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { onDone(title, value); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }
}

/// A source with its role and candidate facts: Accept / Reject / Edit / Discuss.
struct SourceCard: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let source: FeatureObject
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var editing: Int?
    @State private var draft = ""

    var body: some View {
        card {
            HStack(spacing: 4) {
                Image(systemName: "paperclip").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                Text(source.title).font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.textBright).lineLimit(1)
                Spacer()
                let role = source.front.string("role")
                if !role.isEmpty { Text(FeatureVocabulary.label(role)).font(.system(size: 8)).foregroundColor(VSDark.cyan) }
                Button(action: { workspaceManager.openFile(source.url) }) {
                    Image(systemName: "doc.text").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                }.buttonStyle(.plain)
            }
            let facts = source.front["facts"]?.list ?? []
            let pending = facts.filter { $0["status"]?.string == "pending" }.count
            if !facts.isEmpty {
                Text("\(facts.count) facts extracted\(pending > 0 ? " · \(pending) to confirm" : "")")
                    .font(.system(size: 9)).foregroundColor(VSDark.textDim)
            }
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                let status = fact["status"]?.string ?? "pending"
                let text = fact["text"]?.string ?? ""
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 4) {
                        Text(status == "accepted" ? "✓" : status == "rejected" ? "✗" : "?")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(status == "accepted" ? VSDark.green : status == "rejected" ? VSDark.textDim : VSDark.yellow)
                        if editing == index {
                            TextField("", text: $draft).textFieldStyle(.plain).font(.system(size: 10))
                                .onSubmit {
                                    store.assistant.setFact(feature.slug, source: source.id, index: index, status: "accepted", text: draft)
                                    editing = nil
                                }
                        } else {
                            Text(text).font(.system(size: 10)).foregroundColor(status == "rejected" ? VSDark.textDim : VSDark.text)
                                .strikethrough(status == "rejected").fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if status == "pending" {
                        HStack(spacing: 4) {
                            SmallButton(title: "Accept") { store.assistant.setFact(feature.slug, source: source.id, index: index, status: "accepted") }
                            SmallButton(title: "Reject") { store.assistant.setFact(feature.slug, source: source.id, index: index, status: "rejected") }
                            SmallButton(title: "Edit") { draft = text; editing = index }
                            SmallButton(title: "Discuss") {
                                Task { await store.assistant.chat(feature.slug, message: "About this fact from \(source.id): \"\(text)\" — is it right, and what does it mean for the feature?") }
                            }
                        }
                        .padding(.leading, 14)
                    }
                }
            }
        }
    }
}

// MARK: - Review (spec §12–14)

struct ReviewStageView: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Is the specification complete, consistent and ready?").font(.system(size: 10)).foregroundColor(VSDark.textDim)
                Spacer()
                if store.assistant.isRunning("review:" + feature.slug) {
                    Working(text: "Reviewing the specification from every perspective — about a minute…")
                } else {
                    SmallButton(title: "Run review", icon: "sparkles", prominent: true) { Task { await store.assistant.review(feature.slug) } }
                }
            }
            let open = feature.list(.finding).filter { !$0.isClosed }
            PanelSection(title: "Review") {
                let counts = Dictionary(grouping: open) { $0.front.string("category") }
                ForEach(FeatureVocabulary.findingCategories, id: \.self) { category in
                    if let items = counts[category] {
                        HStack {
                            Text(FeatureVocabulary.label(category)).font(.system(size: 10)).foregroundColor(VSDark.text)
                            Spacer()
                            Text("\(items.count)").font(.system(size: 10, design: .monospaced)).foregroundColor(VSDark.textDim)
                        }
                    }
                }
                if open.isEmpty { Text(feature.list(.finding).isEmpty ? "No review yet." : "All findings are closed.").font(.system(size: 10)).foregroundColor(VSDark.textDim) }
            }
            ForEach(FeatureVocabulary.severities, id: \.self) { severity in
                ForEach(open.filter { $0.front.string("severity") == severity }) { finding in
                    FindingCard(store: store, feature: feature, finding: finding)
                }
            }
        }
    }
}

/// A finding with its lifecycle actions (spec §14).
struct FindingCard: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let finding: FeatureObject
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var own = ""
    /// What was just asked for this finding, shown at once.
    @State private var started: String?

    private var assistant: FeatureAssistant { store.assistant }

    var body: some View {
        card {
            HStack(spacing: 4) {
                Text(finding.front.string("severity").uppercased()).font(.system(size: 8, weight: .bold))
                    .foregroundColor(["blocker", "high"].contains(finding.front.string("severity")) ? VSDark.red : VSDark.orange)
                Text(FeatureVocabulary.label(finding.front.string("category")).uppercased()).font(.system(size: 8)).foregroundColor(VSDark.textDim)
                Spacer()
                Text(finding.id).font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
            }
            Text(finding.title).font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.textBright).fixedSize(horizontal: false, vertical: true)
            let quote = finding.front.string("quote")
            if !quote.isEmpty {
                Text("“\(quote)”").font(.system(size: 10).italic()).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
            }
            let detail = finding.section("Finding")
            if !detail.isEmpty { Text(detail).font(.system(size: 10)).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true) }
            let interpretations = finding.front.strings("interpretations")
            if !interpretations.isEmpty {
                ForEach(interpretations, id: \.self) { Text("• " + $0).font(.system(size: 10)).foregroundColor(VSDark.text) }
            }
            Text(finding.front.strings("perspectives").joined(separator: " · ")).font(.system(size: 9)).foregroundColor(VSDark.cyan)
            ResolutionOptions(store: store, feature: feature, finding: finding)
            if let started, assistant.isRunning("chat:" + feature.slug) {
                Working(text: started)
            }
            if !assistant.isRunning("resolve:" + finding.id) && !assistant.isRunning("resolveopts:" + finding.id) {
                FlowButtons {
                    if (finding.front["options"]?.list ?? []).isEmpty {
                        SmallButton(title: "Resolve", icon: "sparkles", prominent: true) {
                            Task { await assistant.resolutionOptions(feature.slug, finding: finding.id) }
                        }
                    }
                    SmallButton(title: "Discuss") {
                        started = "Sent to the discussion — the reply appears at the top of this panel…"
                        Task { await assistant.chat(feature.slug, message: "Let's discuss \(finding.id): \(finding.title)") }
                    }
                    SmallButton(title: "Edit Requirement") { openTarget() }
                    SmallButton(title: "Accept Risk") { store.setStatus(finding.id, in: feature.slug, to: "accepted-risk") }
                    SmallButton(title: "Dismiss") { store.setStatus(finding.id, in: feature.slug, to: "dismissed") }
                }
            }
        }
    }

    private func openTarget() {
        let target = finding.front.strings("refs").first ?? ""
        if let object = feature.object(target) {
            workspaceManager.openFile(object.url)
        } else if let root = store.root, !target.isEmpty, !target.contains("..") {
            let url = root.appendingPathComponent(target)
            if FileManager.default.fileExists(atPath: url.path) { workspaceManager.openFile(url); return }
            workspaceManager.openFile(finding.url)
        } else {
            workspaceManager.openFile(finding.url)
        }
    }
}

/// The ways to resolve a finding (AI-proposed), as buttons, plus the user's own answer.
struct ResolutionOptions: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let finding: FeatureObject
    @State private var own = ""
    /// The resolution just chosen, shown at once while the decision is written.
    @State private var chosen: String?

    var body: some View {
        let options = finding.front["options"]?.list ?? []
        if store.assistant.isRunning("resolve:" + finding.id) {
            VStack(alignment: .leading, spacing: 3) {
                if let chosen {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundColor(VSDark.green)
                        Text(chosen).font(.system(size: 10, weight: .medium)).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Working(text: "Recording the decision and closing \(finding.id)…")
            }
        } else if store.assistant.isRunning("resolveopts:" + finding.id) {
            Working(text: "Looking for ways to resolve \(finding.id)…")
        } else if !options.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                let question = finding.front.string("resolution_question")
                if !question.isEmpty { Text(question).font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.yellow) }
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let text = option["text"]?.string ?? ""
                    VStack(alignment: .leading, spacing: 1) {
                        SmallButton(title: option["label"]?.string ?? "Option", prominent: true) {
                            chosen = (option["label"]?.string ?? "") + " — " + text
                            Task { await store.assistant.resolve(feature.slug, finding: finding.id, with: text) }
                        }
                        Text(text).font(.system(size: 9)).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true)
                        let consequence = option["consequence"]?.string ?? ""
                        if !consequence.isEmpty { Text("→ " + consequence).font(.system(size: 9)).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                HStack(spacing: 4) {
                    TextField("Another way…", text: $own).textFieldStyle(.plain).font(.system(size: 10))
                        .padding(4).background(VSDark.bgInput).cornerRadius(3)
                    SmallButton(title: "Use") {
                        let text = own.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        own = ""
                        chosen = text
                        Task { await store.assistant.resolve(feature.slug, finding: finding.id, with: text) }
                    }
                }
            }
        }
    }
}

// MARK: - Resolve (spec §17)

struct ResolveStageView: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature

    var body: some View {
        let blocking = feature.list(.question).filter { $0.isBlocking && !$0.isClosed }
        let otherQuestions = feature.list(.question).filter { !$0.isBlocking && $0.status == "open" }
        let conflicts = feature.list(.finding).filter { $0.front.string("category") == "contradiction" && !$0.isClosed }
        let important = feature.list(.finding).filter {
            $0.front.string("category") != "contradiction" && !$0.isClosed && ["blocker", "high"].contains($0.front.string("severity"))
        }
        let assumptions = feature.list(.research).flatMap { note in
            (note.front["claims"]?.list ?? []).filter { $0["kind"]?.string == "open-assumption" }.compactMap { $0["text"]?.string }.map { (note.id, $0) }
        }
        let proposed = feature.list(.decision).filter { $0.status == "proposed" }
        let gaps = feature.understanding.filter { $0.state == "unknown" }

        VStack(alignment: .leading, spacing: 10) {
            PanelSection(title: "Resolution center") {
                summary("Blocking questions", blocking.count, VSDark.red)
                summary("Conflicting requirements", conflicts.count, VSDark.red)
                summary("Important findings", important.count, VSDark.orange)
                summary("Open questions", otherQuestions.count, VSDark.yellow)
                summary("Decisions to confirm", proposed.count, VSDark.yellow)
                summary("Open assumptions", assumptions.count, VSDark.yellow)
                summary("Research gaps", gaps.count, VSDark.textDim)
            }
            ForEach(blocking) { QuestionCard(store: store, feature: feature, question: $0) }
            ForEach(conflicts) { FindingCard(store: store, feature: feature, finding: $0) }
            ForEach(important) { FindingCard(store: store, feature: feature, finding: $0) }
            ForEach(proposed) { decision in
                card {
                    HStack {
                        Text(decision.id).font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                        Text("PROPOSED").font(.system(size: 8, weight: .bold)).foregroundColor(VSDark.yellow)
                    }
                    Text(decision.title).font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.textBright)
                    Text(decision.section("Decision")).font(.system(size: 10)).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        SmallButton(title: "Accept", prominent: true) { store.setStatus(decision.id, in: feature.slug, to: "accepted") }
                        SmallButton(title: "Reject") { store.setStatus(decision.id, in: feature.slug, to: "rejected") }
                    }
                }
            }
            if !assumptions.isEmpty {
                PanelSection(title: "Open assumptions") {
                    ForEach(assumptions, id: \.1) { item in
                        HStack(alignment: .top) {
                            Text("• \(item.1)").font(.system(size: 10)).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            SmallButton(title: "Ask") {
                                store.create(.question, in: feature.slug, title: "Is it true that: \(item.1)",
                                             fields: [("q_type", .string("clarification")), ("blocking", .list([])),
                                                      ("sources", .list([.string(item.0)]))],
                                             body: "## Question\n\nConfirm or correct the assumption from \(item.0):\n\n> \(item.1)\n",
                                             provenance: "Derived from \(item.0)")
                            }
                        }
                    }
                }
            }
            if !gaps.isEmpty {
                PanelSection(title: "Research gaps") {
                    ForEach(gaps, id: \.dimension) { gap in
                        HStack {
                            Text(gap.dimension).font(.system(size: 10)).foregroundColor(VSDark.text)
                            Spacer()
                            SmallButton(title: "Research", icon: "globe") {
                                Task { await store.assistant.research(feature.slug, topic: "\(gap.dimension) for \(feature.title)") }
                            }
                        }
                    }
                }
            }
            ForEach(otherQuestions) { QuestionCard(store: store, feature: feature, question: $0) }
        }
    }

    private func summary(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack {
            Text(title).font(.system(size: 10)).foregroundColor(VSDark.text)
            Spacer()
            Text("\(count)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(count > 0 ? color : VSDark.textDim)
        }
    }
}

// MARK: - Build (spec §24–26)

struct BuildStageView: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature
    @EnvironmentObject var workspaceManager: WorkspaceManager

    private var assistant: FeatureAssistant { store.assistant }

    var body: some View {
        let approved = feature.list(.requirement).filter { $0.status == "approved" }
        let issues = feature.planIssues
        let covered = Set(issues.flatMap(\.requirements))
        let missing = approved.filter { !covered.contains($0.id) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(approved.count) approved of \(feature.list(.requirement).filter { $0.status != "rejected" }.count) requirements")
                    .font(.system(size: 10)).foregroundColor(VSDark.textDim)
                Spacer()
                if assistant.isRunning("decompose:" + feature.slug) {
                    Working(text: "Planning…")
                } else {
                    SmallButton(title: issues.isEmpty ? "Propose plan" : "Re-plan", icon: "sparkles", prominent: issues.isEmpty) {
                        Task { await assistant.decompose(feature.slug) }
                    }
                }
            }
            HStack {
                Text("Hand the specification to the AI terminal to implement.").font(.system(size: 10)).foregroundColor(VSDark.textDim)
                Spacer()
                SmallButton(title: "Implement with AI", icon: "hammer") { workspaceManager.implementWithAI(feature.folder) }
            }
            if approved.isEmpty {
                Text("Approve requirements first (their files' status, or in the object panel). The plan uses approved ones; without any it uses all non-rejected.")
                    .font(.system(size: 9)).foregroundColor(VSDark.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !issues.isEmpty {
                PanelSection(title: "Implementation coverage") {
                    Text("\(approved.count - missing.count) / \(approved.count) requirements covered")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(missing.isEmpty ? VSDark.green : VSDark.orange)
                    if !missing.isEmpty {
                        Text("Missing: " + missing.map(\.id).joined(separator: ", ")).font(.system(size: 10)).foregroundColor(VSDark.orange)
                        FlowButtons {
                            ForEach(missing) { RequirementChip(id: $0.id, title: $0.title, from: nil) }
                        }
                    }
                }
                PanelSection(title: "Epic" + (feature.epic.map { " · #\($0)" } ?? "")) {
                    ForEach(issues) { issue in
                        IssuePlanCard(store: store, feature: feature, issue: issue)
                    }
                }
                HStack {
                    Spacer()
                    if assistant.isRunning("issues:" + feature.slug) {
                        Working(text: "Creating GitHub issues…")
                    } else if issues.contains(where: { $0.github == nil }) {
                        SmallButton(title: "Approve & create GitHub issues", icon: "arrow.up.forward.square", prominent: true) {
                            Task { await assistant.createIssues(feature.slug) }
                        }
                        .disabled(!missing.isEmpty && !approved.isEmpty)
                        .help(missing.isEmpty ? "Create the issues and the epic on GitHub" : "Cover every approved requirement first")
                    }
                }
            }
        }
    }
}

/// A requirement that can be dragged between planned issues.
struct RequirementChip: View {
    let id: String
    let title: String
    /// The issue it is dragged from (nil = not in the plan).
    let from: String?

    var body: some View {
        Text(id).font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(VSDark.selection.opacity(0.5)).cornerRadius(3)
            .foregroundColor(VSDark.textBright)
            .help(title)
            .onDrag { NSItemProvider(object: "\(from ?? "")|\(id)" as NSString) }
    }
}

struct IssuePlanCard: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let issue: PlannedIssue
    @State private var targeted = false
    @State private var pulls: [(number: Int, title: String, url: String)] = []

    var body: some View {
        card {
            HStack(spacing: 4) {
                Text(issue.id).font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                Text(issue.title).font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.textBright).lineLimit(2)
                Spacer()
                if let number = issue.github {
                    Button("#\(number)") { openIssue(number) }.buttonStyle(.link).font(.system(size: 10))
                }
            }
            Text(issue.summary).font(.system(size: 10)).foregroundColor(VSDark.text).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            FlowButtons {
                ForEach(issue.requirements, id: \.self) { id in
                    RequirementChip(id: id, title: feature.object(id)?.title ?? id, from: issue.id)
                        .contextMenu { Button("Remove from \(issue.id)") { move(id, from: issue.id, to: nil) } }
                }
                ForEach(issue.decisions, id: \.self) { id in
                    Text(id).font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.purple)
                }
            }
            if let number = issue.github {
                if pulls.isEmpty {
                    Button("Pull requests") { Task { pulls = await store.assistant.pullRequests(closing: number) } }
                        .buttonStyle(.link).font(.system(size: 9))
                }
                ForEach(pulls, id: \.number) { pr in
                    Button("PR #\(pr.number) \(pr.title)") { if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) } }
                        .buttonStyle(.link).font(.system(size: 9))
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(targeted ? VSDark.blue : Color.clear, lineWidth: 2))
        .onDrop(of: [UTType.plainText], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let text = value as? String else { return }
                let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else { return }
                Task { @MainActor in move(parts[1], from: parts[0].isEmpty ? nil : parts[0], to: issue.id) }
            }
            return true
        }
    }

    /// Move a requirement between planned issues (spec §25).
    private func move(_ id: String, from source: String?, to target: String?) {
        guard source != target, let feature = store.feature(feature.slug) else { return }
        var issues = feature.planIssues
        if let source, let i = issues.firstIndex(where: { $0.id == source }) { issues[i].requirements.removeAll { $0 == id } }
        if let target, let i = issues.firstIndex(where: { $0.id == target }), !issues[i].requirements.contains(id) {
            issues[i].requirements.append(id)
        }
        let title = feature.planFront.string("title").isEmpty ? feature.title : feature.planFront.string("title")
        store.savePlan(feature.slug, title: title, issues: issues, epic: feature.epic)
    }

    private func openIssue(_ number: Int) {
        if let slug = store.assistant.gitHubClient()?.repo.slug, let url = URL(string: "https://github.com/\(slug)/issues/\(number)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - The object open in the editor: trace, impact, history (spec §21, §27, §30)

struct ObjectContextView: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let object: FeatureObject
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var history: [String] = []
    @State private var mentions: [String] = []
    @State private var code: [String] = []
    @State private var loadedFor = ""

    private var assistant: FeatureAssistant { store.assistant }

    var body: some View {
        card {
            HStack(spacing: 5) {
                Image(systemName: object.kind.icon).font(.system(size: 10)).foregroundColor(VSDark.blue)
                Text(object.id).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(VSDark.textBright)
                Spacer()
                statusMenu
            }
            let provenance = object.front.string("provenance")
            if !provenance.isEmpty {
                Text(provenance + (object.front.string("created").isEmpty ? "" : " · \(object.front.string("created"))"))
                    .font(.system(size: 9)).foregroundColor(VSDark.textDim)
            }
            actions
            trace
            if object.kind == .decision || object.kind == .requirement { impact }
            if !history.isEmpty {
                Text("HISTORY").font(.system(size: 8, weight: .bold)).foregroundColor(VSDark.textDim).padding(.top, 2)
                ForEach(history.prefix(6), id: \.self) { Text($0).font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim).lineLimit(1) }
            }
        }
        .task(id: object.id + object.front.string("updated")) { await load() }
    }

    private var statusMenu: some View {
        let statuses: [String] = {
            switch object.kind {
            case .requirement: return FeatureVocabulary.requirementStatuses
            case .question: return FeatureVocabulary.questionStatuses
            case .decision: return FeatureVocabulary.decisionStatuses
            case .finding: return FeatureVocabulary.findingStatuses
            default: return []
            }
        }()
        return Menu {
            ForEach(statuses, id: \.self) { status in
                Button((status == object.status ? "✓ " : "") + FeatureVocabulary.label(status)) {
                    store.setStatus(object.id, in: feature.slug, to: status)
                }
            }
        } label: {
            Text(FeatureVocabulary.label(object.status.isEmpty ? "—" : object.status)).font(.system(size: 10, weight: .semibold))
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(statuses.isEmpty)
    }

    @ViewBuilder
    private var actions: some View {
        FlowButtons {
            switch object.kind {
            case .requirement:
                SmallButton(title: "Review requirement", icon: "sparkles") { Task { await assistant.review(feature.slug, focus: object.id) } }
                SmallButton(title: "Acceptance criteria", icon: "sparkles") { Task { await assistant.acceptanceCriteria(feature.slug, requirement: object.id) } }
            case .question:
                SmallButton(title: "Research", icon: "globe") { Task { await assistant.research(feature.slug, topic: object.title, for: object.id) } }
            case .finding:
                if (object.front["options"]?.list ?? []).isEmpty && !object.isClosed {
                    SmallButton(title: "Resolve", icon: "sparkles") { Task { await assistant.resolutionOptions(feature.slug, finding: object.id) } }
                }
            default:
                EmptyView()
            }
        }
        if object.kind == .finding { ResolutionOptions(store: store, feature: feature, finding: object) }
        if object.kind == .question && object.status == "open" { QuestionCard(store: store, feature: feature, question: object) }
        if ["review:" + feature.slug, "criteria:" + object.id, "research:" + feature.slug].contains(where: assistant.isRunning) {
            Working(text: "Working…")
        }
    }

    @ViewBuilder
    private var trace: some View {
        let upstream = feature.outgoing(object.id)
        let downstream = feature.incoming(object.id)
        let issues = object.front.strings("issues")
        if !upstream.isEmpty || !downstream.isEmpty || !issues.isEmpty {
            Text("TRACE").font(.system(size: 8, weight: .bold)).foregroundColor(VSDark.textDim).padding(.top, 2)
            ForEach(Array(upstream.enumerated()), id: \.offset) { _, link in traceRow("↑ " + relation(link.relation), link.to) }
            ForEach(Array(downstream.enumerated()), id: \.offset) { _, link in traceRow("↓ " + relation(link.relation, incoming: true), link.from) }
            ForEach(issues, id: \.self) { issue in
                HStack(spacing: 4) {
                    Text("↓ implemented by").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                    Button(issue) {
                        if let number = Int(issue.filter(\.isNumber)), let slug = assistant.gitHubClient()?.repo.slug,
                           let url = URL(string: "https://github.com/\(slug)/issues/\(number)") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.link).font(.system(size: 10))
                }
            }
        }
    }

    private func traceRow(_ label: String, _ target: FeatureObject) -> some View {
        Button(action: { workspaceManager.openFile(target.url) }) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 9)).foregroundColor(VSDark.textDim)
                Text(target.id).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(VSDark.blue)
                Text(target.title).font(.system(size: 10)).foregroundColor(VSDark.text).lineLimit(1)
                Spacer(minLength: 0)
            }
        }.buttonStyle(.plain)
    }

    private func relation(_ key: String, incoming: Bool = false) -> String {
        let names: [String: (String, String)] = [
            "depends_on": ("depends on", "needed by"), "decisions": ("follows", "applied in"), "sources": ("from", "source of"),
            "blocking": ("blocks", "blocked by"), "resolved_by": ("resolved by", "resolves"), "produces": ("produces", "produced by"),
            "requirements": ("covers", "covered by"), "related": ("related", "related"), "supersedes": ("supersedes", "superseded by"),
            "refs": ("about", "discussed in"), "questions": ("asks", "asked in"),
        ]
        let pair = names[key] ?? (key, key)
        return incoming ? pair.1 : pair.0
    }

    @ViewBuilder
    private var impact: some View {
        let (requirements, issues) = feature.impact(of: object.id)
        if !requirements.isEmpty || !issues.isEmpty || !mentions.isEmpty || !code.isEmpty {
            Text("CHANGE IMPACT").font(.system(size: 8, weight: .bold)).foregroundColor(VSDark.textDim).padding(.top, 2)
            ForEach(requirements) { traceRow("req", $0) }
            ForEach(issues) { issue in
                Text("issue \(issue.github.map { "#\($0)" } ?? issue.id) \(issue.title)").font(.system(size: 9)).foregroundColor(VSDark.text).lineLimit(1)
            }
            ForEach(mentions, id: \.self) { path in
                Button(path) { if let root = store.root { workspaceManager.openFile(root.appendingPathComponent(path)) } }
                    .buttonStyle(.link).font(.system(size: 9))
            }
            if !code.isEmpty {
                Text("Potentially affected code").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                ForEach(code.prefix(12), id: \.self) { Text($0).font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.text).lineLimit(1) }
            }
        }
    }

    /// History, documents that mention the id, and code of the pull requests implementing it.
    private func load() async {
        let key = object.id + object.front.string("updated")
        guard loadedFor != key, let root = store.root else { return }
        loadedFor = key
        history = await store.history(of: object.url)
        guard object.kind == .decision || object.kind == .requirement else { return }
        let grep = await GitHubClient.execute(["grep", "-l", "-w", object.id, "--", "*.md"], in: root, git: true)
        let own = store.relativePath(feature.folder) + "/"
        mentions = grep.stdout.split(separator: "\n").map(String.init).filter { !$0.hasPrefix(own) }
        var files: [String] = []
        let numbers = Set(feature.impact(of: object.id).issues.compactMap(\.github) + object.front.strings("issues").compactMap { Int($0.filter(\.isNumber)) })
        for number in numbers.prefix(5) {
            for pr in await assistant.pullRequests(closing: number) { files += await assistant.files(of: pr.number) }
        }
        code = Array(Set(files)).sorted()
    }
}
