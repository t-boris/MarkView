import SwiftUI

/// The settings of one process as controls (BUG-115): how work starts, how it reaches the default branch, whether checks must pass,
/// which event counts as delivery and who accepts. The Processes page shows all of them; the card of an arrow in the diagram shows the
/// ones its step reads (`TransitionStory.processParts`), so a condition is changed where it is seen. Both edit the same draft.
struct WorkflowProcessControls: View {
    @Environment(\.palette) private var palette
    @Binding var variant: RuleVariant
    let parts: ProcessParts

    private enum EventKind: Hashable { case none, release, person }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if parts.contains(.start) || parts.contains(.delivery) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { startAndBranch; checks }
                    VStack(alignment: .leading, spacing: 6) { startAndBranch; checks }
                }
            }
            if parts.contains(.delivery) || parts.contains(.acceptance) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { deliveryAndAcceptance }
                    VStack(alignment: .leading, spacing: 6) { deliveryAndAcceptance }
                }
            }
        }
    }

    @ViewBuilder
    private var startAndBranch: some View {
        if parts.contains(.start) {
            labeled("Start") {
                Picker("", selection: $variant.start) { ForEach(StartEvidenceMode.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
        }
        if parts.contains(.delivery) {
            labeled("Reaches the branch") {
                Picker("", selection: $variant.integration) { ForEach(IntegrationPath.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
        }
    }

    @ViewBuilder
    private var checks: some View {
        if parts.contains(.delivery) {
            Toggle("Checks must pass", isOn: $variant.checks).toggleStyle(.checkbox).uiFont(size: 11)
        }
    }

    @ViewBuilder
    private var deliveryAndAcceptance: some View {
        if parts.contains(.delivery) {
            labeled("Delivery event") {
                Picker("", selection: eventKind) {
                    Text("None").tag(EventKind.none)
                    Text("A published GitHub release").tag(EventKind.release)
                    Text("A person confirms…").tag(EventKind.person)
                }
            }
            if case .humanConfirmed = variant.delivery {
                TextField("Event, for example: installed on the other Mac", text: eventName).textFieldStyle(.roundedBorder)
            }
        }
        if parts.contains(.acceptance) {
            labeled("Accepted by") {
                Picker("", selection: $variant.acceptance) { ForEach(AcceptanceMode.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
        }
    }

    private var eventKind: Binding<EventKind> {
        Binding(get: {
            switch variant.delivery {
            case .none: return .none
            case .githubRelease: return .release
            case .humanConfirmed: return .person
            }
        }, set: { kind in
            switch kind {
            case .none: variant.delivery = .none
            case .release: variant.delivery = .githubRelease
            case .person:
                if case .humanConfirmed = variant.delivery { return }
                variant.delivery = .humanConfirmed(name: "")
            }
        })
    }

    private var eventName: Binding<String> {
        Binding(get: {
            if case .humanConfirmed(let name) = variant.delivery { return name }
            return ""
        }, set: { variant.delivery = .humanConfirmed(name: $0) })
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) {
            Text(title).uiFont(size: 10).foregroundColor(palette.textDim)
            content().labelsHidden().fixedSize().controlSize(.small)
        }
    }
}
