import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Right panel "Feature" tab: stages, readiness, the AI around the open document.
struct FeaturePanelView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var store: FeatureStore
    @ObservedObject var assistant: FeatureAssistant
    @EnvironmentObject private var tabs: TabsController
    @EnvironmentObject private var fileTree: WorkspaceFileTreeStore
    /// This window's stage (BUG-004: not shared between windows).
    @ObservedObject var layout: PanelLayout
    private var stage: FeatureStage {
        get { layout.featureStage }
        nonmutating set { layout.featureStage = newValue }
    }
    @State private var showConditions = false
    @State private var cleanup: Set<FeatureCleanup>?
    @State private var confirmRestart = false
    @State private var confirmDelete = false

    init(store: FeatureStore, layout: PanelLayout) {
        self.store = store
        self.assistant = store.assistant
        self.layout = layout
    }

    var body: some View {
        VStack(spacing: 0) {
            if fileTree.rootNode == nil {
                panelEmpty("Open a folder to work on features.")
            } else if let bug = openBug {
                // A bug report open in the editor: its investigation.
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        errors
                        actionProgress
                        BugPanelView(store: store, bug: bug)
                    }
                    .padding(10)
                }
                BugDiscussionInput(bug: bug)
            } else if let feature = store.active {
                header(feature)
                Divider().background(palette.border)
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        errors
                        actionProgress
                        if let located = openObject, located.feature.slug == feature.slug, let object = located.object {
                            ObjectContextView(store: store, feature: feature, object: object)
                        }
                        results(feature)
                        removedBanner(feature)
                        switch stage {
                        case .explore: ExploreStageView(store: store, feature: feature)
                        case .review: ReviewStageView(store: store, feature: feature)
                        case .build: BuildStageView(store: store, feature: feature)
                        }
                        IssueLifecycleSection(store: store, kind: .feature, issue: feature.slug, status: feature.status)
                            .id("lifecycle-feature-\(feature.slug)")
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
                panelEmpty("Create a feature with +, or choose one from navigation.")
            }
        }
        .background(palette.bgSidebar)
        // Every card watches the AI engine itself, so "working…" shows the moment a step starts.
        .environmentObject(assistant)
    }

    private var openObject: (feature: Feature, object: FeatureObject?)? {
        tabs.activeTab.flatMap { store.locate($0.url) }
    }

    @ViewBuilder private var actionProgress: some View {
        ForEach(assistant.actions.values.sorted { $0.started > $1.started }, id: \.key) { action in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: action.phase == .running ? "sparkle" :
                          action.phase == .completed ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundColor(action.phase == .failed ? palette.red : palette.blue)
                    Text(action.title)
                        .uiFont(size: 11, weight: .semibold)
                    Spacer()
                    if action.phase == .running {
                        TimelineView(.periodic(from: action.started, by: 1)) { context in
                            Text("\(Int(context.date.timeIntervalSince(action.started)))s")
                                .uiFont(size: 10, design: .monospaced)
                        }
                        Button("Stop") { assistant.stopAction(action.key) }
                    } else {
                        Button { assistant.dismissAction(action.key) } label: { Image(systemName: "xmark") }
                            .help("Dismiss action status")
                    }
                }
                Text("\(action.scope) · \(action.assistant) → \(action.output)")
                    .uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(2)
                Text(action.stage).uiFont(size: 10)
                    .foregroundColor(action.phase == .failed ? palette.red : palette.textDim)
                if action.phase == .running { ProgressView().controlSize(.mini) }
                if action.phase == .stopped || action.phase == .failed, !action.partial.isEmpty {
                    Text(action.partial.prefix(600)).uiFont(size: 10)
                        .lineLimit(6).textSelection(.enabled)
                    Text("Incomplete output").uiFont(size: 9).foregroundColor(palette.orange)
                }
                if action.phase == .stopped || action.phase == .failed {
                    Text("Run this action again from its original control to retry.")
                        .uiFont(size: 9).foregroundColor(palette.textDim)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.bgActive)
            .cornerRadius(6)
        }
    }

    private var openBug: BugReport? {
        tabs.activeTab.flatMap { store.bug(at: $0.url) }
    }

    /// Requirements or decisions were deleted: offer a question round about what they settled.
    @ViewBuilder
    private func removedBanner(_ feature: Feature) -> some View {
        let removed = feature.front.strings("removed_since_explore")
        if !removed.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Removed from the specification").uiFont(size: 10, weight: .semibold).foregroundColor(palette.orange)
                Text(removed.joined(separator: "\n")).uiFont(size: 10).foregroundColor(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if assistant.isRunning("explore:" + feature.slug) {
                    Working(text: "Asking about what they settled…")
                } else {
                    FlowButtons {
                        SmallButton(title: "Re-explore", icon: "sparkles", prominent: true) {
                            stage = .explore
                            assistant.start("explore:" + feature.slug) { await $0.reexplore(feature.slug) }
                        }
                        .help("A question round about what the removed requirements and decisions settled")
                        SmallButton(title: "Dismiss") {
                            store.updateFeature(feature.slug) { front, _ in front["removed_since_explore"] = nil }
                        }
                    }
                }
            }
            .padding(8).background(palette.orange.opacity(0.08)).cornerRadius(5)
        }
    }

    private func header(_ feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(feature.title).uiFont(size: 11, weight: .semibold).foregroundColor(palette.textBright).lineLimit(1)
                Spacer()
                SmallButton(title: "Clean up", icon: "trash") { cleanup = Set(FeatureCleanup.allCases) }
                    .help("Delete outdated requirements, answered questions, closed findings and cancelled decisions")
                if feature.isStructured, !store.hasImplementationStarted(feature) {
                    SmallButton(title: "Start over", icon: "arrow.counterclockwise") { confirmRestart = true }
                        .help("Start the feature again from its overview: everything produced from it goes to the Trash")
                }
                Menu {
                    Button("Delete Feature…") { confirmDelete = true }
                        .disabled(store.hasImplementationStarted(feature))
                    if store.hasImplementationStarted(feature) {
                        Text("Implementation started — start over and delete are off")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").uiFont(size: 11)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Delete this feature")
                FeatureStatusMenu(store: store, feature: feature)
            }
            .confirmationDialog("Start \(feature.title) over?", isPresented: $confirmRestart) {
                Button("Start over from the overview", role: .destructive) {
                    guard store.restartFeature(feature.slug) else { return }
                    stage = .explore
                    assistant.start("explore:" + feature.slug) { await $0.exploreNext(feature.slug) }
                }
            } message: {
                Text("Requirements, questions, decisions, findings, research, the plan and the discussion go to the Trash. The idea (overview) and the attached sources stay; discovery starts again.")
            }
            .confirmationDialog("Delete \(feature.title)?", isPresented: $confirmDelete) {
                Button("Move the feature to the Trash", role: .destructive) { store.deleteFeature(feature.slug) }
            } message: {
                let issues = feature.planIssues.compactMap(\.github).map { "#\($0)" }
                Text("The whole folder \(store.relativePath(feature.folder)) goes to the Trash (restorable)." + (issues.isEmpty ? "" : " Its GitHub issues (\(issues.joined(separator: ", "))) stay open on GitHub."))
            }
            .sheet(isPresented: Binding(get: { cleanup != nil }, set: { if !$0 { cleanup = nil } })) {
                FeatureCleanupSheet(store: store, slug: feature.slug, selected: cleanup ?? []) { cleanup = nil }
            }
            HStack(spacing: 2) {
                ForEach(FeatureStage.allCases, id: \.self) { item in
                    Button(action: {
                        // Leaving Explore once discovery is done approves the requirements.
                        if stage == .explore, item != .explore, feature.discoveryDone { store.finishExplore(feature.slug) }
                        stage = item
                    }) {
                        Text(item.rawValue.uppercased())
                            .uiFont(size: 9, weight: stage == item ? .bold : .regular, design: .monospaced)
                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                            .foregroundColor(stage == item ? palette.textBright : palette.textDim)
                            .background(stage == item ? palette.bgActive : Color.clear).cornerRadius(3)
                    }.buttonStyle(.plain)
                    if item != .build { Text("→").uiFont(size: 8).foregroundColor(palette.textDim) }
                }
            }
            Button(action: { showConditions.toggle() }) {
                HStack(spacing: 6) {
                    Text("Readiness").uiFont(size: 10).foregroundColor(palette.textDim)
                    ReadinessBar(value: feature.readiness)
                    Text("\(feature.readiness)%").uiFont(size: 10, design: .monospaced).foregroundColor(palette.text)
                }
            }.buttonStyle(.plain).help("Calculated from explicit conditions — click for details")
            if showConditions {
                ForEach(feature.readinessConditions) { c in
                    HStack(spacing: 4) {
                        Image(systemName: c.met ? "checkmark.circle.fill" : "circle").uiFont(size: 9)
                            .foregroundColor(c.met ? palette.green : palette.textDim)
                        Text(c.name).uiFont(size: 10).foregroundColor(palette.text)
                        Spacer()
                        Text("\(c.done)/\(c.total)").uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim)
                    }
                }
            }
            CycleTimeLink(kind: .feature, issue: feature.slug)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(palette.bg)
    }

    @ViewBuilder
    private var errors: some View {
        if let error = store.lastError ?? assistant.error {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "exclamationmark.triangle").uiFont(size: 9).foregroundColor(palette.red)
                Text(error).uiFont(size: 10).foregroundColor(palette.red).textSelection(.enabled)
                Spacer()
                Button(action: { store.lastError = nil; assistant.error = nil }) {
                    Image(systemName: "xmark").uiFont(size: 8).foregroundColor(palette.textDim)
                }.buttonStyle(.plain)
            }
            .padding(6).background(palette.red.opacity(0.1)).cornerRadius(4)
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
            Image(systemName: "square.stack.3d.up").uiFont(size: 22).foregroundColor(palette.textDim)
            Text(text).uiFont(size: 11).foregroundColor(palette.textDim).multilineTextAlignment(.center).padding(.horizontal, 16)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}
