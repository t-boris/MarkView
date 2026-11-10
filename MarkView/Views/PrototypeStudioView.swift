import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The tab of Prototype Studio: the live prototype on the left, the review conversation on the right.
/// "Point" lets the reviewer click an element in the preview and say what to do with it.
struct PrototypeStudioView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: PrototypeSession
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var draft = ""
    @StateObject private var dictation = DictationController()
    @WindowStorage("prototypeChatWidth") private var chatWidth = 340.0
    /// What Point sends about the element: its HTML, or its HTML and a screenshot of it.
    @WindowStorage("prototypePickScreenshot") private var pickScreenshot = true
    @State private var dragStartWidth: Double?
    @FocusState private var draftFocused: Bool
    /// The "Assumptions & gaps" popover of the header (REQ-001: the reconstruction's limits are disclosed).
    @State private var showingDisclosure = false
    @State private var showingProblems = false
    /// "Copied" shown for a moment after the reference went to the pasteboard.
    @State private var referenceCopied = false
    /// The Components list of a code-mode prototype (REQ-007).
    @State private var showingComponents = false
    /// The sync status panel: which units match the code (REQ-014).
    @State private var showingSyncStatus = false
    @State private var confirmingClear = false
    /// The hand-off brief the person edits, and the agent it goes to (REQ-012).

    private static let widthRange: ClosedRange<Double> = 260...760

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                previewHeader
                Divider().background(palette.border)
                if session.hasSite {
                    PrototypePreview(session: session)
                } else {
                    placeholder
                }
            }
            resizeHandle
            conversation.frame(width: chatWidth)
        }
        .background(palette.bg)
        .onDisappear { dictation.cancel() }
        .onAppear { if !session.hasSite && !session.isBusy && session.manifest.version == 0 { session.generate() } }
        // A prototype saved before themes were recorded gets its record from the copied stylesheets when it is opened; one saved before
        // MarkView owned the page structure gets the structure (BUG-060).
        .task {
            await session.ensurePageStructure()
            await session.refreshThemes()
            await session.refreshSyncStatus()
        }
    }

    /// The divider between preview and conversation; dragging it left widens the conversation.
    private var resizeHandle: some View {
        Rectangle().fill(palette.border).frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? chatWidth
                    dragStartWidth = start
                    chatWidth = min(max(start - value.translation.width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                }
                .onEnded { _ in dragStartWidth = nil })
            .help("Drag to resize the conversation")
    }

    // MARK: Preview

    private var previewHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.angled").uiFont(size: 10).foregroundColor(palette.blue)
            Text(session.manifest.title).uiFont(size: 11, weight: .semibold).foregroundColor(palette.text).lineLimit(1)
            if session.manifest.version > 0 {
                Text("v\(session.manifest.version)\(session.manifest.approved ? " · approved" : "")")
                    .uiFont(size: 10).foregroundColor(session.manifest.approved ? palette.green : palette.textDim)
            }
            if session.manifest.mode == .code {
                // A reconstruction saved before UI Studio: history, never the live application (REQ-001, DEC-005).
                Text("Historical reconstruction").uiFont(size: 9, weight: .semibold).foregroundColor(palette.purple)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.purple.opacity(0.6)))
                    .help("A reconstruction of the code as it was ("
                          + (session.manifest.sources.isEmpty ? "the whole project" : session.manifest.sources.joined(separator: ", "))
                          + "), saved before UI Studio. It is not the current application: Open in UI Studio shows the real interface.")
            }
            let disclosed = session.manifest.assumptions.count + session.manifest.gaps.count
            if disclosed > 0 {
                Button { showingDisclosure.toggle() } label: {
                    Label("Assumptions & gaps (\(disclosed))", systemImage: "info.circle").uiFont(size: 10)
                }
                .buttonStyle(.plain).foregroundColor(palette.textDim)
                .popover(isPresented: $showingDisclosure, arrowEdge: .bottom) { disclosure }
                .help("What the assistant assumed, and what the original does that this prototype only simulates or lacks")
            }
            // The fix round could not repair everything (BUG-062): the prototype is not ready, whatever the version says.
            if !session.unresolvedProblems.isEmpty {
                Button { showingProblems.toggle() } label: {
                    Label("\(session.unresolvedProblems.count) not working", systemImage: "exclamationmark.triangle.fill")
                        .uiFont(size: 10, weight: .semibold)
                }
                .buttonStyle(.plain).foregroundColor(palette.red)
                .popover(isPresented: $showingProblems, arrowEdge: .bottom) { unresolvedList }
                .help("The check of the preview still finds problems that the fix round did not repair; click for the list")
            }
            if !session.runtimeErrors.isEmpty {
                Label("\(session.runtimeErrors.count)", systemImage: "exclamationmark.triangle.fill")
                    .uiFont(size: 10).foregroundColor(palette.orange)
                    .help(session.runtimeErrors.joined(separator: "\n"))
            }
            if let page = session.shownPage {
                Button { session.show(page: nil) } label: {
                    Label("Back to the screens", systemImage: "chevron.left")
                }
                .controlSize(.small).fixedSize()
                .help("The preview shows \(page) on its own; go back to the prototype's screens")
            }
            Spacer()
            if session.manifest.mode == .code { syncStatusButton }
            if let themes = session.manifest.themes, !themes.ids.isEmpty { themePicker(themes) }
            if !session.manifest.components.isEmpty {
                Button { showingComponents.toggle() } label: {
                    Label("Components (\(session.manifest.components.count))", systemImage: "square.on.square.dashed")
                }
                .controlSize(.small).fixedSize()
                .popover(isPresented: $showingComponents, arrowEdge: .bottom) { componentsList }
                .help("The source components this prototype reproduces: select one to outline its instances, open its source file or view it alone")
            }
            Toggle(isOn: $session.pickMode) {
                Label("Point", systemImage: "cursorarrow.click.2")
            }
            .toggleStyle(.button).controlSize(.small).disabled(!session.hasSite || session.isBusy)
            .help("Click an element in the preview to say what should change about it")
            if session.manifest.mode == .code {
                // Existing code is no longer reconstructed again: the current interface opens in UI Studio (DEC-005).
                Button { workspaceManager.openUIStudio() } label: {
                    Label("Sync from code", systemImage: "macwindow.and.cursorarrow")
                }
                .controlSize(.small).fixedSize()
                .help("Open the project's real interface in UI Studio. The reconstruction is not rebuilt; Hand off to code still carries its edits into the code.")
            }
            if session.manifest.mode == .code {
                Button { session.prepareHandoff() } label: {
                    Label(session.preparingHandoff ? "Comparing…" : "Hand off to code", systemImage: "arrow.uturn.right.circle")
                }
                .controlSize(.small).fixedSize().disabled(!session.canSyncFromCode || session.isBusy || session.preparingHandoff)
                .help("Turn what changed in the prototype since the last sync into a feature with before and after screenshots, or a brief for an agent; you read and edit the draft first and nothing is written until you create the feature")
                .sheet(isPresented: Binding(get: { session.handoff != nil }, set: { if !$0 { session.handoff = nil } })) { handoffSheet }
            }
            if session.manifest.version > 1 {
                Menu {
                    ForEach(session.manifest.history.reversed(), id: \.version) { entry in
                        Button("v\(entry.version): \(entry.instruction.isEmpty ? "Initial build" : String(entry.instruction.prefix(50)))") {
                            session.revert(to: entry.version)
                        }
                        .disabled(entry.version == session.manifest.version)
                    }
                } label: { Label("Versions", systemImage: "clock.arrow.circlepath") }
                .controlSize(.small).menuIndicator(.hidden).fixedSize().disabled(session.isBusy)
                .help("Go back to an earlier version")
            }
            Button { confirmingClear = true } label: {
                Label("Clear conversation", systemImage: "eraser")
            }
            .controlSize(.small).fixedSize().disabled(session.isBusy || session.messages.count <= 1)
            .help("Remove the conversation and its images; the prototype and every version stay")
            .confirmationDialog("Clear the conversation?", isPresented: $confirmingClear) {
                Button("Clear conversation", role: .destructive) { session.clearConversation() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The messages and the images sent with them are removed. The prototype, its versions and their history stay.")
            }
            Button { copyReference() } label: {
                Label(referenceCopied ? "Copied" : "Copy reference", systemImage: referenceCopied ? "checkmark" : "link")
            }
            .controlSize(.small).fixedSize()
            .help("Copy \(PrototypeReference.string(slug: session.slug)) — for an AI agent with access to this project; always resolves to the latest saved version")
            Button { workspaceManager.openHTMLInBrowser(session.siteIndex) } label: {
                Image(systemName: "globe")
            }
            .buttonStyle(.plain).foregroundColor(palette.textDim).disabled(!session.hasSite)
            .help("Open the prototype in a browser tab")
            Button { NSWorkspace.shared.activateFileViewerSelecting([session.siteFolder]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain).foregroundColor(palette.textDim)
            .help("Show the prototype files in Finder")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(palette.bgSidebar)
    }

    /// The assumptions the assistant made and the known gaps of a reconstruction, as recorded at generation.
    /// The problems the fix round left, and the way to run it again.
    private var unresolvedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Still not working").uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
            Text("The preview check found these after the fix round. The prototype is not ready until they are gone.")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(session.unresolvedProblems.enumerated()), id: \.offset) { _, item in
                        Text("• \(item)").uiFont(size: 11).foregroundColor(palette.text)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            Button {
                showingProblems = false
                session.fixProblems()
            } label: {
                Label("Fix again", systemImage: "wrench.and.screwdriver")
            }
            .controlSize(.small).disabled(session.isBusy)
            .help("Runs the fix round again: one run for each file the problems point to when there are more than three")
        }
        .padding(12)
        .frame(width: 460)
    }

    private var disclosure: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !session.manifest.assumptions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assumptions").uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
                        ForEach(session.manifest.assumptions, id: \.self) { item in
                            Text("• \(item)").uiFont(size: 11).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !session.manifest.gaps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Known gaps").uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
                        Text("What the original does that this prototype only simulates or lacks; recorded when it was generated.")
                            .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                        ForEach(session.manifest.gaps, id: \.self) { item in
                            Text("• \(item)").uiFont(size: 11).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(width: 380)
        .frame(maxHeight: 320)
    }

    // MARK: Sync status (REQ-014)

    private func stateColor(_ state: PrototypeBaseline.State) -> Color {
        switch state {
        case .inSync: return palette.green
        case .codeChanged: return palette.orange
        case .prototypeEdited: return palette.blue
        case .bothChanged: return Color.red
        case .unknown: return palette.textDim
        }
    }

    private func stateSymbol(_ state: PrototypeBaseline.State) -> String {
        switch state {
        case .inSync: return "checkmark.circle"
        case .codeChanged: return "arrow.triangle.2.circlepath"
        case .prototypeEdited: return "pencil.circle"
        case .bothChanged: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// The state as a word with a symbol, never a color alone.
    private func stateBadge(_ unit: PrototypeBaseline.UnitStatus) -> some View {
        Label(unit.state.title, systemImage: stateSymbol(unit.state))
            .uiFont(size: 9, weight: .semibold).foregroundColor(stateColor(unit.state))
            .help(unit.state.meaning + (unit.changedSources.isEmpty && unit.editedFiles.isEmpty ? "" : "\n" + unit.summary))
    }

    private var syncStatusButton: some View {
        let status = session.syncStatus
        let attention = (status?.counts[.codeChanged] ?? 0) + (status?.counts[.bothChanged] ?? 0)
        let label: String = {
            guard let status else { return session.checkingSync ? "Checking code…" : "Code match" }
            if !status.hasBaseline { return "No baseline" }
            if attention > 0 { return "\(attention) changed in code" }
            if (status.counts[.prototypeEdited] ?? 0) > 0 { return "Prototype edited" }
            return status.codeUnchanged ? "Matches the code" : "Check the code"
        }()
        return Button { showingSyncStatus.toggle() } label: {
            Label(label, systemImage: attention > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle")
        }
        .controlSize(.small).fixedSize()
        .popover(isPresented: $showingSyncStatus, arrowEdge: .bottom) { syncPanel }
        .help("Which screens and components of this prototype still match the code they were built from")
    }

    // MARK: Hand-off sheet (REQ-012, REQ-016)

    /// What the changes since the last sync are, as a feature to create or a brief for an agent. Studio writes nothing to the project
    /// until the person creates the feature; the agent works under the repository's own rules.
    private var handoffSheet: some View {
        Group {
            if let handoff = session.handoff {
                if let run = session.handoffRun {
                    PrototypeHandoffDraftView(run: run) { session.handoff = nil }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Hand off to code").uiFont(size: 15, weight: .semibold).foregroundColor(palette.text)
                        if !handoff.changes.hasBaseline {
                            Text(PrototypeBaseline.Status(baselineVersion: nil, units: [], unclaimed: [], added: []).summary)
                                .uiFont(size: 11).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Nothing to hand off: the prototype's files are as they were at the last sync (v\(handoff.changes.baselineVersion ?? 0)).")
                                .uiFont(size: 11).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack { Spacer(); Button("Close") { session.handoff = nil }.keyboardShortcut(.defaultAction) }
                    }
                    .padding(16)
                    .frame(width: 520)
                }
            }
        }
    }

    /// The units by state, with the files behind each state, and a button to check again (REQ-014).
    private var syncPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let status = session.syncStatus {
                    Text(status.summary).uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if status.hasBaseline {
                        Text("Last synced at v\(status.baselineVersion ?? 0). Checked just now, on this computer, without an assistant run.")
                            .uiFont(size: 10).foregroundColor(palette.textDim)
                    }
                    ForEach(PrototypeBaseline.State.allCases, id: \.self) { state in
                        let units = status.units.filter { $0.state == state }
                        if !units.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("\(state.title) (\(units.count))", systemImage: stateSymbol(state))
                                    .uiFont(size: 11, weight: .semibold).foregroundColor(stateColor(state))
                                Text(state.meaning).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                                ForEach(units, id: \.unit.id) { unit in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(unit.unit.name + (unit.unit.kind == .component ? " · component" : unit.unit.kind == .foundation ? " · shell" : ""))
                                            .uiFont(size: 11).foregroundColor(palette.text)
                                        if !unit.changedSources.isEmpty {
                                            Text("code: " + unit.changedSources.joined(separator: ", ")).uiFont(size: 10, design: .monospaced)
                                                .foregroundColor(palette.textDim).lineLimit(3)
                                        }
                                        if !unit.editedFiles.isEmpty {
                                            Text("prototype: " + unit.editedFiles.joined(separator: ", ")).uiFont(size: 10, design: .monospaced)
                                                .foregroundColor(palette.textDim).lineLimit(3)
                                        }
                                        if state == .unknown && status.hasBaseline {
                                            Text(unit.unit.sources.isEmpty ? "No source file is known for this unit." : "Some sources the plan named were not found.")
                                                .uiFont(size: 10).foregroundColor(palette.textDim)
                                        }
                                    }
                                    .padding(.leading, 8)
                                }
                            }
                        }
                    }
                    if !status.unclaimed.isEmpty {
                        Text("Changed files no unit lists (the prototype may depend on them): " + PrototypeBaseline.list(status.unclaimed, limit: 6))
                            .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                    if !status.added.isEmpty {
                        Text("New files since the last sync: " + PrototypeBaseline.list(status.added, limit: 6))
                            .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(session.checkingSync ? "Comparing the code with the last sync…" : "Not checked yet.").uiFont(size: 11).foregroundColor(palette.textDim)
                }
                HStack {
                    Button { Task { await session.refreshSyncStatus() } } label: { Label("Check again", systemImage: "arrow.clockwise") }
                        .controlSize(.small).disabled(session.checkingSync)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(width: 440)
        .frame(maxHeight: 460)
    }

    private static let defaultThemeTag = "\u{0}default"
    private static let originalLookTag = "\u{0}original"

    /// The theme picker of a prototype whose original has themes: Studio sets the root attribute of the preview itself, so it works
    /// whatever the generated screens do (REQ-002, DEC-001).
    private func themePicker(_ themes: PrototypeFiles.ThemeRecord) -> some View {
        let selection = Binding<String>(
            get: { themes.chosen == nil ? Self.defaultThemeTag : (themes.chosen!.isEmpty ? Self.originalLookTag : themes.chosen!) },
            set: { tag in
                session.chooseTheme(tag == Self.defaultThemeTag ? nil : (tag == Self.originalLookTag ? "" : tag))
            })
        return Menu {
            Picker("Theme", selection: selection) {
                Text(themes.defaultID.map { "Default (\($0))" } ?? "Default").tag(Self.defaultThemeTag)
                ForEach(themes.ids, id: \.self) { Text($0).tag($0) }
                Text("Original look").tag(Self.originalLookTag)
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Label("Theme: \(themes.effective ?? "original")", systemImage: "paintpalette")
        }
        .controlSize(.small).menuIndicator(.hidden).fixedSize()
        .help("The themes of the original interface, found in its stylesheets. The choice is applied to the preview and remembered with the prototype.")
    }

    /// The Components list (REQ-007, DEC-005): every source component the prototype reproduces, with the screens
    /// that use it. Selecting one outlines its instances in the preview; each offers its source file and its
    /// isolated view when the generation produced one.
    private var componentsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Source components the prototype reproduces. Select one to outline its instances in the preview; pointing at an element selects its component.")
                    .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                ForEach(session.manifest.components, id: \.path) { component in
                    componentRow(component)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(width: 400)
        .frame(maxHeight: 360)
    }

    private func componentRow(_ component: PrototypeFiles.Component) -> some View {
        let selected = session.selectedComponent == component.path
        let screens = component.screens.count
        let usage = screens == 0 ? "no screen names it" : "\(screens) screen\(screens == 1 ? "" : "s")"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(component.label).uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
                Text(usage).uiFont(size: 10).foregroundColor(palette.textDim)
                Spacer()
                if let state = session.syncStatus?.units.first(where: { $0.unit.id == component.path }) { stateBadge(state) }
                if selected, let count = session.highlightedInstances {
                    Text(count == 0 ? "not on this page" : "\(count) on this page").uiFont(size: 10).foregroundColor(palette.blue)
                }
            }
            Text(component.path).uiFont(size: 10, design: .monospaced).foregroundColor(palette.textDim).lineLimit(1)
                .help(component.screens.isEmpty ? component.path : "Used by: \(component.screens.joined(separator: ", "))")
            if selected { componentActions(component.path) }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? palette.selection.opacity(0.5) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { session.selectedComponent = selected ? nil : component.path }
    }

    /// "Open source" and "View alone" for a component path (the pick card and the Components list share them).
    @ViewBuilder
    private func componentActions(_ path: String) -> some View {
        HStack(spacing: 8) {
            Button("Open source") {
                if let url = session.sourceURL(of: path) { workspaceManager.openFile(url, line: nil) }
            }
            .disabled(session.sourceURL(of: path) == nil)
            .help(session.sourceURL(of: path) == nil ? "\(path) is not in the project any more" : "Open \(path) in an editor tab")
            if let page = session.component(at: path)?.page {
                Button(session.shownPage == page ? "Back to the screens" : "View alone") {
                    session.show(page: session.shownPage == page ? nil : page)
                    showingComponents = false
                }
                .help("Show only this component, rendered with simulated data (\(page))")
            }
        }
        .controlSize(.small)
    }

    /// Puts the prototype's reference (REQ-003, DEC-002: the prototype, never a version) on the pasteboard.
    private func copyReference() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PrototypeReference.string(slug: session.slug), forType: .string)
        referenceCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            referenceCopied = false
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Spacer()
            if session.isBusy {
                Text("The assistant plans the screens, builds the shell, then writes the screens side by side. Everything it does is listed here.")
                    .uiFont(size: 11).foregroundColor(palette.textDim)
                PrototypeProgressView(session: session, maxLogHeight: 260).frame(maxWidth: 480)
            } else {
                Image(systemName: "rectangle.on.rectangle.angled").uiFont(size: 28).foregroundColor(palette.textDim)
                Text("No prototype files yet.").uiFont(size: 12).foregroundColor(palette.textDim)
            }
            if !session.isBusy && session.manifest.version == 0 {
                Button("Build the prototype") { session.generate() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(session.messages) { message in
                            bubble(message).id(message.id)
                        }
                        if session.isBusy && session.hasSite {
                            PrototypeProgressView(session: session, maxLogHeight: 150).id("stage")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: session.messages.count) { _ in
                    if let last = session.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider().background(palette.border)
            composer
        }
        .background(palette.bgSidebar)
    }

    private func bubble(_ message: PrototypeSession.Message) -> some View {
        let color: Color = message.role == .user ? palette.bgActive : message.role == .error ? palette.red.opacity(0.18) : palette.bg
        return VStack(alignment: .leading, spacing: 6) {
            Text(message.text)
                .uiFont(size: 11).foregroundColor(palette.text)
                .textSelection(.enabled)
            if let request = message.retry {
                HStack(spacing: 8) {
                    Button("Retry") { session.retry(request) }.disabled(session.isBusy)
                    Button("Edit in the field") { session.edit(request) }
                }
                .controlSize(.small)
            }
            if !message.images.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(message.images.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 90, maxHeight: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(color))
    }

    /// What the next request is about (REQ-008): the whole prototype unless a screen or a component is chosen here, or an element is pointed at.
    private var targetRow: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Whole prototype") { session.target = nil; session.pick = nil }
                let screens = session.screenTargets
                if !screens.isEmpty {
                    Section("Screens") {
                        ForEach(screens, id: \.name) { item in Button(item.name) { session.target = item } }
                    }
                }
                let components = session.componentTargets
                if !components.isEmpty {
                    Section("Components") {
                        ForEach(components, id: \.detail) { item in Button(item.name + "  ·  " + (item.detail ?? "")) { session.target = item } }
                    }
                }
            } label: {
                Label(session.target.map { "\($0.kind): \($0.name)" } ?? (session.pick == nil ? "About: whole prototype" : "About: the pointed-at element"),
                      systemImage: "scope")
            }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            .disabled(!session.hasSite || session.isBusy)
            .help("Choose what your next request is about: the whole prototype, one screen or one source component. Point at an element in the preview to aim it at that element.")
            if let target = session.target {
                if let detail = target.detail {
                    Text(detail).uiFont(size: 10, design: .monospaced).foregroundColor(palette.textDim).lineLimit(1).help(detail)
                }
                Button { session.target = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundColor(palette.textDim).help("Aim the request at the whole prototype again")
            }
            Spacer()
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            targetRow
            if let pick = session.pick {
                HStack(spacing: 6) {
                    Image(systemName: "scope").foregroundColor(palette.blue)
                    Text(pick.text.isEmpty ? pick.selector : "“\(pick.text.prefix(40))” · \(pick.tag)")
                        .uiFont(size: 10).foregroundColor(palette.text).lineLimit(1)
                    Spacer()
                    Button { session.pick = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(palette.textDim)
                }
                .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(palette.selection.opacity(0.5)))
                if let component = pick.component, !component.isEmpty {
                    // The element or its nearest marked ancestor reproduces this source file (REQ-007).
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Component:").uiFont(size: 10).foregroundColor(palette.textDim)
                            Text(component).uiFont(size: 10, design: .monospaced).foregroundColor(palette.text).lineLimit(1)
                                .help(component)
                        }
                        componentActions(component)
                    }
                    .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(palette.bgInput.opacity(0.6)))
                } else if session.manifest.mode == .code {
                    Text("No source component is recorded for this element.").uiFont(size: 10).foregroundColor(palette.textDim)
                }
                Picker("", selection: $pickScreenshot) {
                    Text("HTML").tag(false)
                    Text("HTML + screenshot").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .help("What the assistant gets about the pointed-at element")
                if pickScreenshot, let shot = session.pickShot, let image = NSImage(data: shot) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            } else if session.pickMode {
                Text("Click an element in the preview.").uiFont(size: 10).foregroundColor(palette.blue)
            }
            ImageAttachmentStrip(attachments: $session.attachments)
            HStack(alignment: .top, spacing: 6) {
                TextEditor(text: $draft)
                    .uiFont(size: 12)
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .focused($draftFocused)
                    .padding(4).background(RoundedRectangle(cornerRadius: 5).fill(palette.bgInput))
                    .disabled(!session.hasSite || session.isBusy)
                    .takesImageAttachments($session.attachments, text: $draft)
                ImageAttachmentMenu(attachments: $session.attachments)
                    .disabled(!session.hasSite || session.isBusy)
                DictationButton(dictation: dictation) { transcript, window in
                    DictationInsertion.insert(transcript, window: window, fieldFocused: draftFocused, text: &draft)
                }
                .padding(.top, 2)
            }
            DictationStatusView(dictation: dictation) { DDESettingsWindow.show(workspace: workspaceManager) }
            HStack {
                Button {
                    session.approveAndExport()
                } label: { Label("Approve & export", systemImage: "checkmark.seal") }
                .controlSize(.small).disabled(!session.hasSite || session.isBusy)
                .help("Write SPEC.md and pack the prototype, the specification and the review history into a zip")
                if let archive = session.archive {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([archive]) } label: {
                        Label("Show zip", systemImage: "archivebox")
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Send") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.attachments.isEmpty)
                              || session.isBusy || !session.hasSite)
            }
        }
        .padding(10)
        .onChange(of: session.restoredDraft) { text in
            guard let text else { return }
            draft = text
            session.restoredDraft = nil
            draftFocused = true
        }
    }

    private func submit() {
        session.send(draft, withScreenshot: pickScreenshot)
        draft = ""
    }
}

// MARK: - Progress

/// What a running assistant is doing: the current step, the time so far and a list of its actions
/// (files read, searches, files being written), so a long run never looks like a hang.
struct PrototypeProgressView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: PrototypeSession
    var maxLogHeight: CGFloat

    @ViewBuilder
    private func screenIcon(_ state: PrototypeAI.ScreenState) -> some View {
        switch state {
        case .queued: Image(systemName: "circle").uiFont(size: 10).foregroundColor(palette.textDim)
        case .writing: ProgressView().controlSize(.mini).scaleEffect(0.7)
        case .done: Image(systemName: "checkmark.circle.fill").uiFont(size: 11).foregroundColor(palette.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").uiFont(size: 11).foregroundColor(palette.red)
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text((session.stage ?? "Working") + "…").uiFont(size: 11, weight: .medium).foregroundColor(palette.text).lineLimit(2)
                Spacer()
                if let started = session.runStarted {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let seconds = Int(context.date.timeIntervalSince(started))
                        Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                            .uiFont(size: 10, design: .monospaced).foregroundColor(palette.textDim)
                    }
                }
                Button("Stop") { session.cancel() }.controlSize(.small)
            }
            if let phase = session.phase {
                Text(phase).uiFont(size: 10, weight: .semibold).foregroundColor(palette.blue).fixedSize(horizontal: false, vertical: true)
            }
            if !session.screens.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(session.screens) { screen in
                        HStack(spacing: 6) {
                            screenIcon(screen.state).frame(width: 14)
                            Text(screen.name).uiFont(size: 11).foregroundColor(screen.state == .queued ? palette.textDim : palette.text)
                                .lineLimit(1)
                            if case .failed(let problem) = screen.state {
                                Text(problem).uiFont(size: 9).foregroundColor(palette.red).lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(palette.bgInput.opacity(0.6)))
            }
            if !session.activity.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(session.activity) { line in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(Self.clock.string(from: line.time))
                                        .uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim)
                                    Text(line.text).uiFont(size: 10).foregroundColor(palette.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(line.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: maxLogHeight)
                    .background(RoundedRectangle(cornerRadius: 5).fill(palette.bgInput.opacity(0.6)))
                    .onChange(of: session.activity.count) { _ in
                        if let last = session.activity.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

// MARK: - Preview web view

/// Shows `site/index.html`. A user script marks the element under the pointer while `pickMode` is on and
/// reports the click; another reports JavaScript errors so the assistant can fix them.
private struct PrototypePreview: NSViewRepresentable {
    @ObservedObject var session: PrototypeSession

    fileprivate static let pickScript = """
    (function () {
      var on = false, box = document.createElement('div');
      box.style.cssText = 'position:fixed;pointer-events:none;border:2px solid #0a84ff;background:rgba(10,132,255,.14);z-index:2147483647;display:none';
      function path(el) {
        var parts = [];
        while (el && el.nodeType === 1 && el !== document.body) {
          var s = el.tagName.toLowerCase();
          if (el.id) { parts.unshift(s + '#' + el.id); break; }
          var cls = (typeof el.className === 'string' && el.className.trim()) ? el.className.trim().split(/\\s+/).slice(0, 2).join('.') : '';
          if (cls) s += '.' + cls;
          var i = 1, sib = el;
          while ((sib = sib.previousElementSibling)) if (sib.tagName === el.tagName) i++;
          parts.unshift(s + ':nth-of-type(' + i + ')');
          el = el.parentElement;
        }
        return parts.join(' > ');
      }
      document.addEventListener('DOMContentLoaded', function () { document.documentElement.appendChild(box); });
      document.addEventListener('mouseover', function (e) {
        if (!on) return;
        var r = e.target.getBoundingClientRect();
        box.style.display = 'block'; box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
        box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
      }, true);
      ['click', 'mousedown', 'mouseup', 'submit'].forEach(function (type) {
        document.addEventListener(type, function (e) {
          if (!on) return;
          e.preventDefault(); e.stopPropagation();
          if (type !== 'click') return;
          var el = e.target, r = el.getBoundingClientRect();
          box.style.display = 'none';  // the highlight must not be in the screenshot
          var marked = el.closest ? el.closest('[data-mv-component]') : null;
          window.webkit.messageHandlers.mvPick.postMessage({
            selector: path(el), tag: el.tagName.toLowerCase(),
            text: (el.innerText || el.value || '').trim().slice(0, 200),
            html: el.outerHTML.slice(0, 800), screen: location.hash || '',
            component: marked ? (marked.getAttribute('data-mv-component') || '') : '',
            rect: { x: r.left, y: r.top, w: r.width, h: r.height }
          });
        }, true);
      });
      window.__mvPick = function (v) {
        on = v; if (!v) box.style.display = 'none';
        document.documentElement.style.cursor = v ? 'crosshair' : '';
      };
      // Outlines every element of one source component (the Components list); returns how many there are.
      var highlight = document.createElement('style');
      highlight.id = 'mv-highlight';
      window.__mvHighlight = function (component) {
        if (!highlight.parentNode) document.documentElement.appendChild(highlight);
        if (!component) { highlight.textContent = ''; return 0; }
        var selector = '[data-mv-component="' + (window.CSS && CSS.escape ? CSS.escape(component) : component.replace(/["\\\\]/g, '\\\\$&')) + '"]';
        highlight.textContent = selector + '{outline:2px solid #0a84ff !important;outline-offset:-2px;box-shadow:0 0 0 4px rgba(10,132,255,.18) !important}';
        return document.querySelectorAll(selector).length;
      };
      window.addEventListener('error', function (e) {
        window.webkit.messageHandlers.mvError.postMessage((e.message || 'Error') + (e.lineno ? ' (' + (e.filename || '').replace(/^[a-z]+:\\/\\/[^\\/]*\\//, '') + ':' + e.lineno + ')' : ''));
      });
      window.addEventListener('unhandledrejection', function (e) {
        window.webkit.messageHandlers.mvError.postMessage('Unhandled promise rejection: ' + (e.reason && e.reason.message || e.reason));
      });
    })();
    """

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.add(context.coordinator, name: "mvPick")
        controller.add(context.coordinator, name: "mvError")
        controller.add(context.coordinator, name: "mvAudit")
        context.coordinator.theme = Coordinator.ThemeKey(session.manifest.themes)
        context.coordinator.install(on: controller, pickScript: Self.pickScript)
        // One origin for all files of the site: errors in app.js and screens/*.js keep their text (BUG-047).
        configuration.setURLSchemeHandler(context.coordinator.files, forURLScheme: PrototypeSchemeHandler.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.load(session: session, keepingScreen: false)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.session = session
        coordinator.files.root = session.siteFolder
        if coordinator.loadedToken != session.reloadToken {
            coordinator.load(session: session, keepingScreen: true)
        }
        coordinator.applyPickMode(session.pickMode)
        coordinator.applyHighlight(session.selectedComponent)
        coordinator.set(theme: Coordinator.ThemeKey(session.manifest.themes))
        if coordinator.auditToken != session.auditToken {
            coordinator.auditToken = session.auditToken
            coordinator.runAudit()
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var session: PrototypeSession
        weak var webView: WKWebView?
        var loadedToken = -1
        /// The theme attribute the preview sets on every page, as last installed (themes feature, REQ-002).
        struct ThemeKey: Equatable {
            var attribute: String?
            var id: String?
            init(_ record: PrototypeFiles.ThemeRecord?) { attribute = record?.attribute; id = record?.effective }
        }
        var theme = ThemeKey(nil)

        /// The scripts every page of the preview starts with: the pick overlay, the screen audit and the theme attribute. They are
        /// installed again when the theme changes so the next page already paints with it.
        func install(on controller: WKUserContentController, pickScript: String) {
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(source: pickScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            controller.addUserScript(WKUserScript(source: PrototypeAudit.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            if let attribute = theme.attribute, let id = theme.id {
                controller.addUserScript(WKUserScript(source: PrototypeThemes.startScript(attribute: attribute, id: id),
                                                      injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
        }

        /// Applies a change of theme to the open page at once, without a reload, and to the pages that follow.
        func set(theme new: ThemeKey) {
            guard new != theme, let webView else { return }
            let old = theme
            theme = new
            install(on: webView.configuration.userContentController, pickScript: PrototypePreview.pickScript)
            if let previous = old.attribute, previous != new.attribute {
                webView.evaluateJavaScript(PrototypeThemes.applyScript(attribute: previous, id: nil))
            }
            if let attribute = new.attribute { webView.evaluateJavaScript(PrototypeThemes.applyScript(attribute: attribute, id: new.id)) }
        }

        /// The last audit request of the session this preview took up (BUG-053).
        var auditToken = 0
        /// An audit asked for while the page was still loading; it starts when the page finished.
        private var auditWaiting = false
        private var pickMode = false
        /// The component whose instances are outlined, as last sent to the page.
        private var highlighted: String?
        /// The page the last load showed, so a switch between the screens and an isolated view starts afresh.
        private var loadedPage: String?

        /// Serves the files of the session's `site/` folder to the page.
        let files: PrototypeSchemeHandler

        init(session: PrototypeSession) {
            self.session = session
            files = PrototypeSchemeHandler(root: session.siteFolder)
        }

        /// Loads index.html (or the isolated page the session shows); after a change the screen the reviewer was
        /// on stays selected.
        func load(session: PrototypeSession, keepingScreen: Bool) {
            guard let webView else { return }
            loadedToken = session.reloadToken
            let samePage = loadedPage == session.shownPage
            loadedPage = session.shownPage
            files.root = session.siteFolder
            let page = session.shownPage ?? "index.html"
            let reload = { (hash: String) in
                guard let url = PrototypeSchemeHandler.address(of: page, fragment: hash) else { return }
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            }
            if keepingScreen && samePage {
                webView.evaluateJavaScript("location.hash") { value, _ in reload(value as? String ?? "") }
            } else {
                reload("")
            }
        }

        /// Opens every screen of the loaded prototype in turn and sends what `PrototypeAudit.script` found back to the session.
        func runAudit() {
            guard let webView else { return }
            if webView.isLoading { auditWaiting = true; return }
            auditWaiting = false
            session.auditStarted()
            webView.evaluateJavaScript("""
            window.__mvAudit ? window.__mvAudit().then(
              function (report) { window.webkit.messageHandlers.mvAudit.postMessage(report); },
              function (error) { window.webkit.messageHandlers.mvAudit.postMessage({ error: String(error) }); }
            ) : window.webkit.messageHandlers.mvAudit.postMessage({ error: 'no audit' });
            """)
        }

        func applyPickMode(_ on: Bool) {
            pickMode = on
            webView?.evaluateJavaScript("window.__mvPick && window.__mvPick(\(on))")
        }

        /// Outlines the instances of `component` in the page (none with nil) and reports how many it holds.
        func applyHighlight(_ component: String?, force: Bool = false) {
            guard force || component != highlighted, let webView else { return }
            highlighted = component
            let value = component.map { path -> String in
                let data = (try? JSONSerialization.data(withJSONObject: [path])) ?? Data("[\"\"]".utf8)
                return String(decoding: data, as: UTF8.self) + "[0]"
            } ?? "null"
            webView.evaluateJavaScript("window.__mvHighlight ? window.__mvHighlight(\(value)) : null") { [weak self] result, _ in
                guard let self, self.highlighted == component else { return }
                self.session.highlightedInstances = component == nil ? nil : (result as? NSNumber)?.intValue
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyPickMode(pickMode)
            applyHighlight(highlighted, force: true)
            if auditWaiting { runAudit() }
        }

        /// A screenshot of the pointed-at element, kept with the pick; sent only if the reviewer chose HTML + screenshot.
        private func snapshot(of pick: PrototypeAI.Pick) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, let webView = self.webView else { return }
                let config = WKSnapshotConfiguration()
                config.rect = pick.rect.intersection(webView.bounds)
                guard config.rect.width > 1, config.rect.height > 1 else { return }
                config.snapshotWidth = NSNumber(value: Double(min(config.rect.width * 2, 1600)))
                webView.takeSnapshot(with: config) { image, _ in
                    guard let image, let png = ImageAttachments.pngData(from: image) else { return }
                    Task { @MainActor in
                        if self.session.pick?.selector == pick.selector { self.session.pickShot = png }
                    }
                }
            }
        }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let name = message.name, body = message.body
            Task { @MainActor in
                if name == "mvError", let text = body as? String {
                    session.report(error: String(text.prefix(300)))
                } else if name == "mvAudit" {
                    session.finishAudit(PrototypeAudit.report(from: body))
                } else if name == "mvPick", let info = body as? [String: Any] {
                    func field(_ key: String) -> String { info[key] as? String ?? "" }
                    let box = info["rect"] as? [String: Any] ?? [:]
                    func number(_ key: String) -> CGFloat { CGFloat((box[key] as? NSNumber)?.doubleValue ?? 0) }
                    let rect = CGRect(x: number("x"), y: number("y"), width: number("w"), height: number("h"))
                    let component = PrototypeFiles.componentPath(field("component"))
                    let pick = PrototypeAI.Pick(selector: field("selector"), tag: field("tag"), text: field("text"),
                                                html: field("html"), screen: field("screen"), rect: rect, component: component)
                    session.pick = pick
                    session.pickMode = false
                    snapshot(of: pick)
                }
            }
        }
    }
}
