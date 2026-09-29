import SwiftUI

/// Left panel: the file tree, or — when the project has docs/features or docs/bugs — its issues:
/// features and bugs, each with its GitHub issue.
struct LeftPanelView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        LeftPanelContent(store: workspaceManager.features, layout: workspaceManager.layout)
    }
}

private struct LeftPanelContent: View {
    @ObservedObject var store: FeatureStore
    /// This window's Files/Issues choice and open feature (BUG-004: not shared between windows).
    @ObservedObject var layout: PanelLayout
    @EnvironmentObject var workspaceManager: WorkspaceManager
    private var mode: String {
        get { layout.leftPanel }
        nonmutating set { layout.leftPanel = newValue }
    }
    /// The feature opened from the Issues list; kept so "New Feature" can open it.
    private var openFeature: String? {
        get { layout.issuesFeature.isEmpty ? nil : layout.issuesFeature }
        nonmutating set { layout.issuesFeature = newValue ?? "" }
    }

    var body: some View {
        let showingIssues = mode == "issues" && store.hasIssues
        VStack(spacing: 0) {
            if store.hasIssues {
                HStack(spacing: 4) {
                    sidebarButton("Files", symbol: "folder", selected: !showingIssues) { mode = "files" }
                    sidebarButton("Issues", symbol: "checklist", selected: showingIssues) { mode = "issues" }
                }
                .padding(6)
                Divider().background(VSDark.border)
            }
            if showingIssues {
                if let slug = openFeature, store.feature(slug) != nil {
                    FeatureNavigatorView(store: store, onBack: { openFeature = nil })
                } else {
                    IssuesListView(store: store, batch: workspaceManager.bugBatch) { slug in
                        store.activeSlug = slug
                        openFeature = slug
                        workspaceManager.showFeatureContext(slug)
                        if let feature = store.feature(slug) {
                            workspaceManager.openFile(feature.overviewURL)
                        }
                    }
                }
                // The basket stays in view while features are opened and closed (REQ-001).
                BugBasketView(batch: workspaceManager.bugBatch, assistant: store.assistant)
            } else {
                FileTreeView()
            }
        }
        .background(VSDark.bgSidebar)
    }

    private func sidebarButton(_ title: String, symbol: String, selected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .uiFont(size: 11, weight: selected ? .semibold : .regular)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? VSDark.bgActive : Color.clear)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(title) sidebar")
    }
}

/// Features (docs/features/*) and bugs (docs/bugs/*.md) of the project, filtered by the text
/// field and the funnel menu, ordered by the sort menu within each section (issue #24).
struct IssuesListView: View {
    @ObservedObject var store: FeatureStore
    /// The window's bug basket: open bugs can be put in it from their rows (issue #31).
    @ObservedObject var batch: BugBatch
    let open: (String) -> Void
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var filter = ""
    @State private var showFeatures = true
    @State private var showBugs = true

    var body: some View {
        let features = store.issueSort.sorted(store.features.filter {
            matches($0.title + " " + $0.slug) && store.issueFilter.matches($0.issueFacts)
        }, facts: \.issueFacts)
        let bugs = store.issueSort.sorted(store.bugs.filter {
            matches($0.title + " " + $0.key) && store.issueFilter.matches($0.issueFacts)
        }, facts: \.issueFacts)
        // Unfiltered, both sections show (with their "+"), even when empty.
        let filtering = !filter.isEmpty || !store.issueFilter.isDefault
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").uiFont(size: 9).foregroundColor(VSDark.textDim)
                TextField("Filter", text: $filter).textFieldStyle(.plain).uiFont(size: 11)
                filterMenu
                sortMenu
                IssueSyncButton(sync: store.issueSync, start: startSync)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            if !store.issueFilter.isDefault { activeFilterSummary }
            IssueSyncReportView(sync: store.issueSync)
            Divider().background(VSDark.border)
            if filtering, features.isEmpty, bugs.isEmpty {
                noMatches
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !(filtering && features.isEmpty) {
                            sectionHeader("Features", count: features.count, expanded: $showFeatures, kind: .feature)
                            if showFeatures {
                                ForEach(features) { featureRow($0) }
                            }
                        }
                        if !(filtering && bugs.isEmpty) {
                            sectionHeader("Bugs", count: bugs.count, expanded: $showBugs, kind: .bug)
                            if showBugs {
                                ForEach(bugs) { bugRow($0) }
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func featureRow(_ feature: Feature) -> some View {
        Button(action: { open(feature.slug) }) {
            HStack(spacing: 5) {
                Image(systemName: feature.isStructured ? "square.stack.3d.up" : "doc.text")
                    .uiFont(size: 9).foregroundColor(VSDark.blue).frame(width: 12)
                Text(feature.title).uiFont(size: 11).foregroundColor(VSDark.text).lineLimit(1)
                Spacer(minLength: 2)
                IssueLinks(numbers: feature.issueNumbers)
                // Without a status the feature reads as its default (Idea / Draft), muted.
                IssueStatusBadge(text: FeatureVocabulary.label(feature.status), tone: IssueStatus.tone(feature.issueFacts),
                                 muted: feature.front.string("status").isEmpty)
            }
            .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(feature.slug)
    }

    private func bugRow(_ bug: BugReport) -> some View {
        HStack(spacing: 0) {
            bugButton(bug)
            basketToggle(bug)
        }
    }

    /// In the basket, or open and can go in; other bugs keep the space empty so rows line up.
    @ViewBuilder private func basketToggle(_ bug: BugReport) -> some View {
        let inBasket = batch.contains(bug)
        if inBasket || batch.canAdd(bug) {
            Button(action: { batch.toggle(bug) }) {
                Image(systemName: inBasket ? "basket.fill" : "basket").uiFont(size: 9)
                    .foregroundColor(inBasket ? VSDark.blue : VSDark.textDim)
                    .frame(width: 18, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help(inBasket ? "Remove from basket" : "Add to basket — fix several bugs in one AI run")
        } else {
            Color.clear.frame(width: 22, height: 16)
        }
    }

    private func bugButton(_ bug: BugReport) -> some View {
        Button(action: {
            workspaceManager.showFeatureContext(nil)
            workspaceManager.openFile(bug.url)
        }) {
            HStack(spacing: 5) {
                Image(systemName: "ladybug").uiFont(size: 9)
                    .foregroundColor(["critical", "high"].contains(bug.severity) ? VSDark.red : VSDark.orange).frame(width: 12)
                Text(bug.key).uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim)
                Text(bug.title).uiFont(size: 11).foregroundColor(bug.status == "open" ? VSDark.text : VSDark.textDim).lineLimit(1)
                Spacer(minLength: 2)
                IssueLinks(numbers: bug.issueNumbers)
                IssueStatusBadge(text: bug.hasStatus ? IssueStatus.normalize(bug.status) : "open",
                                 tone: IssueStatus.tone(bug.issueFacts), muted: !bug.hasStatus)
            }
            .padding(.leading, 18).padding(.trailing, 2).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(bug.key) · \(bug.status)\(bug.severity.isEmpty ? "" : " · \(bug.severity)")")
    }

    /// Status, type and implementation toggles; highlighted while any is on (DEC-001, DEC-006).
    private var filterMenu: some View {
        let active = !store.issueFilter.isDefault
        return Menu {
            ForEach(IssueFilterToggle.Group.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(group.toggles, id: \.self) { toggle in
                        Toggle(toggle.title, isOn: Binding(get: { store.issueFilter.selected.contains(toggle) },
                                                           set: { _ in store.issueFilter.toggle(toggle) }))
                    }
                }
            }
            if active {
                Divider()
                Button("Reset Filter") { store.issueFilter = IssueFilter() }
            }
        } label: {
            Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 3).fill(active ? VSDark.blue.opacity(0.35) : Color.clear))
        .help(active ? "Filter: \(store.issueFilter.summary)" : "Filter by status and type")
    }

    /// Date or priority, and the direction; a new field starts newest / highest first (DEC-008).
    private var sortMenu: some View {
        let sort = store.issueSort
        return Menu {
            Section("Sort By") {
                ForEach(IssueSort.Field.allCases, id: \.self) { field in
                    Toggle(field.title, isOn: Binding(get: { sort.field == field },
                                                      set: { _ in if sort.field != field { store.issueSort = IssueSort(field: field) } }))
                }
            }
            Section("Order") {
                ForEach([true, false], id: \.self) { descending in
                    Toggle(IssueSort.directionTitle(sort.field, descending: descending),
                           isOn: Binding(get: { sort.descending == descending },
                                         set: { _ in store.issueSort.descending = descending }))
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(2)
        .help("Sort: \(sort.field.title), \(sort.directionTitle.lowercased())")
    }

    /// "Open · Bugs  ✕": the funnel filter in force; ✕ clears it, not the text or the sort (DEC-010).
    private var activeFilterSummary: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease").uiFont(size: 8).foregroundColor(VSDark.blue)
            Text(store.issueFilter.summary).uiFont(size: 10).foregroundColor(VSDark.text)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
            Button(action: { store.issueFilter = IssueFilter() }) {
                Image(systemName: "xmark.circle.fill").uiFont(size: 10).foregroundColor(VSDark.textDim)
            }
            .buttonStyle(.plain).help("Reset the filter")
        }
        .padding(.horizontal, 8).padding(.bottom, 4)
    }

    /// Nothing matches the text and the funnel together: one action clears both (DEC-009).
    private var noMatches: some View {
        VStack(spacing: 6) {
            Text("No matching items").uiFont(size: 11).foregroundColor(VSDark.textDim)
            Button("Reset Filters") {
                store.issueFilter = IssueFilter()
                filter = ""
            }
            .uiFont(size: 11)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    /// Every listed feature and bug, whatever the filter shows (issue #36).
    private func startSync() {
        guard let root = store.root else { return }
        store.issueSync.start(root: root, features: store.features.map(\.folder), bugs: store.bugs.map(\.url))
    }

    private func matches(_ text: String) -> Bool {
        filter.isEmpty || text.localizedCaseInsensitiveContains(filter)
    }

    private func sectionHeader(_ title: String, count: Int, expanded: Binding<Bool>, kind: IntakeKind) -> some View {
        HStack(spacing: 5) {
            Button(action: { expanded.wrappedValue.toggle() }) {
                HStack(spacing: 5) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").uiFont(size: 8).foregroundColor(VSDark.textDim).frame(width: 10)
                    Text(title.uppercased()).uiFont(size: 9, weight: .bold).foregroundColor(VSDark.textDim)
                    Text("\(count)").uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim)
                }
            }.buttonStyle(.plain)
            Spacer()
            Button(action: { workspaceManager.intake = IntakeRequest(kind: kind) }) {
                Image(systemName: "plus").uiFont(size: 9).foregroundColor(VSDark.textDim)
            }.buttonStyle(.plain).help(kind.title)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}

/// Status of a feature or bug in its row: up to 12 characters, then cut with the whole value in
/// the tooltip; the title gives way first (DEC-014).
struct IssueStatusBadge: View {
    let text: String
    let tone: IssueStatus.Tone
    /// No status written: the default is shown dimmed.
    var muted = false

    var body: some View {
        let color = muted ? VSDark.textDim : toneColor
        Text(text.count > 12 ? String(text.prefix(11)) + "…" : text)
            .uiFont(size: 9, weight: .medium)
            .foregroundColor(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15)))
            .fixedSize()
            .layoutPriority(1)
            .help(muted ? "No status set: \(text)" : "Status: \(text)")
    }

    private var toneColor: Color {
        switch tone {
        case .open: return VSDark.blue
        case .active: return VSDark.yellow
        case .done: return VSDark.green
        case .dropped: return VSDark.textDim
        }
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
                    .uiFont(size: 9, weight: .medium, design: .monospaced)
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
                        Image(systemName: "chevron.left").uiFont(size: 9)
                        Text("Issues").uiFont(size: 11)
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
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").uiFont(size: 8).foregroundColor(VSDark.textDim).frame(width: 10)
                    Image(systemName: "doc.on.doc").uiFont(size: 10).foregroundColor(VSDark.blue).frame(width: 14)
                    Text("Documents").uiFont(size: 11, weight: .medium).foregroundColor(VSDark.text)
                    Spacer()
                    Text("\(feature.documents.count)").uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if isExpanded {
                ForEach(feature.documents, id: \.self) { url in
                    Button(action: { open(url) }) {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text").uiFont(size: 9).foregroundColor(VSDark.textDim)
                            Text(url.deletingPathExtension().lastPathComponent).uiFont(size: 11)
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
            Text(feature.title).uiFont(size: 12, weight: .semibold).foregroundColor(VSDark.textBright).lineLimit(2)
            if !feature.issueNumbers.isEmpty { IssueLinks(numbers: feature.issueNumbers) }
            HStack(spacing: 6) {
                FeatureStatusMenu(store: store, feature: feature)
                Spacer()
                Text("\(feature.readiness)%").uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim)
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
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right").uiFont(size: 8).foregroundColor(VSDark.textDim).frame(width: 10)
                Image(systemName: kind.icon).uiFont(size: 10).foregroundColor(VSDark.blue).frame(width: 14)
                Text(kind.title).uiFont(size: 11, weight: .medium).foregroundColor(VSDark.text)
                Spacer()
                if !objects.isEmpty {
                    Text(openCount > 0 && openCount != objects.count ? "\(openCount)/\(objects.count)" : "\(objects.count)")
                        .uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim)
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
                        Text(object.id).uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim)
                        Text(object.title).uiFont(size: 11).foregroundColor(isActive(object.url) ? VSDark.textBright : VSDark.text).lineLimit(1)
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
                Image(systemName: icon).uiFont(size: 10).foregroundColor(VSDark.blue).frame(width: 14)
                Text(title).uiFont(size: 11, weight: .medium).foregroundColor(VSDark.text)
                Spacer()
                if let detail { Text(detail).uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim) }
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
                Image(systemName: showHistory ? "chevron.down" : "chevron.right").uiFont(size: 8).foregroundColor(VSDark.textDim).frame(width: 10)
                Image(systemName: "clock.arrow.circlepath").uiFont(size: 10).foregroundColor(VSDark.blue).frame(width: 14)
                Text("History").uiFont(size: 11, weight: .medium).foregroundColor(VSDark.text)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if showHistory {
            if history.isEmpty {
                Text("No commits yet").uiFont(size: 10).foregroundColor(VSDark.textDim).padding(.leading, 28)
            }
            ForEach(history, id: \.self) { line in
                Text(line).uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim)
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
            Text(FeatureVocabulary.label(feature.status)).uiFont(size: 10, weight: .semibold)
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
    /// New Research: documents to analyse first, the output path and whether the user edited it.
    @State private var targets: [URL] = []
    @State private var outputPath = ""
    @State private var outputPathEdited = false
    /// Voice input for the text; lives as long as the sheet — closing it discards a recording.
    @StateObject private var dictation = DictationController()
    @AppStorage(WhisperClient.apiKeyStorage) private var openAIKey = ""
    @State private var editorFocused = false

    init(request: IntakeRequest, workspaceManager: WorkspaceManager) {
        self.request = request
        self.workspaceManager = workspaceManager
        self.assistant = workspaceManager.features.assistant
        _text = State(initialValue: request.text)
        _attachments = State(initialValue: request.attachments)
        _linkedIssue = State(initialValue: request.linkedIssue)
        if request.kind == .research {
            _targets = State(initialValue: request.targets ?? workspaceManager.researchDefaultTargets)
            _outputPath = State(initialValue: Self.suggestedPath(for: request.text, root: workspaceManager.rootNode?.url))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).foregroundColor(VSDark.blue)
                Text(kind.title).uiFont(.headline)
                Spacer()
                if (kind == .understand || kind == .research), !openAIKey.isEmpty {
                    DictationButton(dictation: dictation, prominent: true) { transcript, window in
                        DictationInsertion.insert(transcript, window: window, fieldFocused: editorFocused, text: &text)
                    }
                }
            }
            Text(kind.prompt).uiFont(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            IntakeTextEditor(text: $text, focused: $editorFocused, attach: { urls in
                attachments += urls.filter { !attachments.contains($0) }
            }, failed: { failed = $0 })
                .frame(minWidth: 560, minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(editorBorder, lineWidth: dropping || dictation.isRecording ? 2 : 1))
                .overlay(alignment: .bottomTrailing) {
                    if kind != .understand, kind != .research, !openAIKey.isEmpty {
                        DictationButton(dictation: dictation) { transcript, window in
                            DictationInsertion.insert(transcript, window: window, fieldFocused: editorFocused, text: &text)
                        }
                        .padding(6)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            if let url { Task { @MainActor in attachments.append(url) } }
                        }
                    }
                    return true
                }
            DictationStatusView(dictation: dictation) { DDESettingsWindow.show(workspace: workspaceManager) }
            if kind == .research, let root = workspaceManager.rootNode?.url {
                ResearchIntakeOptions(root: root, targets: $targets, outputPath: $outputPath, outputPathEdited: $outputPathEdited)
            }
            if kind == .feature || kind == .quickFeature || kind == .bug, workspaceManager.gitHub.isAvailable {
                HStack(spacing: 8) {
                    Button("From GitHub Issue…") {
                        picking = true
                        if workspaceManager.gitHub.issues.isEmpty { workspaceManager.gitHub.refreshIssues() }
                    }
                    .popover(isPresented: $picking) { issuePicker }
                    if let linkedIssue {
                        HStack(spacing: 3) {
                            Text("Linked to #\(linkedIssue) — no new issue is filed").uiFont(.caption)
                            Button(action: { self.linkedIssue = nil }) { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundColor(.secondary)
                        }
                        if kind == .bug { Toggle("Add the analysis to #\(linkedIssue) as a comment", isOn: $commentOnIssue).uiFont(.caption) }
                    }
                    Spacer()
                }
            }
            HStack(spacing: 6) {
                Button("Add Files…") { chooseFiles() }
                Text("or paste images with ⌘V").uiFont(.caption).foregroundColor(.secondary)
            }
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
                Spacer()
            }
            }
            Text(footnote).uiFont(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failed { Text(failed).uiFont(.caption).foregroundColor(.red).textSelection(.enabled) }
            HStack {
                if loadingSource {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading \(request.loadIssue.map { "#\($0)" } ?? request.loadPullRequest.map { "PR #\($0)" } ?? "")…")
                        .uiFont(.caption).foregroundColor(.secondary)
                }
                if working {
                    ProgressView().scaleEffect(0.6)
                    Text("Analyzing…")
                        .uiFont(.caption).foregroundColor(.secondary)
                }
                Spacer()
                // Esc cancels a dictation first; the next Esc closes the sheet.
                Button(dictation.isActive ? "Cancel Dictation" : "Cancel") {
                    if dictation.isActive { dictation.cancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction).disabled(working && !dictation.isActive)
                Button(kind == .understand ? "Show in X-Ray" : kind == .research ? "Start Research" : "Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || loadingSource || dictation.isActive || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .task { await loadRequestedSource() }
        .onChange(of: text) { newText in
            // The path follows the question until the user edits it (DEC-006).
            if kind == .research, !outputPathEdited {
                outputPath = Self.suggestedPath(for: newText, root: workspaceManager.rootNode?.url)
            }
        }
        .onDisappear { dictation.cancel() }
        .onChange(of: openAIKey.isEmpty) { removed in
            // The key is gone: the mic disappears and its recording is discarded.
            if removed { dictation.cancel() }
        }
    }

    private var editorBorder: Color {
        if dropping { return VSDark.blue }
        return dictation.isRecording ? VSDark.red : VSDark.border
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
                Text(workspaceManager.gitHub.loadingIssues ? "Loading…" : "No open issues").uiFont(.caption).foregroundColor(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(issues) { issue in
                        Button(action: { load(issue.number) }) {
                            HStack(spacing: 5) {
                                Text("#\(issue.number)").uiFont(size: 11, design: .monospaced).foregroundColor(VSDark.blue)
                                Text(issue.title).uiFont(size: 11).lineLimit(1)
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
        switch kind {
        case .feature: return "sparkles"
        case .quickFeature: return "bolt"
        case .bug: return "ladybug"
        case .understand: return "magnifyingglass"
        case .research: return "books.vertical"
        }
    }

    private var footnote: String {
        let github = workspaceManager.gitHub.isAvailable
        switch kind {
        case .feature: return "Creates docs/features/<name>/ (overview, first requirements and questions, your text as a source)" + (github ? " and a GitHub issue." : ". Turn on the GitHub integration to also file an issue.")
        case .quickFeature: return "Creates a one-page feature specification with analysis and discussion, without question rounds" + (github ? " and a GitHub issue." : ".")
        case .bug: return "Writes docs/bugs/BUG-nnn-….md with reproduction steps and the suspected code" + (github ? ", and files it on GitHub." : ". Turn on the GitHub integration to also file it on GitHub.") + " What is still missing is asked in the Feature tab."
        case .understand: return "The answer opens at the top of the X-Ray right panel, with What, Why, How and Origin sections. Sources reveal the evidence in X-Ray or open it. Save as research keeps the answer in docs/research; nothing is saved automatically."
        case .research: return "Runs in the background (progress and Cancel under the editor) and opens the report when it is done. Findings are labelled project fact, external fact, AI inference or open assumption, with file paths and URLs. Attachments are copied to docs/research/assets/."
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        attachments += panel.urls
    }

    /// docs/research/<date>-<slug>.md for the question, with a free numeric suffix (DEC-006).
    static func suggestedPath(for question: String, root: URL?) -> String {
        ResearchDocument.relativePath(question: question, date: FeatureStore.today) { path in
            root.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(path).path) } ?? false
        }
    }

    /// Why `path` cannot be the new research document, or nil.
    static func pathProblem(_ path: String, root: URL) -> String? {
        let path = path.trimmingCharacters(in: .whitespaces)
        if path.isEmpty || !path.hasSuffix(".md") { return "The research is saved as a Markdown file: give a path ending in .md." }
        if path.hasPrefix("/") || path.split(separator: "/").contains("..") { return "Give a path inside the folder, such as docs/research/name.md." }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) { return "\(path) already exists; choose another name." }
        return nil
    }

    private func submit() {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .understand {
            dismiss()
            workspaceManager.understandInXRay(input, attachments: attachments)
            return
        }
        if kind == .research {
            guard let root = workspaceManager.rootNode?.url else { return }
            if let problem = Self.pathProblem(outputPath, root: root) {
                failed = problem
                return
            }
            dismiss()
            workspaceManager.research.start(question: input, relativePath: outputPath.trimmingCharacters(in: .whitespaces),
                                            targets: targets, attachments: attachments)
            return
        }
        working = true
        failed = nil
        Task {
            let outcome: FeatureAssistant.IntakeOutcome?
            switch kind {
            case .feature: outcome = await assistant.newFeature(from: input, attachments: attachments, linkedIssue: linkedIssue)
            case .quickFeature: outcome = await assistant.newQuickFeature(from: input, attachments: attachments, linkedIssue: linkedIssue)
            case .bug: outcome = await assistant.newBug(from: input, attachments: attachments, linkedIssue: linkedIssue,
                                                        commentOnIssue: commentOnIssue)
            case .understand, .research: outcome = nil
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
