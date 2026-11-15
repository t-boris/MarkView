import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Build stage (spec §24–26): the requirements and the issue plan.

struct BuildStageView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature
    @EnvironmentObject var workspaceManager: WorkspaceManager


    var body: some View {
        let approved = feature.list(.requirement).filter { $0.status == "approved" }
        let issues = feature.planIssues
        let covered = Set(issues.flatMap(\.requirements))
        let missing = approved.filter { !covered.contains($0.id) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(approved.count) approved of \(feature.list(.requirement).filter { $0.status != "rejected" }.count) requirements")
                    .uiFont(size: 10).foregroundColor(palette.textDim)
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
                Text("Hand the specification to the AI terminal to implement.").uiFont(size: 10).foregroundColor(palette.textDim)
                Spacer()
                SmallButton(title: "Implement with AI", icon: "hammer") { workspaceManager.implementWithAI(feature.folder) }
            }
            let unapproved = feature.activeRequirements.filter { ["draft", "review"].contains($0.status) }
            if !unapproved.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("\(unapproved.count) requirement\(unapproved.count == 1 ? "" : "s") not approved yet. The plan uses approved ones; without any it uses all non-rejected.")
                        .uiFont(size: 9).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    SmallButton(title: "Approve all", icon: "checkmark.seal") { store.approveRequirements(feature.slug) }
                }
            }
            if !issues.isEmpty {
                PanelSection(title: "Implementation coverage") {
                    Text("\(approved.count - missing.count) / \(approved.count) requirements covered")
                        .uiFont(size: 10, weight: .semibold).foregroundColor(missing.isEmpty ? palette.green : palette.orange)
                    if !missing.isEmpty {
                        Text("Missing: " + missing.map(\.id).joined(separator: ", ")).uiFont(size: 10).foregroundColor(palette.orange)
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
    @Environment(\.palette) private var palette
    let id: String
    let title: String
    /// The issue it is dragged from (nil = not in the plan).
    let from: String?

    var body: some View {
        Text(id).uiFont(size: 9, weight: .semibold, design: .monospaced)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(palette.selection.opacity(0.5)).cornerRadius(3)
            .foregroundColor(palette.textBright)
            .help(title)
            .onDrag { NSItemProvider(object: "\(from ?? "")|\(id)" as NSString) }
    }
}

struct IssuePlanCard: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let issue: PlannedIssue
    @State private var targeted = false
    @State private var pulls: [(number: Int, title: String, url: String)] = []

    var body: some View {
        FeatureCard {
            HStack(spacing: 4) {
                Text(issue.id).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim)
                Text(issue.title).uiFont(size: 11, weight: .semibold).foregroundColor(palette.textBright).lineLimit(2)
                Spacer()
                if let number = issue.github {
                    Button("#\(number)") { openIssue(number) }.buttonStyle(.link).uiFont(size: 10)
                }
            }
            Text(issue.summary).uiFont(size: 10).foregroundColor(palette.text).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            FlowButtons {
                ForEach(issue.requirements, id: \.self) { id in
                    RequirementChip(id: id, title: feature.object(id)?.title ?? id, from: issue.id)
                        .contextMenu { Button("Remove from \(issue.id)") { move(id, from: issue.id, to: nil) } }
                }
                ForEach(issue.decisions, id: \.self) { id in
                    Text(id).uiFont(size: 9, design: .monospaced).foregroundColor(palette.purple)
                }
            }
            if let number = issue.github {
                if pulls.isEmpty {
                    Button("Pull requests") { Task { pulls = await assistant.pullRequests(closing: number) } }
                        .buttonStyle(.link).uiFont(size: 9)
                }
                ForEach(pulls, id: \.number) { pr in
                    Button("PR #\(pr.number) \(pr.title)") { if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) } }
                        .buttonStyle(.link).uiFont(size: 9)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(targeted ? palette.blue : Color.clear, lineWidth: 2))
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
        if let slug = assistant.gitHubClient()?.repo.slug, let url = URL(string: "https://github.com/\(slug)/issues/\(number)") {
            NSWorkspace.shared.open(url)
        }
    }
}
