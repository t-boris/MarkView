import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Pieces the Feature panel's views share: sections, buttons, cards, the wrapping button layout, the result and discussion boxes.

struct PanelSection<Content: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title.uppercased()).uiFont(size: 9, weight: .bold).foregroundColor(palette.textDim)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }
}

struct SmallButton: View {
    @Environment(\.palette) private var palette
    let title: String
    var icon: String? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).uiFont(size: 9) }
                Text(title).uiFont(size: 10, weight: prominent ? .semibold : .regular)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundColor(prominent ? .white : palette.text)
            .background(prominent ? palette.badge : palette.bgInput)
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }
}

struct Working: View {
    @Environment(\.palette) private var palette
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
            Text(text).uiFont(size: 10).foregroundColor(palette.textDim)
        }
    }
}

struct FeatureCard<Content: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5, content: content)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.bg)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(palette.border))
            .cornerRadius(5)
    }
}

func panelMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
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

/// An answer of a contextual action or of the discussion.
struct ResultCard: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let result: FeatureResult
    let feature: Feature
    @EnvironmentObject private var flow: FeatureFlowCoordinator

    var body: some View {
        FeatureCard {
            HStack {
                Image(systemName: "sparkles").uiFont(size: 9).foregroundColor(palette.blue)
                Text(result.title).uiFont(size: 10, weight: .semibold).foregroundColor(palette.textBright)
                Spacer()
                if result.pending { ProgressView().scaleEffect(0.4).frame(width: 10, height: 10) }
                Button(action: { assistant.dismissResult(result.id) }) {
                    Image(systemName: "xmark").uiFont(size: 8).foregroundColor(palette.textDim)
                }.buttonStyle(.plain)
            }
            Text(panelMarkdown(result.text.isEmpty ? "…" : result.text))
                .uiFont(size: 11).foregroundColor(palette.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let diagram = result.diagram {
                SmallButton(title: "Save diagram to feature", icon: "square.and.arrow.down") {
                    if let url = assistant.saveDiagram(diagram, title: "Diagram", in: feature.slug) { flow.open(url) }
                }
            }
            if let decision = result.decision {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This discussion appears to contain a decision:").uiFont(size: 10).foregroundColor(palette.yellow)
                    Text(decision.title).uiFont(size: 11, weight: .semibold).foregroundColor(palette.textBright)
                    HStack {
                        SmallButton(title: "Create Decision", icon: "signpost.right", prominent: true) {
                            assistant.saveDecision(decision, in: feature.slug, from: result.id)
                        }
                        SmallButton(title: "Continue Discussion") { assistant.dismissDecision(result.id) }
                    }
                }
            }
        }
    }
}

/// Free-form discussion with the facilitator (spec §32), always at the bottom of the tab.
struct DiscussionInput: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var assistant: FeatureAssistant
    @ObservedObject var store: FeatureStore
    let feature: Feature
    @State private var text = ""
    @FocusState private var textFocused: Bool

    var body: some View {
        DictationInput(text: $text, isFocused: { textFocused }, resetOn: feature.slug) { voice in
            VStack(spacing: 0) {
                Divider().background(palette.border)
                HStack(alignment: .bottom, spacing: 6) {
                    TextField("Discuss this feature…", text: $text, axis: .vertical)
                        .textFieldStyle(.plain).uiFont(size: 11).lineLimit(1...5)
                        .focused($textFocused)
                        .onSubmit(send)
                    voice.mic()
                    if assistant.isRunning("chat:" + feature.slug) {
                        ProgressView().scaleEffect(0.45).frame(width: 14, height: 14)
                    } else {
                        Button(action: send) { Image(systemName: "arrow.up.circle.fill").uiFont(size: 15).foregroundColor(palette.blue) }
                            .buttonStyle(.plain).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(8)
                .background(palette.bgInput)
                voice.status
                    .padding(.horizontal, 8)
            }
            .onChange(of: feature.slug) { _ in text = "" }
        }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let started = assistant.start("chat:" + feature.slug) { await $0.chat(feature.slug, message: message) }
        if started { text = "" }
    }
}
