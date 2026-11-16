import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Explore stage (spec §6–7, §9–10): the understanding, the question rounds and their cards.

/// An answer prepared on the Explore screen, before the round is applied: an option ("A. …"),
/// the user's own words, or "let the AI decide".
enum PendingAnswer: Equatable {
    case option(String)
    case text(String)
    case ai

    /// What the round sends for a question.
    func questionAnswer(for id: String) -> FeatureAssistant.QuestionAnswer {
        switch self {
        case .option(let text), .text(let text): return .init(id: id, answer: text)
        case .ai: return .init(id: id, answer: "", delegated: true)
        }
    }

    /// The AI's recommendation as the preselected answer: its option, or the answer itself.
    @MainActor static func recommended(for question: FeatureObject) -> PendingAnswer? {
        let recommended = question.front.string("recommended")
        guard !recommended.isEmpty else { return nil }
        let options = question.front["options"]?.list ?? []
        if options.contains(where: { ($0["label"]?.string ?? "").caseInsensitiveCompare(recommended) == .orderedSame }) {
            return .option(FeatureAssistant.recommendedAnswer(question))
        }
        return .text(recommended)
    }
}

struct ExploreStageView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature
    @EnvironmentObject private var layout: PanelLayout
    @State private var showUnderstandingDetails = false

    private var open: [FeatureObject] { feature.openQuestions }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelSection(title: "Feature understanding") {
                HStack(spacing: 6) {
                    Text(open.isEmpty ? (feature.isUnderstood ? "Discovery done" : "No open question")
                         : "\(open.count) open question\(open.count == 1 ? "" : "s")")
                        .uiFont(size: 10, weight: .semibold)
                        .foregroundColor(feature.isUnderstood ? palette.green : palette.text)
                    Text("· \(feature.discoveryAnswered) answered · \(feature.activeRequirements.count) requirements"
                         + expectation)
                        .uiFont(size: 10).foregroundColor(palette.textDim)
                    Spacer()
                    Button {
                        showUnderstandingDetails.toggle()
                    } label: {
                        Label(showUnderstandingDetails ? "Hide details" : "Details",
                              systemImage: showUnderstandingDetails ? "chevron.up" : "chevron.down")
                            .uiFont(size: 10)
                    }
                    .buttonStyle(.plain)
                }
                if showUnderstandingDetails {
                    Text("The AI's assessment of what the specification covers; it does not decide the questions.")
                        .uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    if !feature.openDimensions.isEmpty {
                        Text("Rated partial or unknown: " + feature.openDimensions.joined(separator: ", "))
                            .uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        ForEach(FeatureVocabulary.understandingStates, id: \.self) { state in
                            HStack(spacing: 2) {
                                Text(symbol(state)).uiFont(size: 9, weight: .bold, design: .monospaced).foregroundColor(color(state))
                                Text(state).uiFont(size: 9).foregroundColor(palette.textDim)
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
                                Text(symbol(item.state)).uiFont(size: 10, weight: .bold, design: .monospaced).foregroundColor(color(item.state))
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("\(item.dimension): \(item.state) — click to change")
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(item.dimension).uiFont(size: 10, weight: .medium).foregroundColor(palette.text)
                                    Text(item.state).uiFont(size: 9).foregroundColor(color(item.state))
                                }
                                if !note.isEmpty {
                                    Text(note).uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            if feature.isUnderstood && open.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill").foregroundColor(palette.green)
                        Text("Feature understood").uiFont(size: 11, weight: .semibold).foregroundColor(palette.textBright)
                    }
                    Text("Every question is settled and the AI expects no further one, so discovery is done. Leaving Explore approves the requirements. Next: review the specification.")
                        .uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                    FlowButtons {
                        SmallButton(title: "Go to Review", icon: "arrow.right", prominent: true) {
                            store.finishExplore(feature.slug)
                            layout.featureStage = .review
                        }
                        SmallButton(title: "Ask more questions", icon: "sparkles") {
                            assistant.start("explore:" + feature.slug) { await $0.exploreNext(feature.slug) }
                        }
                    }
                }
                .padding(8).background(palette.green.opacity(0.08)).cornerRadius(5)
            } else if assistant.isRunning("decide:" + feature.slug) {
                Working(text: "AI is deciding the remaining questions and finishing discovery…")
            } else if assistant.isRunning("explore:" + feature.slug) {
                Working(text: "Looking at what is still unclear…")
            } else if !open.isEmpty {
                QuestionRound(store: store, feature: feature, questions: open)
            } else {
                HStack {
                    Text(feature.list(.question).isEmpty ? "Start guided discovery." : "No open question.")
                        .uiFont(size: 10).foregroundColor(palette.textDim)
                    Spacer()
                    SmallButton(title: "Ask more questions", icon: "sparkles", prominent: true) {
                        assistant.start("explore:" + feature.slug) { await $0.exploreNext(feature.slug) }
                    }
                }
            }
            if !feature.isUnderstood && !assistant.isRunning("decide:" + feature.slug) {
                HStack(alignment: .top, spacing: 6) {
                    Text("AI decides unresolved questions for review.")
                        .uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    SmallButton(title: "Decide the rest and finish", icon: "flag.checkered") {
                        assistant.start("decide:" + feature.slug) { await $0.decideRest(feature.slug) }
                    }
                }
            }
            SourcesSection(store: store, feature: feature)
        }
    }

    /// "· AI expects ~2 more" while discovery is running.
    private var expectation: String {
        guard let left = feature.questionsLeft, left > 0, !feature.isUnderstood else { return "" }
        let more = max(0, left - open.count)
        return more > 0 ? " · AI expects ~\(more) more" : ""
    }

    private func symbol(_ state: String) -> String {
        switch state { case "known": return "✓"; case "partial": return "~"; case "n/a": return "–"; default: return "?" }
    }

    private func color(_ state: String) -> Color {
        switch state { case "known": return palette.green; case "partial": return palette.yellow; case "n/a": return palette.textDim; default: return palette.orange }
    }
}

/// The open questions of a round on one screen: each card with the recommended answer
/// preselected, and one button that applies every answer in a single AI call (spec §7).
struct QuestionRound: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let questions: [FeatureObject]
    /// Answers changed by the user; a question not here keeps the AI's recommendation.
    @State private var chosen: [String: PendingAnswer?] = [:]

    private var applying: Bool { assistant.isRunning("answer:" + feature.slug) }

    private func answer(for question: FeatureObject) -> PendingAnswer? {
        if let changed = chosen[question.id] { return changed }
        return PendingAnswer.recommended(for: question)
    }

    private var answers: [FeatureAssistant.QuestionAnswer] {
        questions.compactMap { question in answer(for: question)?.questionAnswer(for: question.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(questions, id: \.id) { question in
                QuestionCard(store: store, feature: feature, question: question,
                             selection: Binding(get: { answer(for: question) }, set: { chosen[question.id] = $0 }),
                             busy: applying)
                    .id(question.id)
            }
            if applying {
                Working(text: "Applying \(answers.count) answer\(answers.count == 1 ? "" : "s") — updating the specification and preparing the next questions…")
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Text(questions.count == 1 ? "The recommended answer is preselected; change it or answer in your own words."
                         : "Recommended answers are preselected; change any of them, then apply the round.")
                        .uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    SmallButton(title: answers.count == 1 ? "Apply answer" : "Apply \(answers.count) answers",
                                icon: "checkmark", prominent: true) {
                        let round = answers
                        chosen = [:]
                        assistant.start("answer:" + feature.slug) { await $0.answerBatch(feature.slug, answers: round) }
                    }
                    .disabled(answers.isEmpty)
                    .opacity(answers.isEmpty ? 0.5 : 1)
                }
            }
        }
    }
}

/// A question with its options, the AI's recommendation and the discovery actions (spec §7, §15).
/// The answer is chosen here and applied by the round.
struct QuestionCard: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let question: FeatureObject
    @Binding var selection: PendingAnswer?
    /// The round is being applied: the answer is shown, nothing can change.
    var busy = false
    @EnvironmentObject private var flow: FeatureFlowCoordinator
    @State private var own = ""
    @FocusState private var ownFocused: Bool
    @State private var showDetails = false

    private var working: Bool {
        busy || ["options:", "pros:"].contains { assistant.isRunning($0 + question.id) }
            || assistant.isRunning("research:" + feature.slug) || assistant.isRunning("decide:" + feature.slug)
    }

    var body: some View {
        FeatureCard {
            HStack(spacing: 4) {
                Text(question.id).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim)
                if question.isBlocking { Text("BLOCKING").uiFont(size: 8, weight: .bold).foregroundColor(palette.red) }
                Text(question.front.string("q_type").uppercased()).uiFont(size: 8).foregroundColor(palette.textDim)
                if !question.front.string("dimension").isEmpty {
                    Text("clarifies " + question.front.string("dimension")).uiFont(size: 8, weight: .semibold).foregroundColor(palette.cyan)
                }
                Spacer()
                Button(action: { flow.open(question.url) }) {
                    Image(systemName: "doc.text").uiFont(size: 9).foregroundColor(palette.textDim)
                }.buttonStyle(.plain).help("Open \(question.id)")
            }
            Text(question.section("Question").isEmpty ? question.title : question.section("Question"))
                .uiFont(size: 11, weight: .semibold).foregroundColor(palette.textBright).fixedSize(horizontal: false, vertical: true)
            let why = question.section("Why it matters")
            if !why.isEmpty {
                Text(why).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            let recommended = question.front.string("recommended")
            let recommendedWhy = question.front.string("recommended_why")
            if !recommended.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "wand.and.stars").uiFont(size: 9).foregroundColor(palette.cyan)
                    Text("AI recommends \(recommended)" + (recommendedWhy.isEmpty ? "" : " — \(recommendedWhy)"))
                        .uiFont(size: 10).foregroundColor(palette.cyan).fixedSize(horizontal: false, vertical: true)
                }
            }
            let options = question.front["options"]?.list ?? []
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let label = option["label"]?.string ?? ""
                let text = option["text"]?.string ?? ""
                let value = PendingAnswer.option("\(label). \(text)")
                VStack(alignment: .leading, spacing: 2) {
                    choice(selected: selection == value, enabled: !working) {
                        selection = value
                        own = ""
                    } label: {
                        Text(label).uiFont(size: 10, weight: .bold, design: .monospaced).foregroundColor(palette.blue)
                        Text(text).uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                        if label.caseInsensitiveCompare(recommended) == .orderedSame {
                            Text("recommended").uiFont(size: 8, weight: .semibold).foregroundColor(palette.cyan)
                        }
                    }
                    if showDetails {
                        ForEach(option["pros"]?.strings ?? [], id: \.self) { Text("+ " + $0).uiFont(size: 9).foregroundColor(palette.green).padding(.leading, 18) }
                        ForEach(option["cons"]?.strings ?? [], id: \.self) { Text("− " + $0).uiFont(size: 9).foregroundColor(palette.orange).padding(.leading, 18) }
                    }
                }
            }
            choice(selected: isOwn, enabled: !working, tappable: false) {
                if !isOwn { selection = own.isEmpty ? nil : .text(own) }
            } label: {
                DictationInput(text: $own, isFocused: { ownFocused }) { voice in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            TextField(options.isEmpty ? "Your answer…" : "Or answer in your own words…", text: $own)
                                .textFieldStyle(.plain).uiFont(size: 10)
                                .focused($ownFocused)
                            voice.mic(compact: true)
                        }
                        .padding(4).background(palette.bgInput).cornerRadius(3)
                        .disabled(working)
                        .onChange(of: own) { text in
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { selection = .text(trimmed) } else if isOwn { selection = nil }
                        }
                        voice.status
                    }
                }
            }
            choice(selected: selection == .ai, enabled: !working) {
                selection = .ai
                own = ""
            } label: {
                Text("Let the AI decide").uiFont(size: 10).foregroundColor(palette.text)
                Text(recommended.isEmpty ? "— its decision is recorded as proposed, to check in Review"
                     : "— takes the recommendation as a proposed decision, to check in Review")
                    .uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            if working && !busy {
                Working(text: "Working on \(question.id)…")
            } else if !busy {
                FlowButtons {
                    SmallButton(title: "Suggest another approach") {
                        assistant.start("options:" + question.id) { await $0.moreOptions(feature.slug, question: question.id) }
                    }
                    SmallButton(title: "Research this", icon: "globe") {
                        assistant.start("research:" + feature.slug) { await $0.research(feature.slug, topic: question.title, for: question.id) }
                    }
                    if !options.isEmpty {
                        SmallButton(title: showDetails ? "Hide pros/cons" : "Show pros/cons") {
                            let hasPros = options.contains { !($0["pros"]?.strings ?? []).isEmpty }
                            showDetails.toggle()
                            if showDetails && !hasPros {
                                assistant.start("pros:" + question.id) { await $0.prosAndCons(feature.slug, question: question.id) }
                            }
                        }
                    }
                    SmallButton(title: "Skip for now") {
                        assistant.start("skip:" + question.id) { await $0.skip(feature.slug, question: question.id) }
                    }
                }
            }
        }
        .onAppear {
            // An open-ended recommendation is the prefilled answer, editable.
            if case .text(let text)? = selection, own.isEmpty { own = text }
        }
    }

    private var isOwn: Bool {
        if case .text? = selection { return true }
        return false
    }

    /// A selectable row: a radio mark and the row's content. `tappable`: the content itself selects
    /// the row too (not for a row holding a text field, which needs its clicks).
    private func choice<Label: View>(selected: Bool, enabled: Bool, tappable: Bool = true, action: @escaping () -> Void,
                                     @ViewBuilder label: () -> Label) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Button(action: action) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .uiFont(size: 11).foregroundColor(selected ? palette.blue : palette.textDim)
            }
            .buttonStyle(.plain).disabled(!enabled)
            if tappable {
                HStack(alignment: .top, spacing: 5) { label() }
                    .contentShape(Rectangle())
                    .onTapGesture { if enabled { action() } }
            } else {
                HStack(alignment: .top, spacing: 5) { label() }
            }
        }
    }
}
