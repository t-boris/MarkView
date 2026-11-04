import AppKit
import SwiftUI
import WebKit

/// The tab of UI Studio (feature "MarkView UI Studio"): the project's real interface on the left, run by its development
/// server with simulated dependencies; the inspector on the right holds the selected element with questions and changes,
/// the history of changes, the scenarios, the environment and its policies, and the captures and feature export.
struct UIStudioView: View {
    @ObservedObject var session: StudioSession
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @AppStorage("uiStudioInspectorWidth") private var inspectorWidth = 380.0
    @State private var dragStartWidth: Double?
    @State private var panel: Panel = .element
    @State private var draft = ""
    @FocusState private var draftFocused: Bool
    @StateObject private var dictation = DictationController()
    @AppStorage("uiStudioSelectionExpanded") private var selectionExpanded = true
    @State private var showingTrust = false
    @State private var effectiveScale = 1.0
    @State private var showLivePage = false

    enum Panel: String, CaseIterable, Identifiable {
        case element = "Element", history = "History", scenarios = "Scenarios", environment = "Environment", evidence = "Evidence"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .element: return "cursorarrow.rays"
            case .history: return "clock.arrow.circlepath"
            case .scenarios: return "square.stack.3d.up"
            case .environment: return "network"
            case .evidence: return "photo.on.rectangle"
            }
        }
    }

    private static let widthRange: ClosedRange<Double> = 300...720

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(VSDark.border)
            banners
            HStack(spacing: 0) {
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                resizeHandle
                inspector.frame(width: inspectorWidth)
            }
        }
        .background(VSDark.bg)
    }

    private var resizeHandle: some View {
        Rectangle().fill(VSDark.border).frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? inspectorWidth
                    dragStartWidth = start
                    inspectorWidth = min(max(start - value.translation.width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                }
                .onEnded { _ in dragStartWidth = nil })
            .help("Drag to resize the inspector")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow.and.cursorarrow").uiFont(size: 11).foregroundColor(VSDark.blue)
            Text("UI Studio").uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text)
            if session.targets.count > 1 {
                Menu(session.target?.label ?? "Choose application") {
                    ForEach(session.targets, id: \.folder) { target in
                        Button(target.label) { session.start(target) }
                    }
                }
                .controlSize(.small).fixedSize()
                .help("The web application of this project the session runs")
            } else if let target = session.target {
                Text(target.label).uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(1)
            }
            stateBadge
            if session.appURL != nil {
                Text(session.route).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim).lineLimit(1)
                    .truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
                    .help("The page's route")
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { session.mode }, set: { session.setMode($0) })) {
                Text("Interact").tag(StudioSession.Mode.interact)
                Text("Select").tag(StudioSession.Mode.select)
                Text("Record").tag(StudioSession.Mode.record)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            .disabled(session.appURL == nil || session.busy != nil)
            .help("Interact uses the application. Select picks an element without running its action. Record writes the steps that rebuild the current state.")
            if session.mode == .record {
                // What recording has written so far, so it is visible without opening the Scenarios panel (BUG-071).
                HStack(spacing: 4) {
                    Circle().fill(VSDark.red).frame(width: 6, height: 6)
                    Text("\(session.recordedSteps.count) step\(session.recordedSteps.count == 1 ? "" : "s")")
                    if let last = session.recordedSteps.last {
                        Text("· \(last.action.rawValue) \(last.selector ?? "")").foregroundColor(VSDark.textDim)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                    }
                }
                .uiFont(size: 10)
                .help("Recording: clicks, typing and Enter become steps. Stop with Interact, then save the scenario in the Scenarios panel.")
            }
            scenarioMenu
            viewportMenu
            zoomMenu
            Button { session.setTheme(session.scenario.theme == .dark ? .light : .dark) } label: {
                Image(systemName: session.scenario.theme == .dark ? "moon.fill" : "sun.max")
            }
            .buttonStyle(.plain).foregroundColor(VSDark.textDim)
            .help("Color scheme of the page: \(session.scenario.theme.rawValue)")
            Button { session.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                .controlSize(.small).fixedSize().disabled(session.appURL == nil || session.busy != nil)
                .help("Back to the scenario's baseline: its data, an empty browser storage, a fresh page and its restoration steps")
            Button { session.captureNow() } label: { Image(systemName: "camera") }
                .buttonStyle(.plain).foregroundColor(VSDark.textDim).disabled(session.appURL == nil || session.busy != nil)
                .help("Capture the preview, linked to the code revision, the scenario and the rendering conditions")
            Button { showingTrust.toggle() } label: { Image(systemName: "shield.lefthalf.filled") }
                .buttonStyle(.plain).foregroundColor(VSDark.orange)
                .popover(isPresented: $showingTrust, arrowEdge: .bottom) { trustPanel.frame(width: 420).padding(14) }
                .help("What runs, with which permissions, and where the application and the assistant may connect")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(VSDark.bgSidebar)
    }

    private var stateBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(stateColor).frame(width: 7, height: 7)
            Text(session.state.title).uiFont(size: 10, weight: .semibold).foregroundColor(stateColor)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(stateColor.opacity(0.5)))
        .help(session.stateDetail)
    }

    private var stateColor: Color {
        switch session.state {
        case .ready: return VSDark.green
        case .degraded: return VSDark.orange
        case .failed: return VSDark.red
        case .stopped: return VSDark.textDim
        case .analyzing, .preparing, .starting: return VSDark.blue
        }
    }

    private var scenarioMenu: some View {
        Menu {
            Section("Built in") {
                ForEach(session.presets) { preset in
                    Button(preset.name) { session.activate(preset) }
                }
            }
            if !session.savedScenarios.isEmpty {
                Section("Saved") {
                    ForEach(session.savedScenarios) { saved in
                        let problems = session.problems(of: saved)
                        Button(saved.name + (problems.isEmpty ? "" : " (needs update)")) { session.activate(saved) }
                    }
                }
            }
            Divider()
            Button("Save or Record Scenario…") { panel = .scenarios }
        } label: {
            Label(session.scenario.name, systemImage: "square.stack.3d.up")
        }
        .controlSize(.small).fixedSize().disabled(session.appURL == nil || session.busy != nil)
        .help("The scenario: baseline data, role, route, viewport, theme, locale, clock and restoration steps")
    }

    private var viewportMenu: some View {
        Menu {
            ForEach(StudioViewport.presets, id: \.name) { preset in
                Button("\(preset.name) — \(preset.viewport.width)×\(preset.viewport.height)") { session.setViewport(preset.viewport) }
            }
        } label: {
            Text("\(session.viewport.width)×\(session.viewport.height)").uiFont(size: 10, design: .monospaced)
        }
        .controlSize(.small).fixedSize()
        .help("The application's viewport (its window size). Zoom never changes it.")
    }

    private var zoomMenu: some View {
        Menu {
            Button("Fit") { session.zoom = nil }
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                Button("\(Int(value * 100)) %") { session.zoom = value }
            }
        } label: {
            Text(session.zoom == nil ? "Fit \(Int((effectiveScale * 100).rounded())) %" : "\(Int((effectiveScale * 100).rounded())) %")
                .uiFont(size: 10)
        }
        .controlSize(.small).fixedSize()
        .help("Zoom of the preview only: the page keeps its viewport, media queries and layout")
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        if let notice = session.notice {
            banner(notice, symbol: "info.circle", color: VSDark.blue) { session.notice = nil }
        }
        if session.state == .degraded, !session.limitations.isEmpty {
            banner("Degraded: " + session.limitations.joined(separator: " · "), symbol: "exclamationmark.triangle", color: VSDark.orange) {
                panel = .environment
            }
        }
        if let busy = session.busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(busy + (session.busyDetail.isEmpty ? "" : " — " + session.busyDetail)).uiFont(size: 10).foregroundColor(VSDark.text).lineLimit(1)
                Spacer()
                Button("Cancel") { session.cancelWork() }.controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(VSDark.bgBanner)
        }
    }

    private func banner(_ text: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).uiFont(size: 10).foregroundColor(color)
            Text(text).uiFont(size: 10).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer()
            Button(action: action) { Image(systemName: "xmark").uiFont(size: 9) }.buttonStyle(.plain).foregroundColor(VSDark.textDim)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(VSDark.bgBanner)
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        if session.appURL == nil {
            startingPlaceholder
        } else {
            ZStack(alignment: .top) {
                UIStudioWebHost(session: session) { scale in effectiveScale = scale }
                if let error = session.buildError, let stale = session.stalePreview, !showLivePage {
                    stalePreview(stale, error: error)
                }
            }
        }
    }

    /// The last working picture while the change does not build (EDIT-08, AC-15).
    private func stalePreview(_ capture: StudioCapture, error: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundColor(VSDark.red)
                Text("Stale preview: the application does not build after the change. This is the last working capture.")
                    .uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text)
                Spacer()
                Button("Show the error page") { showLivePage = true }.controlSize(.small)
            }
            .padding(8).background(VSDark.bgBanner)
            Text(error).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.red).lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(VSDark.bgSidebar).textSelection(.enabled)
            StudioCaptureImage(url: session.url(of: capture)).opacity(0.55).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VSDark.bg)
        .onDisappear { showLivePage = false }
    }

    private var startingPlaceholder: some View {
        VStack(spacing: 12) {
            if [.analyzing, .starting, .preparing].contains(session.state) { ProgressView() }
            Text(session.state.title).uiFont(size: 14, weight: .semibold).foregroundColor(VSDark.text)
            Text(session.stateDetail).uiFont(size: 11).foregroundColor(VSDark.textDim).multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            if session.target == nil, session.targets.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.targets, id: \.folder) { target in
                        Button { session.start(target) } label: {
                            Label("\(target.label) — \(target.command)", systemImage: target.isElectron ? "macwindow" : "globe")
                        }
                        .buttonStyle(.plain).foregroundColor(VSDark.blue)
                    }
                }
            }
            if session.state == .failed {
                Button("Try again") { session.start(session.target) }
            }
            if !session.serverLog.isEmpty {
                ScrollView {
                    Text(session.serverLog).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxWidth: 700, maxHeight: 240).padding(8).background(VSDark.bgSidebar)
            }
            Text("Project processes run with your permissions.").uiFont(size: 10).foregroundColor(VSDark.orange)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Panel.allCases) { item in
                    Button { panel = item } label: {
                        Image(systemName: item.symbol).uiFont(size: 11)
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(panel == item ? VSDark.bgActive : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain).foregroundColor(panel == item ? VSDark.text : VSDark.textDim)
                    .help(item.rawValue)
                }
            }
            .padding(6)
            Text(panel.rawValue.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            Divider().background(VSDark.border)
            switch panel {
            case .element: elementPanel
            case .history: UIStudioHistoryPanel(session: session) { panel = .evidence }
            case .scenarios: UIStudioScenariosPanel(session: session)
            case .environment: UIStudioEnvironmentPanel(session: session, queue: session.preparation)
            case .evidence: UIStudioEvidencePanel(session: session)
            }
        }
        .background(VSDark.bgSidebar)
    }

    // MARK: Element

    /// The selected element above the conversation about it: the earlier turns oldest first, the turn the assistant is
    /// answering, and the composer. Nothing of the conversation disappears while the assistant works.
    private var elementPanel: some View {
        VStack(spacing: 0) {
            selectionHeader
            Divider().background(VSDark.border)
            thread
            Divider().background(VSDark.border)
            composer
        }
    }

    /// The selection, folded to its tag on request so the conversation keeps the room.
    @ViewBuilder private var selectionHeader: some View {
        if let selection = session.selection {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button { selectionExpanded.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: selectionExpanded ? "chevron.down" : "chevron.right").uiFont(size: 9)
                                .foregroundColor(VSDark.textDim).frame(width: 10)
                            Text(selection.tag).uiFont(size: 12, weight: .semibold, design: .monospaced).foregroundColor(VSDark.text)
                                .lineLimit(selectionExpanded ? 2 : 1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(selectionExpanded ? "Hide the element's details" : "Show the element's details: source, picture, route, revision")
                    HStack(spacing: 8) {
                        Button { session.selectParent() } label: { Image(systemName: "arrow.up.left") }.help("Select the parent element")
                        Button { session.selectChild() } label: { Image(systemName: "arrow.down.right") }.help("Select a child element")
                        Button { session.clearSelection() } label: { Image(systemName: "xmark.circle") }.help("Clear the selection")
                    }
                    .buttonStyle(.plain).foregroundColor(VSDark.textDim).uiFont(size: 11).disabled(session.busy != nil)
                }
                if selectionExpanded { selectionDetails(selection) }
            }
            .padding(10)
        } else {
            Text(session.mode == .select
                 ? "Click an element in the preview. In Select mode a click selects; it does not run the element's action. Escape ends selecting."
                 : "Choose Select in the toolbar, then click an element to ask about it or change it.")
                .uiFont(size: 11).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }

    private static let threadEnd = "thread-end"

    /// The conversation: every question and change of the session, oldest at the top, then the request being answered.
    /// It follows the newest turn.
    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.history.isEmpty, session.pendingTurn == nil {
                        Text("Questions and changes appear here as a conversation. The assistant remembers the last turns, so a follow-up can refer to them.")
                            .uiFont(size: 11).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(session.history) { operation in
                        turn(operation)
                    }
                    if let pending = session.pendingTurn {
                        pendingTurn(pending)
                    }
                    Color.clear.frame(height: 1).id(Self.threadEnd)
                }
                .padding(10)
            }
            .onAppear { scrollToEnd(proxy, animated: false) }
            .onChange(of: threadPosition) { _ in scrollToEnd(proxy, animated: true) }
        }
    }

    /// Changes when a request is sent, and when a turn is added, answered or replaced.
    private var threadPosition: String {
        let last = session.history.last
        return "\(session.history.count)|\(last?.id ?? "")|\(last?.status.rawValue ?? "")|\(session.pendingTurn?.started.timeIntervalSince1970 ?? 0)"
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        // After the new rows are laid out.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.threadEnd, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.threadEnd, anchor: .bottom)
            }
        }
    }

    private func turn(_ operation: StudioOperation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            UIStudioOperationRow(session: session, operation: operation, compact: true) { panel = .evidence }
            if operation.status == .clarification { clarification(operation) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VSDark.bg).cornerRadius(6)
    }

    /// The request the assistant is working on: what was asked, about which element, what the assistant is doing, Stop.
    private func pendingTurn(_ turn: StudioSession.PendingTurn) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: turn.kind == .question ? "questionmark.bubble" : "wand.and.stars").uiFont(size: 10)
                    .foregroundColor(VSDark.blue)
                Text(turn.request).uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            if !turn.element.isEmpty {
                Text(turn.element).uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                TimelineView(.periodic(from: turn.started, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(turn.started)))
                    Text((session.busyDetail.isEmpty ? (session.busy ?? "Working") : session.busyDetail)
                         + String(format: " · %d:%02d", seconds / 60, seconds % 60))
                        .uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button("Stop") { session.cancelWork() }.controlSize(.small).help("Stop the assistant")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VSDark.bg).cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(VSDark.blue.opacity(0.4)))
    }

    private func selectionDetails(_ selection: StudioSelectionContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = selection.imagePath {
                StudioCaptureImage(url: URL(fileURLWithPath: image)).frame(maxHeight: 120)
            }
            FactRows(rows: selectionRows(selection))
            if let path = selection.sourcePath {
                Button {
                    workspaceManager.openFile(session.root.appendingPathComponent(path), line: selection.line)
                } label: {
                    Label("Open \(path)\(selection.line.map { ":\($0)" } ?? "")", systemImage: "doc.text")
                }
                .buttonStyle(.plain).foregroundColor(VSDark.blue).uiFont(size: 10)
            }
            if let boundary = selection.boundary {
                Text(boundary).uiFont(size: 10).foregroundColor(VSDark.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let snippet = selection.snippet {
                DisclosureGroup("Source around the element") {
                    ScrollView(.horizontal) {
                        Text(snippet).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.text).textSelection(.enabled)
                    }
                }
                .uiFont(size: 10).foregroundColor(VSDark.textDim)
            }
        }
    }

    private func selectionRows(_ selection: StudioSelectionContext) -> [(String, String)] {
        var rows: [(String, String)] = [("Source", selection.mappingDescription)]
        if let component = selection.component { rows.append(("Component", component)) }
        if selection.instanceCount > 1 { rows.append(("Instance", "\(selection.instanceIndex + 1) of \(selection.instanceCount)")) }
        rows.append(("Route", selection.route))
        rows.append(("Scenario", session.scenario.name))
        if let revision = selection.revision { rows.append(("Revision", revision.label)) }
        if selection.revalidated { rows.append(("Checked", "after the last change")) }
        return rows
    }

    /// The assistant's question in a clarification turn (its scope is on the turn's row), with the options as answers.
    private func clarification(_ operation: StudioOperation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The assistant asks before changing anything", systemImage: "questionmark.bubble").uiFont(size: 10, weight: .semibold)
                .foregroundColor(VSDark.yellow)
            Text(operation.question ?? "").uiFont(size: 11).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(operation.options, id: \.self) { option in
                Button(option) { session.answerClarification(operation, choice: option) }
                    .controlSize(.small).disabled(session.busy != nil)
            }
            if session.history.last(where: { $0.status == .clarification })?.id == operation.id {
                Text("Or type the answer below and press Change.").uiFont(size: 10).foregroundColor(VSDark.textDim)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft)
                .uiFont(size: 12).frame(height: 70)
                .scrollContentBackground(.hidden).background(VSDark.bgInput).cornerRadius(4)
                .focused($draftFocused)
            DictationStatusView(dictation: dictation) { DDESettingsWindow.show(workspace: workspaceManager) }
            HStack {
                Text(session.selection == nil ? "Select an element first." : "Ask reads only. Change edits the project's source files.")
                    .uiFont(size: 9).foregroundColor(VSDark.textDim)
                Spacer()
                DictationButton(dictation: dictation) { transcript, window in
                    DictationInsertion.insert(transcript, window: window, fieldFocused: draftFocused, text: &draft)
                }
                Button("Ask") {
                    session.ask(draft)
                    draft = ""
                }
                .disabled(!canSend).help("A question about the selected element; nothing in the project changes")
                Button("Change") {
                    if let pending = session.history.last(where: { $0.status == .clarification }) {
                        session.answerClarification(pending, choice: draft)
                    } else {
                        session.change(draft)
                    }
                    draft = ""
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSend)
                .help("Change the interface: the assistant names the scope, edits the sources, and MarkView verifies the rebuilt application (⌘↩)")
            }
            .controlSize(.small)
        }
        .padding(8)
        .onDisappear { dictation.cancel() }
    }

    private var canSend: Bool {
        session.selection != nil && session.busy == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Trust

    private var trustPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trusted local projects only").uiFont(size: 13, weight: .semibold).foregroundColor(VSDark.text)
            Text("Project processes run with your permissions. The development server, its build and the application's code are the "
                 + "project's own and are not isolated from your Mac. Open only projects you trust.")
                .uiFont(size: 11).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true)
            Text("Requests are intercepted inside the page so that they reach the simulation. This keeps the application away from "
                 + "real services; it is not operating-system isolation and does not make a malicious project safe.")
                .uiFont(size: 11).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Application connections").uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text)
            Text("The page reaches its development server (\(session.appURL?.absoluteString ?? "not running")), local data: and blob: "
                 + "resources and the addresses you allow in Environment. Everything else is blocked; an unknown request is answered by "
                 + "the simulation or ends in a controlled error.")
                .uiFont(size: 11).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
            Text("Model connections").uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text)
            Text(StudioModelPolicy.description).uiFont(size: 11).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
            Text("The simulated user is a test account with test credentials.").uiFont(size: 11).foregroundColor(VSDark.textDim)
        }
    }
}

// MARK: - Web host

/// Puts the session's web view into the zoom container (`StudioPreviewScrollView`).
struct UIStudioWebHost: NSViewRepresentable {
    @ObservedObject var session: StudioSession
    var onScale: (Double) -> Void

    func makeNSView(context: Context) -> StudioPreviewScrollView {
        let view = StudioPreviewScrollView(webView: session.webView)
        view.onScale = { scale in DispatchQueue.main.async { onScale(scale) } }
        update(view)
        return view
    }

    func updateNSView(_ view: StudioPreviewScrollView, context: Context) {
        view.onScale = { scale in DispatchQueue.main.async { onScale(scale) } }
        update(view)
    }

    private func update(_ view: StudioPreviewScrollView) {
        view.attach(session.webView)
        view.viewport = CGSize(width: session.viewport.width, height: session.viewport.height)
        view.zoom = session.zoom
    }
}

/// A capture or selection picture, read off the main thread.
struct StudioCaptureImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(VSDark.bg).overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: url) {
            let file = url
            let loaded = await Task.detached { StudioImageDiff.load(file) }.value
            image = loaded.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }
}

// MARK: - History

struct UIStudioHistoryPanel: View {
    @ObservedObject var session: StudioSession
    var showEvidence: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if session.history.isEmpty {
                    Text("Questions and changes appear here with their verification. Each change can be undone on its own.")
                        .uiFont(size: 11).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(session.history.reversed()) { operation in
                    UIStudioOperationRow(session: session, operation: operation, compact: false, showEvidence: showEvidence)
                    Divider().background(VSDark.border)
                }
            }
            .padding(10)
        }
    }
}

struct UIStudioOperationRow: View {
    @ObservedObject var session: StudioSession
    let operation: StudioOperation
    /// The form of a turn in the element panel's conversation: the whole request and answer, and checks that all passed
    /// folded into one line.
    let compact: Bool
    var showEvidence: () -> Void
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var showingPatch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: operation.kind == .question ? "questionmark.bubble" : "wand.and.stars").uiFont(size: 10)
                    .foregroundColor(VSDark.blue)
                Text(operation.request).uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text).lineLimit(compact ? nil : 4)
                    .fixedSize(horizontal: false, vertical: compact)
                Spacer()
                Text(operation.status.rawValue).uiFont(size: 9, weight: .semibold).foregroundColor(statusColor)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(statusColor.opacity(0.6)))
            }
            if !operation.selection.isEmpty {
                Text(operation.selection).uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim).lineLimit(1)
            }
            if operation.kind == .edit, operation.scope != .unknown {
                Text("Scope: \(operation.scope.title)" + (operation.scopeNote.isEmpty ? "" : " — \(operation.scopeNote)"))
                    .uiFont(size: 10).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
            }
            let text = operation.answer.isEmpty ? operation.summary : operation.answer
            if !text.isEmpty {
                Text(text).uiFont(size: 11).foregroundColor(VSDark.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let conflict = operation.conflict {
                Text(conflict).uiFont(size: 10).foregroundColor(VSDark.red).fixedSize(horizontal: false, vertical: true)
                if session.undoConflicts[operation.id] != nil {
                    Button("Write the conflict markers into the files") { session.resolveUndoConflictInEditor(operation.id) }
                        .controlSize(.small)
                        .help("Writes both versions with <<<<<<< markers into the files and opens them, so you resolve the overlap yourself")
                }
            }
            if compact, !operation.checks.isEmpty, operation.checks.allSatisfy(\.passed) {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(VSDark.green).uiFont(size: 10)
                    Text(operation.checks.count == 1 ? operation.checks[0].name : "\(operation.checks.count) checks passed")
                        .uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(1)
                }
                .help(operation.checks.map(\.name).joined(separator: "\n"))
            } else if !operation.checks.isEmpty {
                ForEach(operation.checks, id: \.name) { check in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(check.passed ? VSDark.green : VSDark.red).uiFont(size: 10)
                        Text(check.name + (check.detail.isEmpty ? "" : ": " + check.detail)).uiFont(size: 10)
                            .foregroundColor(VSDark.textDim).lineLimit(3)
                    }
                }
            }
            if !operation.files.isEmpty {
                ForEach(operation.files, id: \.path) { file in
                    Button { workspaceManager.openFile(session.root.appendingPathComponent(file.path)) } label: {
                        Label(file.path, systemImage: file.before == nil ? "doc.badge.plus" : "doc.text").uiFont(size: 10)
                    }
                    .buttonStyle(.plain).foregroundColor(VSDark.blue)
                }
            }
            if operation.kind == .edit {
                HStack(spacing: 6) {
                    if operation.status == .applied {
                        Button("Keep") { session.keep(operation.id) }.help("Keep the change; it can still be undone later")
                    }
                    if [.applied, .kept, .conflict].contains(operation.status), !operation.files.isEmpty {
                        Button("Undo") { session.undo(operation.id) }
                            .help("Remove this change only; later independent changes stay, overlapping ones are shown as a conflict")
                    }
                    if !operation.patch.isEmpty {
                        Button("Diff") { showingPatch.toggle() }
                            .popover(isPresented: $showingPatch, arrowEdge: .leading) {
                                ScrollView([.vertical, .horizontal]) {
                                    Text(operation.patch).uiFont(size: 10, design: .monospaced).textSelection(.enabled).padding(10)
                                }
                                .frame(width: 620, height: 420)
                            }
                    }
                    if let before = operation.beforeCapture, let after = operation.afterCapture {
                        Button("Compare") {
                            session.compare(before, after)
                            showEvidence()
                        }
                        .help("Before and after, side by side and as a difference")
                    }
                }
                .controlSize(.small).disabled(session.busy != nil)
            }
        }
    }

    private var statusColor: Color {
        switch operation.status {
        case .applied, .kept, .answered: return VSDark.green
        case .undone: return VSDark.textDim
        case .conflict, .failed: return VSDark.red
        case .clarification: return VSDark.yellow
        }
    }
}

// MARK: - Scenarios

struct UIStudioScenariosPanel: View {
    @ObservedObject var session: StudioSession
    @State private var name = ""
    @State private var kind: StudioScenario.Kind = .custom
    @State private var locale = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FactRows(rows: [("Scenario", session.scenario.name), ("Kind", session.scenario.kind.title),
                                ("Revision", String(session.scenario.revision)), ("Route", session.scenario.route),
                                ("Role", session.scenario.role.name), ("Viewport", "\(session.viewport.width)×\(session.viewport.height)"),
                                ("Theme", session.scenario.theme.rawValue), ("Locale", session.scenario.locale),
                                ("Time zone", session.scenario.timeZone ?? TimeZone.current.identifier),
                                ("Clock", ISO8601DateFormatter().string(from: session.scenario.testTime)),
                                ("Random seed", String(session.scenario.seed)),
                                ("Steps", String(session.scenario.steps.count))])
                HStack {
                    TextField("Locale, e.g. de-DE", text: $locale).textFieldStyle(.roundedBorder).uiFont(size: 11)
                    Button("Apply") { session.setLocale(locale) }.disabled(locale.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)

                section("Record restoration steps")
                Text("Recording starts from the scenario's baseline. Use the application; clicks, typing and Enter become steps that "
                     + "rebuild this state after every Reset. Typed passwords are replaced by a test value.")
                    .uiFont(size: 10).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if session.mode == .record {
                        Button("Stop recording") { session.setMode(.interact) }
                        Text("\(session.recordedSteps.count) step\(session.recordedSteps.count == 1 ? "" : "s")").uiFont(size: 10)
                    } else {
                        Button("Record") { session.setMode(.record) }.disabled(session.appURL == nil || session.busy != nil)
                        if !session.recordedSteps.isEmpty { Text("\(session.recordedSteps.count) recorded").uiFont(size: 10) }
                    }
                }
                .controlSize(.small)
                ForEach(Array(session.recordedSteps.enumerated()), id: \.offset) { _, step in
                    Text("\(step.action.rawValue) \(step.selector ?? "") \(step.text ?? "")").uiFont(size: 9, design: .monospaced)
                        .foregroundColor(VSDark.textDim).lineLimit(1)
                }

                section("Save the current scenario")
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).uiFont(size: 11)
                Picker("Kind", selection: $kind) {
                    ForEach(StudioScenario.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .uiFont(size: 11)
                Button("Save in .markview/studio/scenarios") {
                    session.saveScenario(name: name, kind: kind)
                    name = ""
                }
                .controlSize(.small).disabled(session.busy != nil)

                section("Built in")
                ForEach(session.presets) { preset in
                    scenarioRow(preset, problems: [])
                }
                if !session.savedScenarios.isEmpty {
                    section("Saved")
                    ForEach(session.savedScenarios) { saved in
                        scenarioRow(saved, problems: session.problems(of: saved))
                    }
                }
            }
            .padding(10)
        }
        .onAppear { locale = session.scenario.locale }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim).padding(.top, 4)
    }

    private func scenarioRow(_ scenario: StudioScenario, problems: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: scenario.id == session.scenario.id ? "largecircle.fill.circle" : "circle").uiFont(size: 10)
                    .foregroundColor(VSDark.blue)
                Text(scenario.name).uiFont(size: 11).foregroundColor(VSDark.text)
                Text(scenario.kind.title).uiFont(size: 9).foregroundColor(VSDark.textDim)
                Spacer()
                Button("Open") { session.activate(scenario) }.controlSize(.small).disabled(session.busy != nil)
                if !scenario.id.hasPrefix("builtin-") {
                    Button { session.deleteScenario(scenario.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                        .foregroundColor(VSDark.textDim).help("Delete the saved scenario")
                }
            }
            if !problems.isEmpty {
                ForEach(problems, id: \.self) { problem in
                    Text(problem).uiFont(size: 10).foregroundColor(VSDark.orange).fixedSize(horizontal: false, vertical: true)
                }
                Button("Update to the current contracts") { session.updateScenario(scenario) }.controlSize(.small)
                    .help("Writes a new revision of the scenario that fits the current entities; what changed is reported")
            }
        }
    }
}

// MARK: - Environment

struct UIStudioEnvironmentPanel: View {
    @ObservedObject var session: StudioSession
    @ObservedObject var queue: StudioPreparationQueue
    @State private var allowed = ""
    /// Page events opened to their whole text, by group.
    @State private var expandedEvents: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Project processes run with your permissions.").uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.orange)
                FactRows(rows: serverRows)
                ForEach(session.disclosures, id: \.self) { note in
                    Label(note, systemImage: "info.circle").uiFont(size: 10).foregroundColor(VSDark.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !session.removedEnvironment.isEmpty {
                    Text("Not passed to the server: " + session.removedEnvironment.sorted().joined(separator: ", "))
                        .uiFont(size: 10).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                }

                section("Application connections")
                Text("Allowed: the development server, data: and blob: resources, and these addresses. Everything else is blocked.")
                    .uiFont(size: 10).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                ForEach(session.spec.allowedRequests, id: \.self) { pattern in
                    HStack {
                        Text(pattern).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.text)
                        Spacer()
                        Button { session.disallow(pattern) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                            .foregroundColor(VSDark.textDim).disabled(session.busy != nil)
                    }
                }
                HStack {
                    TextField("https://fonts.googleapis.com/*", text: $allowed).textFieldStyle(.roundedBorder).uiFont(size: 10)
                    Button("Allow") {
                        session.allow(allowed)
                        allowed = ""
                    }
                    .disabled(allowed.trimmingCharacters(in: .whitespaces).isEmpty || session.busy != nil)
                }
                .controlSize(.small)

                section("Model connections")
                Text(StudioModelPolicy.description).uiFont(size: 10).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)

                section("Dependencies")
                if session.dependencies.isEmpty {
                    Text("None seen yet.").uiFont(size: 10).foregroundColor(VSDark.textDim)
                }
                ForEach(session.dependencies) { dependency in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(dependency.mode.rawValue).uiFont(size: 9, weight: .semibold).foregroundColor(color(dependency.mode))
                                .frame(width: 70, alignment: .leading)
                            Text(dependency.id).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.text).lineLimit(2)
                        }
                        if !dependency.note.isEmpty {
                            Text(dependency.note).uiFont(size: 9).foregroundColor(VSDark.textDim).padding(.leading, 74)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(dependency.evidence, id: \.self) { evidence in
                            Text("\(evidence.kind.rawValue): \(evidence.detail)").uiFont(size: 9).foregroundColor(VSDark.textDim)
                                .padding(.leading, 74).lineLimit(2)
                        }
                    }
                }

                section("Unknown requests")
                if queue.ordered.isEmpty {
                    Text("Every request so far had a rule.").uiFont(size: 10).foregroundColor(VSDark.textDim)
                }
                ForEach(queue.ordered) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(record.contract).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.text).lineLimit(1)
                            Spacer()
                            Text(record.status.rawValue).uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
                            if [.failed, .timedOut, .cancelled, .limit, .stale].contains(record.status) {
                                Button("Retry") { session.retryPreparation(record.contract) }.controlSize(.small)
                                    .disabled(session.busy != nil)
                            }
                        }
                        if !record.message.isEmpty {
                            Text(record.message).uiFont(size: 9).foregroundColor(VSDark.textDim).lineLimit(3)
                        }
                    }
                }

                section("Requests")
                ForEach(session.requests.suffix(80).reversed()) { request in
                    HStack(spacing: 4) {
                        Text(request.status.map(String.init) ?? "…").uiFont(size: 9, design: .monospaced).frame(width: 28, alignment: .leading)
                        Text(request.outcome).uiFont(size: 9).foregroundColor(VSDark.textDim).frame(width: 62, alignment: .leading)
                        Text("\(request.method) \(request.url)").uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.text)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }

                section("Page events")
                if session.rejectedMessages > 0 {
                    Text("\(session.rejectedMessages) message(s) from the page were rejected (wrong frame, origin, session or generation).")
                        .uiFont(size: 10).foregroundColor(VSDark.orange)
                }
                ForEach(StudioEventGrouping.group(session.events.map { (kind: $0.kind, detail: $0.detail) }).prefix(60)) { group in
                    eventRow(group)
                }

                if !session.serverLog.isEmpty {
                    section("Server output")
                    Text(session.serverLog).uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim).textSelection(.enabled)
                        .lineLimit(60)
                }
            }
            .padding(10)
        }
    }

    private var serverRows: [(String, String)] {
        var rows: [(String, String)] = [("State", session.state.title), ("Detail", session.stateDetail)]
        if let target = session.target {
            rows.append(("Application", target.label))
            rows.append(("Command", target.command))
        }
        if let url = session.appURL { rows.append(("Address", url.absoluteString)) }
        rows.append(("Server", session.appURL == nil ? "—" : session.ownsServer
                     ? "Started by this session; stopped when it closes" : "Already running; left running when the session closes"))
        return rows
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim).padding(.top, 4)
    }

    /// One page event with its repeats counted; a long one (a React hydration diff) opens to its whole text.
    private func eventRow(_ group: StudioEventGrouping.Group) -> some View {
        let expanded = expandedEvents.contains(group.id)
        let long = group.detail.count > 200 || group.detail.contains("\n")
        let color = group.kind == .runtimeError || group.kind == .buildError ? VSDark.red : VSDark.textDim
        return HStack(alignment: .top, spacing: 4) {
            if long {
                Button {
                    if expanded { expandedEvents.remove(group.id) } else { expandedEvents.insert(group.id) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").uiFont(size: 8).frame(width: 10, height: 12)
                }
                .buttonStyle(.plain).foregroundColor(VSDark.textDim)
                .help(expanded ? "Show less" : "Show the whole text")
            } else {
                Color.clear.frame(width: 10, height: 1)
            }
            Text("\(group.kind.rawValue): \(group.detail)").uiFont(size: 9, design: .monospaced).foregroundColor(color)
                .lineLimit(expanded ? nil : 4).fixedSize(horizontal: false, vertical: expanded).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if group.count > 1 {
                Text("×\(group.count)").uiFont(size: 9, weight: .semibold).foregroundColor(color)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.5)))
                    .help("The page reported this \(group.count) times")
            }
        }
    }

    private func color(_ mode: StudioDependency.Mode) -> Color {
        switch mode {
        case .simulated: return VSDark.green
        case .allowed: return VSDark.blue
        case .unsupported: return VSDark.orange
        case .unresolved: return VSDark.red
        }
    }
}

// MARK: - Evidence

struct UIStudioEvidencePanel: View {
    @ObservedObject var session: StudioSession
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var chosen: [String] = []
    @State private var showDifference = false
    @State private var title = ""
    @State private var summary = ""
    @State private var exported: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let comparison = session.comparison { comparisonView(comparison) }

                section("Captures")
                Text("Choose two captures to compare them.").uiFont(size: 10).foregroundColor(VSDark.textDim)
                ForEach(session.captures.reversed()) { capture in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(get: { chosen.contains(capture.id) }, set: { on in
                            chosen.removeAll { $0 == capture.id }
                            if on { chosen.append(capture.id) }
                            if chosen.count > 2 { chosen.removeFirst() }
                        }))
                        .labelsHidden().toggleStyle(.checkbox)
                        StudioCaptureImage(url: session.url(of: capture)).frame(width: 64, height: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(capture.label).uiFont(size: 10).foregroundColor(VSDark.text).lineLimit(1)
                            Text("\(capture.revision.label) · \(capture.rendering.viewport.width)×\(capture.rendering.viewport.height) · \(capture.rendering.colorScheme)")
                                .uiFont(size: 9).foregroundColor(VSDark.textDim).lineLimit(1)
                        }
                    }
                }
                Button("Compare") {
                    guard chosen.count == 2 else { return }
                    let ordered = session.captures.filter { chosen.contains($0.id) }.map(\.id)
                    session.compare(ordered[0], ordered[1])
                }
                .controlSize(.small).disabled(chosen.count != 2)

                section("Export as a feature")
                if session.exportableOperations.isEmpty {
                    Text("Applied or kept changes can be exported with their code changes, revisions, scenario, captures and checks.")
                        .uiFont(size: 10).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField("Feature title", text: $title).textFieldStyle(.roundedBorder).uiFont(size: 11)
                    TextField("What the change does", text: $summary, axis: .vertical).textFieldStyle(.roundedBorder).uiFont(size: 11)
                        .lineLimit(2...5)
                    ForEach(session.exportableOperations) { operation in
                        Toggle(isOn: Binding(get: { exported.contains(operation.id) }, set: { on in
                            if on { exported.insert(operation.id) } else { exported.remove(operation.id) }
                        })) {
                            Text(operation.request).uiFont(size: 10).lineLimit(2)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Button("Export feature") {
                        session.exportFeature(title: title, summary: summary, operations: Array(exported))
                        exported = []
                    }
                    .controlSize(.small)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || exported.isEmpty || session.busy != nil)
                }

                if !session.packages.isEmpty {
                    section("Feature packages")
                    ForEach(session.packages) { package in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(package.title).uiFont(size: 11).foregroundColor(VSDark.text)
                                Spacer()
                                Text(package.status == .current ? "current" : "needs revalidation").uiFont(size: 9, weight: .semibold)
                                    .foregroundColor(package.status == .current ? VSDark.green : VSDark.orange)
                            }
                            if !package.changedSince.isEmpty {
                                Text("Changed since export: " + package.changedSince.joined(separator: ", ")).uiFont(size: 9)
                                    .foregroundColor(VSDark.orange).lineLimit(3)
                            }
                            if !package.featureSlug.isEmpty {
                                Button("Show feature \(package.featureSlug)") { workspaceManager.showFeatureContext(package.featureSlug) }
                                    .buttonStyle(.plain).foregroundColor(VSDark.blue).uiFont(size: 10)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
        .task { await session.revalidatePackages() }
    }

    private func comparisonView(_ comparison: StudioSession.Comparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Comparison").uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text)
                Spacer()
                Picker("", selection: $showDifference) {
                    Text("Side by side").tag(false)
                    Text("Difference").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                Button { session.comparison = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            if !comparison.reasons.isEmpty {
                ForEach(comparison.reasons, id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.triangle").uiFont(size: 10).foregroundColor(VSDark.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let ratio = comparison.changedRatio {
                Text(String(format: "%.2f %% of the pixels changed", ratio * 100)).uiFont(size: 10).foregroundColor(VSDark.textDim)
            }
            if showDifference {
                if let diff = comparison.diffFile {
                    StudioCaptureImage(url: diff)
                } else {
                    Text("These captures have different sizes, so there is no pixel difference.").uiFont(size: 10).foregroundColor(VSDark.textDim)
                }
            } else {
                HStack(alignment: .top, spacing: 4) {
                    VStack(spacing: 2) {
                        Text("Before").uiFont(size: 9).foregroundColor(VSDark.textDim)
                        StudioCaptureImage(url: session.url(of: comparison.before))
                    }
                    VStack(spacing: 2) {
                        Text("After").uiFont(size: 9).foregroundColor(VSDark.textDim)
                        StudioCaptureImage(url: session.url(of: comparison.after))
                    }
                }
            }
        }
        .padding(8).background(VSDark.bg).cornerRadius(6)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim).padding(.top, 4)
    }
}

// MARK: - Contents panel

/// The Contents panel beside a UI Studio tab: the session's facts.
struct UIStudioContentsPanel: View {
    @ObservedObject var session: StudioSession

    var body: some View {
        ScrollView {
            FactRows(rows: [("Tab", "UI Studio"), ("Application", session.target?.label ?? "—"), ("State", session.state.title),
                            ("Address", session.appURL?.absoluteString ?? "—"), ("Scenario", session.scenario.name),
                            ("Route", session.route), ("Changes", String(session.history.filter { $0.kind == .edit }.count)),
                            ("Captures", String(session.captures.count))])
                .padding(10)
        }
    }
}
