import SwiftUI
import AppKit

/// The body of the "Hand off to code" sheet when the prototype has changes since the last sync (feature "Prototype and code stay in step",
/// REQ-016 to REQ-018): the draft of the feature that is created, with a before and after picture and an editable list of changes for
/// each unit, and the brief for an agent made from the same draft. Nothing is written to the project until "Create feature" is pressed.
struct PrototypeHandoffDraftView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var run: PrototypeHandoffRun
    let onClose: () -> Void
    @EnvironmentObject private var workspaceManager: WorkspaceManager

    private enum Tab: String, CaseIterable, Identifiable {
        case feature = "Feature", brief = "Brief for an agent"
        var id: String { rawValue }
    }

    @State private var tab = Tab.feature
    @State private var brief = ""
    @State private var briefEdited = false
    @State private var agent = TerminalProfile.claude
    @State private var copied = false
    @State private var showNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hand off to code").uiFont(size: 15, weight: .semibold).foregroundColor(palette.text)
            if let draft = run.draft {
                Text("\(draft.units.count) screen\(draft.units.count == 1 ? "" : "s") or component\(draft.units.count == 1 ? "" : "s") changed in the prototype since the last sync (v\(draft.baselineVersion)). Read and edit what the code must do, then create a feature to implement, or give the brief to an agent. Nothing is written to your project until you create the feature.")
                    .uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                progressRow
                switch tab {
                case .feature: featureTab(draft)
                case .brief: briefTab
                }
                footer
            }
        }
        .padding(16)
        .frame(width: 760)
        .onAppear { agent = TerminalProfile(AIAssistantPreferences.backend(project: workspaceManager.aiProject)) }
        .onChange(of: tab) { newTab in
            if newTab == .brief, !briefEdited { brief = run.brief() }
        }
    }

    // MARK: Progress

    @ViewBuilder private var progressRow: some View {
        let progress = run.progress
        if progress.running {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Screenshots \(progress.shotsDone)/\(progress.shotsTotal) · descriptions \(progress.describedDone)/\(progress.describedTotal)")
                    .uiFont(size: 11).foregroundColor(palette.textDim)
                Spacer()
                Button("Stop") { run.stop() }.controlSize(.small)
            }
        }
        if !progress.notes.isEmpty {
            DisclosureGroup(isExpanded: $showNotes) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(progress.notes, id: \.self) { note in
                        Text("• \(note)").uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("\(progress.notes.count) note\(progress.notes.count == 1 ? "" : "s") on screenshots and descriptions")
                    .uiFont(size: 11).foregroundColor(palette.textDim)
            }
        }
    }

    // MARK: Feature tab

    private func featureTab(_ draft: PrototypeHandoff.Draft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Feature title", text: Binding(get: { run.draft?.title ?? "" }, set: { run.setTitle($0) }))
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(draft.units) { unit in unitCard(unit) }
                }
            }
            .frame(height: 380)
        }
    }

    private func unitCard(_ unit: PrototypeHandoff.Unit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(unit.name).uiFont(size: 12, weight: .semibold).foregroundColor(palette.text)
                Text(unit.kind == .foundation ? "shell" : unit.kind.rawValue).uiFont(size: 10).foregroundColor(palette.textDim)
                Spacer()
                Text(unit.described ? "described by the assistant" : "from the review requests")
                    .uiFont(size: 10).foregroundColor(palette.textDim)
            }
            if !unit.alsoChangedInCode.isEmpty {
                Label("Also changed in the code since the last sync: " + unit.alsoChangedInCode.joined(separator: ", "), systemImage: "exclamationmark.triangle")
                    .uiFont(size: 10).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 8) {
                shot("Before (v\(run.draft?.baselineVersion ?? 0))", unit.before, running: run.progress.running)
                shot("After (v\(run.draft?.version ?? 0))", unit.after, running: run.progress.running)
            }
            Text("What the code must do (one change per line)").uiFont(size: 10).foregroundColor(palette.textDim)
            TextEditor(text: Binding(get: { unit.changes.joined(separator: "\n") }, set: { run.setChanges($0, of: unit.id) }))
                .uiFont(size: 11)
                .scrollContentBackground(.hidden)
                .padding(4).background(RoundedRectangle(cornerRadius: 5).fill(palette.bgInput))
                .frame(height: 96)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).stroke(palette.border))
    }

    @ViewBuilder private func shot(_ title: String, _ shot: PrototypeHandoff.Shot, running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).uiFont(size: 10).foregroundColor(palette.textDim)
            switch shot {
            case .taken(let path):
                if let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 130)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.border))
                } else {
                    placeholder("The picture cannot be read")
                }
            case .pending: placeholder(running ? "Waiting…" : "Not taken")
            case .skipped(let reason): placeholder(reason.prefix(1).uppercased() + reason.dropFirst())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).uiFont(size: 10).foregroundColor(palette.textDim)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(RoundedRectangle(cornerRadius: 3).fill(palette.bgInput))
    }

    // MARK: Brief tab

    private var briefTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The same changes as text for an agent, with the pictures listed. Edit it, then start an agent with it or copy it.")
                .uiFont(size: 11).foregroundColor(palette.textDim)
            TextEditor(text: Binding(get: { brief }, set: { brief = $0; briefEdited = true }))
                .uiFont(size: 11, design: .monospaced)
                .scrollContentBackground(.hidden)
                .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(palette.bgInput))
                .frame(height: 420)
            HStack {
                Picker("Agent", selection: $agent) {
                    ForEach(TerminalProfile.allCases.filter { $0 != .shell }) { profile in Text(profile.title).tag(profile) }
                }
                .pickerStyle(.menu).fixedSize()
                Text("starts a new session in the AI panel").uiFont(size: 10).foregroundColor(palette.textDim)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure = run.createFailure {
                Text(failure).uiFont(size: 11).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Close") { onClose() }
                Spacer()
                Button(copied ? "Copied" : "Copy brief") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(currentBrief, forType: .string)
                    copied = true
                }
                .disabled(currentBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Send to \(agent.title)") {
                    let text = currentBrief
                    let terminal = workspaceManager.openAITerminal(agent)
                    workspaceManager.sendToAssistant(submit: true, to: terminal) { _ in text }
                    onClose()
                }
                .disabled(currentBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || run.progress.running)
                Button(run.creating ? "Creating…" : "Create feature") {
                    Task {
                        if let created = await run.create(into: workspaceManager.features) {
                            workspaceManager.featureWritten(created.slug, overview: created.overview)
                            onClose()
                        }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(run.progress.running || run.creating || (run.draft?.title.trimmingCharacters(in: .whitespaces).isEmpty ?? true))
                .help(run.progress.running ? "Wait for the screenshots and descriptions, or stop them" : "Write the feature, its requirements and the screenshots into the project")
            }
            .controlSize(.regular)
        }
    }

    /// The brief as shown: the person's edit, or the one made from the draft as it stands now.
    private var currentBrief: String { briefEdited ? brief : run.brief() }
}
