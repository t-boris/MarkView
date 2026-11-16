import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Review stage (spec §12–14, §17): the findings, their resolutions and what is left to settle before the build.

struct ReviewStageView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Is the specification complete, consistent and ready?").uiFont(size: 10).foregroundColor(palette.textDim)
                Spacer()
                if assistant.isRunning("review:" + feature.slug) {
                    Working(text: "Reviewing the specification from every perspective — about a minute…")
                } else {
                    SmallButton(title: "Run review", icon: "sparkles", prominent: true) {
                        assistant.start("review:" + feature.slug) { await $0.review(feature.slug) }
                    }
                }
            }
            if !feature.outdatedRequirements.isEmpty {
                OutdatedRequirementsBanner(store: store, feature: feature)
            }
            if feature.activeRequirements.count > 30 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(feature.activeRequirements.count) requirements — too many to review or build well.")
                        .uiFont(size: 10, weight: .semibold).foregroundColor(palette.orange)
                    if assistant.isRunning("consolidate:" + feature.slug) {
                        Working(text: "Merging overlapping requirements into a compact set — a few minutes for large specs…")
                    } else {
                        SmallButton(title: "Consolidate requirements", icon: "arrow.triangle.merge", prominent: true) {
                            assistant.start("consolidate:" + feature.slug) { await $0.consolidateRequirements(feature.slug) }
                        }
                        .help("Merge duplicates and refinements; merged files stay with status superseded")
                    }
                }
                .padding(8).background(palette.orange.opacity(0.08)).cornerRadius(5)
            }
            let open = feature.list(.finding).filter { !$0.isClosed }
            if assistant.isRunning("decideall:" + feature.slug) {
                let progress = assistant.decideProgress[feature.slug]
                Working(text: "AI is resolving the findings itself — \(progress?.done ?? 0) of \(progress?.total ?? open.count) done…")
            } else if !open.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("Too many to go through? AI resolves every open finding itself; its decisions are proposed, to accept or change.")
                        .uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    SmallButton(title: "Decide all for me (\(open.count))", icon: "wand.and.stars", prominent: true) {
                        assistant.start("decideall:" + feature.slug) { await $0.decideAllFindings(feature.slug) }
                    }
                }
            }
            PanelSection(title: "Review") {
                let counts = Dictionary(grouping: open) { $0.front.string("category") }
                ForEach(FeatureVocabulary.findingCategories, id: \.self) { category in
                    if let items = counts[category] {
                        HStack {
                            Text(FeatureVocabulary.label(category)).uiFont(size: 10).foregroundColor(palette.text)
                            Spacer()
                            Text("\(items.count)").uiFont(size: 10, design: .monospaced).foregroundColor(palette.textDim)
                        }
                    }
                }
                if open.isEmpty { Text(feature.list(.finding).isEmpty ? "No review yet." : "All findings are closed.").uiFont(size: 10).foregroundColor(palette.textDim) }
            }
            ForEach(FeatureVocabulary.severities, id: \.self) { severity in
                ForEach(open.filter { $0.front.string("severity") == severity }) { finding in
                    FindingCard(store: store, feature: feature, finding: finding)
                }
            }
            BeforeBuildSection(store: store, feature: feature)
        }
    }
}

/// A finding with its lifecycle actions (spec §14).
struct FindingCard: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let finding: FeatureObject
    @EnvironmentObject private var flow: FeatureFlowCoordinator
    @State private var own = ""
    /// What was just asked for this finding, shown at once.
    @State private var started: String?


    var body: some View {
        FeatureCard {
            HStack(spacing: 4) {
                Text(finding.front.string("severity").uppercased()).uiFont(size: 8, weight: .bold)
                    .foregroundColor(["blocker", "high"].contains(finding.front.string("severity")) ? palette.red : palette.orange)
                Text(FeatureVocabulary.label(finding.front.string("category")).uppercased()).uiFont(size: 8).foregroundColor(palette.textDim)
                Spacer()
                Text(finding.id).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim)
            }
            Text(finding.title).uiFont(size: 11, weight: .semibold).foregroundColor(palette.textBright).fixedSize(horizontal: false, vertical: true)
            let quote = finding.front.string("quote")
            if !quote.isEmpty {
                Text("“\(quote)”").uiFont(size: 10, italic: true).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            let detail = finding.section("Finding")
            if !detail.isEmpty { Text(detail).uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true) }
            let interpretations = finding.front.strings("interpretations")
            if !interpretations.isEmpty {
                ForEach(interpretations, id: \.self) { Text("• " + $0).uiFont(size: 10).foregroundColor(palette.text) }
            }
            Text(finding.front.strings("perspectives").joined(separator: " · ")).uiFont(size: 9).foregroundColor(palette.cyan)
            ResolutionOptions(store: store, feature: feature, finding: finding)
            if let started, assistant.isRunning("chat:" + feature.slug) {
                Working(text: started)
            }
            if !assistant.isRunning("resolve:" + finding.id) && !assistant.isRunning("resolveopts:" + finding.id)
                && !assistant.isRunning("decideall:" + feature.slug) {
                FlowButtons {
                    SmallButton(title: "Decide for me", icon: "wand.and.stars") {
                        assistant.start("resolve:" + finding.id) { await $0.resolve(feature.slug, finding: finding.id, with: "", delegated: true) }
                    }
                    .help("AI chooses the resolution itself; the decision is recorded as proposed")
                    if (finding.front["options"]?.list ?? []).isEmpty {
                        SmallButton(title: "Resolve", icon: "sparkles", prominent: true) {
                            assistant.start("resolveopts:" + finding.id) { await $0.resolutionOptions(feature.slug, finding: finding.id) }
                        }
                    }
                    SmallButton(title: "Discuss") {
                        started = "Sent to the discussion — the reply appears at the top of this panel…"
                        assistant.start("chat:" + feature.slug) { await $0.chat(feature.slug, message: "Let's discuss \(finding.id): \(finding.title)") }
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
            flow.open(object.url)
        } else if let root = store.root, !target.isEmpty, !target.contains("..") {
            let url = root.appendingPathComponent(target)
            if FileManager.default.fileExists(atPath: url.path) { flow.open(url); return }
            flow.open(finding.url)
        } else {
            flow.open(finding.url)
        }
    }
}

/// The ways to resolve a finding (AI-proposed), as buttons, plus the user's own answer.
struct ResolutionOptions: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let finding: FeatureObject
    @State private var own = ""
    /// The resolution just chosen, shown at once while the decision is written.
    @State private var chosen: String?

    var body: some View {
        let options = finding.front["options"]?.list ?? []
        if assistant.isRunning("resolve:" + finding.id) {
            VStack(alignment: .leading, spacing: 3) {
                if let chosen {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").uiFont(size: 10).foregroundColor(palette.green)
                        Text(chosen).uiFont(size: 10, weight: .medium).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Working(text: chosen == nil ? "AI is choosing how to resolve \(finding.id)…" : "Recording the decision and closing \(finding.id)…")
            }
        } else if assistant.isRunning("resolveopts:" + finding.id) {
            Working(text: "Looking for ways to resolve \(finding.id)…")
        } else if !options.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                let question = finding.front.string("resolution_question")
                if !question.isEmpty { Text(question).uiFont(size: 10, weight: .semibold).foregroundColor(palette.yellow) }
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let text = option["text"]?.string ?? ""
                    VStack(alignment: .leading, spacing: 1) {
                        SmallButton(title: option["label"]?.string ?? "Option", prominent: true) {
                            chosen = (option["label"]?.string ?? "") + " — " + text
                            assistant.start("resolve:" + finding.id) { await $0.resolve(feature.slug, finding: finding.id, with: text) }
                        }
                        Text(text).uiFont(size: 9).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                        let consequence = option["consequence"]?.string ?? ""
                        if !consequence.isEmpty { Text("→ " + consequence).uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                HStack(spacing: 4) {
                    TextField("Another way…", text: $own).textFieldStyle(.plain).uiFont(size: 10)
                        .padding(4).background(palette.bgInput).cornerRadius(3)
                    SmallButton(title: "Use") {
                        let text = own.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        own = ""
                        chosen = text
                        assistant.start("resolve:" + finding.id) { await $0.resolve(feature.slug, finding: finding.id, with: text) }
                    }
                }
            }
        }
    }
}

/// What is left to settle besides the findings above: blocking and open questions, the AI's
/// proposed decisions to confirm, open assumptions and research gaps. Hidden when nothing is left.
struct BeforeBuildSection: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature

    var body: some View {
        let blocking = feature.list(.question).filter { $0.isBlocking && !$0.isClosed }
        let otherQuestions = feature.list(.question).filter { !$0.isBlocking && $0.status == "open" }
        let assumptions = feature.list(.research).flatMap { note in
            (note.front["claims"]?.list ?? []).filter { $0["kind"]?.string == "open-assumption" }.compactMap { $0["text"]?.string }.map { (note.id, $0) }
        }
        let proposed = feature.list(.decision).filter { $0.status == "proposed" }
        let gaps = feature.understanding.filter { $0.state == "unknown" }

        if !(blocking.isEmpty && otherQuestions.isEmpty && proposed.isEmpty && assumptions.isEmpty && gaps.isEmpty) {
            VStack(alignment: .leading, spacing: 10) {
                PanelSection(title: "Before Build") {
                    summary("Blocking questions", blocking.count, palette.red)
                    summary("Open questions", otherQuestions.count, palette.yellow)
                    summary("Decisions to confirm", proposed.count, palette.yellow)
                    summary("Open assumptions", assumptions.count, palette.yellow)
                    summary("Research gaps", gaps.count, palette.textDim)
                }
                if !blocking.isEmpty { QuestionRound(store: store, feature: feature, questions: blocking) }
                ForEach(proposed) { decision in
                    FeatureCard {
                        HStack {
                            Text(decision.id).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim)
                            Text("PROPOSED").uiFont(size: 8, weight: .bold).foregroundColor(palette.yellow)
                        }
                        Text(decision.title).uiFont(size: 11, weight: .semibold).foregroundColor(palette.textBright)
                        Text(decision.section("Decision")).uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            SmallButton(title: "Accept", prominent: true) { store.setStatus(decision.id, in: feature.slug, to: "accepted") }
                            SmallButton(title: "Reject") { store.rejectDecision(decision.id, in: feature.slug) }
                        }
                    }
                }
                if !assumptions.isEmpty {
                    PanelSection(title: "Open assumptions") {
                        ForEach(assumptions, id: \.1) { item in
                            HStack(alignment: .top) {
                                Text("• \(item.1)").uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
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
                                Text(gap.dimension).uiFont(size: 10).foregroundColor(palette.text)
                                Spacer()
                                SmallButton(title: "Research", icon: "globe") {
                                    assistant.start("research:" + feature.slug) {
                                        await $0.research(feature.slug, topic: "\(gap.dimension) for \(feature.title)")
                                    }
                                }
                            }
                        }
                    }
                }
                if !otherQuestions.isEmpty { QuestionRound(store: store, feature: feature, questions: otherQuestions) }
            }
        }
    }

    private func summary(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack {
            Text(title).uiFont(size: 10).foregroundColor(palette.text)
            Spacer()
            Text("\(count)").uiFont(size: 10, weight: .semibold, design: .monospaced).foregroundColor(count > 0 ? color : palette.textDim)
        }
    }
}
