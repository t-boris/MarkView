import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The object open in the editor (trace, impact, history; spec §21, §27, §30), the outdated requirements banner and the cleanup sheet.

struct ObjectContextView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let object: FeatureObject
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var history: [String] = []
    @State private var mentions: [String] = []
    @State private var code: [String] = []
    @State private var loadedFor = ""


    var body: some View {
        FeatureCard {
            HStack(spacing: 5) {
                Image(systemName: object.kind.icon).uiFont(size: 10).foregroundColor(palette.blue)
                Text(object.id).uiFont(size: 11, weight: .bold, design: .monospaced).foregroundColor(palette.textBright)
                Spacer()
                statusMenu
            }
            let provenance = object.front.string("provenance")
            if !provenance.isEmpty {
                Text(provenance + (object.front.string("created").isEmpty ? "" : " · \(object.front.string("created"))"))
                    .uiFont(size: 9).foregroundColor(palette.textDim)
            }
            actions
            trace
            if object.kind == .decision || object.kind == .requirement { impact }
            if !history.isEmpty {
                Text("HISTORY").uiFont(size: 8, weight: .bold).foregroundColor(palette.textDim).padding(.top, 2)
                ForEach(history.prefix(6), id: \.self) { Text($0).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim).lineLimit(1) }
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
            Text(FeatureVocabulary.label(object.status.isEmpty ? "—" : object.status)).uiFont(size: 10, weight: .semibold)
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
            if [.requirement, .decision, .question, .finding, .research].contains(object.kind) {
                SmallButton(title: "Delete…", icon: "trash") {
                    FeatureObjectDeletion.confirmAndDelete([object.id], in: feature, store: store, workspace: workspaceManager)
                }
            }
        }
        if object.kind == .finding { ResolutionOptions(store: store, feature: feature, finding: object) }
        if object.kind == .question && object.status == "open" { QuestionRound(store: store, feature: feature, questions: [object]).id(object.id) }
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
            Text("TRACE").uiFont(size: 8, weight: .bold).foregroundColor(palette.textDim).padding(.top, 2)
            ForEach(Array(upstream.enumerated()), id: \.offset) { _, link in traceRow("↑ " + relation(link.relation), link.to) }
            ForEach(Array(downstream.enumerated()), id: \.offset) { _, link in traceRow("↓ " + relation(link.relation, incoming: true), link.from) }
            ForEach(issues, id: \.self) { issue in
                HStack(spacing: 4) {
                    Text("↓ implemented by").uiFont(size: 9).foregroundColor(palette.textDim)
                    Button(issue) {
                        if let number = Int(issue.filter(\.isNumber)), let slug = assistant.gitHubClient()?.repo.slug,
                           let url = URL(string: "https://github.com/\(slug)/issues/\(number)") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.link).uiFont(size: 10)
                }
            }
        }
    }

    private func traceRow(_ label: String, _ target: FeatureObject) -> some View {
        Button(action: { workspaceManager.openFile(target.url) }) {
            HStack(spacing: 4) {
                Text(label).uiFont(size: 9).foregroundColor(palette.textDim)
                Text(target.id).uiFont(size: 9, weight: .semibold, design: .monospaced).foregroundColor(palette.blue)
                Text(target.title).uiFont(size: 10).foregroundColor(palette.text).lineLimit(1)
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
            Text("CHANGE IMPACT").uiFont(size: 8, weight: .bold).foregroundColor(palette.textDim).padding(.top, 2)
            ForEach(requirements) { traceRow("req", $0) }
            ForEach(issues) { issue in
                Text("issue \(issue.github.map { "#\($0)" } ?? issue.id) \(issue.title)").uiFont(size: 9).foregroundColor(palette.text).lineLimit(1)
            }
            ForEach(mentions, id: \.self) { path in
                Button(path) { if let root = store.root { workspaceManager.openFile(root.appendingPathComponent(path)) } }
                    .buttonStyle(.link).uiFont(size: 9)
            }
            if !code.isEmpty {
                Text("Potentially affected code").uiFont(size: 9).foregroundColor(palette.textDim)
                ForEach(code.prefix(12), id: \.self) { Text($0).uiFont(size: 9, design: .monospaced).foregroundColor(palette.text).lineLimit(1) }
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

/// "N outdated requirements — Clean up…": opens the cleanup sheet with the requirements chosen.
struct OutdatedRequirementsBanner: View {
    @Environment(\.palette) private var palette
    @ObservedObject var store: FeatureStore
    let feature: Feature
    @State private var showing = false

    var body: some View {
        let outdated = feature.outdatedRequirements
        let superseded = outdated.filter { $0.status == "superseded" }.count
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(outdated.count) outdated requirements").uiFont(size: 10, weight: .semibold).foregroundColor(palette.text)
                Text("\(superseded) merged in a consolidation, \(outdated.count - superseded) rejected")
                    .uiFont(size: 9).foregroundColor(palette.textDim)
            }
            Spacer()
            SmallButton(title: "Clean up…", icon: "trash") { showing = true }
        }
        .padding(8).background(palette.bgInput.opacity(0.5)).cornerRadius(5)
        .sheet(isPresented: $showing) {
            FeatureCleanupSheet(store: store, slug: feature.slug, selected: [.requirements]) { showing = false }
        }
    }
}

/// Preview of what a cleanup removes, by category; the chosen objects go to the Trash and the
/// links to them move to their replacements or are removed.
struct FeatureCleanupSheet: View {
    @Environment(\.palette) private var palette
    @ObservedObject var store: FeatureStore
    @ObservedObject var assistant: FeatureAssistant
    let slug: String
    @State var selected: Set<FeatureCleanup>
    let close: () -> Void
    @State private var marked: String?

    init(store: FeatureStore, slug: String, selected: Set<FeatureCleanup>, close: @escaping () -> Void) {
        self.store = store
        self.assistant = store.assistant
        self.slug = slug
        self._selected = State(initialValue: selected)
        self.close = close
    }
    @State private var expanded: Set<FeatureCleanup> = []
    @State private var working = false
    @State private var removed: Int?

    var body: some View {
        let feature = store.feature(slug)
        let candidates = Dictionary(uniqueKeysWithValues: FeatureCleanup.allCases.map { ($0, feature?.cleanupCandidates($0) ?? []) })
        let chosen = FeatureCleanup.allCases.filter { selected.contains($0) }.flatMap { candidates[$0] ?? [] }
        VStack(alignment: .leading, spacing: 10) {
            Text("Clean up \(feature?.title ?? slug)").uiFont(size: 13, weight: .semibold)
            Text("Chosen files go to the Trash (restorable). Links to them in the remaining objects and the plan move to the object that replaced them, or are removed.")
                .uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Decisions and findings written against older requirements").uiFont(size: 11, weight: .medium)
                    Text(marked ?? "AI compares them with the current requirements and marks the ones that no longer apply (decisions superseded, findings dismissed); they then appear below.")
                        .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if assistant.isRunning("outdated:" + slug) {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    Text("Checking… a few minutes").uiFont(size: 10).foregroundColor(palette.textDim)
                } else {
                    Button("Find outdated (AI)") {
                        marked = nil
                        Task {
                            if let result = await assistant.markOutdated(slug) {
                                marked = "Marked \(result.decisions) decisions and \(result.findings) findings as outdated — see the lists below."
                                if result.decisions > 0 { selected.insert(.decisions) }
                                if result.findings > 0 { selected.insert(.findings) }
                            } else {
                                marked = assistant.error ?? "The check failed."
                            }
                        }
                    }
                    .disabled(working || removed != nil)
                }
            }
            .padding(8).background(Color.secondary.opacity(0.08)).cornerRadius(5)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(FeatureCleanup.allCases) { category in
                        section(category, objects: candidates[category] ?? [])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180, maxHeight: 380)
            HStack {
                if let removed {
                    Text("\(removed) files moved to the Trash.").uiFont(size: 11).foregroundColor(palette.textDim)
                } else if working {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    Text("Deleting…").uiFont(size: 11).foregroundColor(palette.textDim)
                }
                Spacer()
                Button(removed == nil ? "Cancel" : "Done", action: close).keyboardShortcut(.cancelAction)
                if removed == nil {
                    Button("Move \(chosen.count) to Trash", role: .destructive) {
                        working = true
                        let ids = Set(chosen.map(\.id))
                        // Let the spinner draw before the (synchronous) file work.
                        DispatchQueue.main.async {
                            removed = store.cleanUp(slug, ids: ids)
                            working = false
                        }
                    }
                    .disabled(chosen.isEmpty || working)
                }
            }
        }
        .padding(16).frame(width: 520)
    }

    private func section(_ category: FeatureCleanup, objects: [FeatureObject]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { selected.contains(category) },
                                     set: { if $0 { selected.insert(category) } else { selected.remove(category) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(category.title) (\(objects.count))").uiFont(size: 12, weight: .medium)
                        Text(category.detail).uiFont(size: 10).foregroundColor(palette.textDim)
                    }
                }
                .disabled(objects.isEmpty || working || removed != nil)
                Spacer()
                if !objects.isEmpty {
                    Button(expanded.contains(category) ? "Hide" : "Show") {
                        if expanded.contains(category) { expanded.remove(category) } else { expanded.insert(category) }
                    }
                    .buttonStyle(.link).uiFont(size: 10)
                }
            }
            if expanded.contains(category) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(objects, id: \.id) { object in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(object.id).uiFont(size: 10, design: .monospaced).foregroundColor(palette.textDim)
                            Text(object.title).uiFont(size: 10).lineLimit(1)
                            Spacer()
                            Text(object.status).uiFont(size: 9).foregroundColor(palette.textDim)
                        }
                        let reason = object.front.string("outdated_reason") + object.front.string("dismissed_reason")
                        if !reason.isEmpty {
                            Text(reason).uiFont(size: 9).foregroundColor(palette.textDim).lineLimit(2).padding(.leading, 12)
                        }
                    }
                }
                .padding(.leading, 22)
            }
        }
    }
}
