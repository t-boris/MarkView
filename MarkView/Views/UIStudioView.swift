import AppKit
import SwiftUI
import WebKit

/// The tab of UI Studio (feature "MarkView UI Studio"): the project's real interface on the left, run by its development
/// server with simulated dependencies; the inspector on the right holds the selected element with questions and changes,
/// the history of changes, the scenarios, the environment and its policies, and the captures and feature export.
struct UIStudioView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: StudioSession
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @WindowStorage("uiStudioInspectorWidth") private var inspectorWidth = 380.0
    @State private var dragStartWidth: Double?
    @State private var panel: Panel = .element
    @State private var draft = ""
    @FocusState private var draftFocused: Bool
    @WindowStorage("uiStudioSelectionExpanded") private var selectionExpanded = true
    @State private var showingTrust = false
    @State private var effectiveScale = 1.0
    @State private var showLivePage = false
    @State private var showingLog = false

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
            Divider().background(palette.border)
            banners
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showingLog {
                        Divider().background(palette.border)
                        UIStudioLogDrawer(log: session.sessionLog, fixable: Set(session.fixableErrors.map(\.key)), busy: session.busy != nil,
                                          fix: { session.fixData($0) }) { showingLog = false }
                    }
                }
                resizeHandle
                inspector.frame(width: inspectorWidth)
            }
        }
        .background(palette.bg)
        .overlay {
            // The comparison of two captures at the size of the whole tab (BUG-094).
            if session.comparisonEnlarged, let comparison = session.comparison {
                StudioComparisonView(url: { session.url(of: $0) }, comparison: comparison) { session.comparisonEnlarged = false }
                    .transition(.opacity)
            }
        }
    }

    private var resizeHandle: some View {
        Rectangle().fill(palette.border).frame(width: 1)
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
            Image(systemName: "macwindow.and.cursorarrow").uiFont(size: 11).foregroundColor(palette.blue)
            Text("UI Studio").uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
            if session.targets.count > 1 {
                Menu(session.target?.label ?? "Choose application") {
                    ForEach(session.targets, id: \.folder) { target in
                        Button(target.label) { session.start(target) }
                    }
                }
                .controlSize(.small).fixedSize()
                .help("The web application of this project the session runs")
            } else if let target = session.target {
                Text(target.label).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1)
            }
            stateBadge
            if session.appURL != nil {
                Text(session.route).uiFont(size: 10, design: .monospaced).foregroundColor(palette.textDim).lineLimit(1)
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
                    Circle().fill(palette.red).frame(width: 6, height: 6)
                    Text("\(session.recordedSteps.count) step\(session.recordedSteps.count == 1 ? "" : "s")")
                    if let last = session.recordedSteps.last {
                        Text("· \(last.action.rawValue) \(last.selector ?? "")").foregroundColor(palette.textDim)
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
            .buttonStyle(.plain).foregroundColor(palette.textDim)
            .help("Color scheme of the page: \(session.scenario.theme.rawValue)")
            Button { session.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                .controlSize(.small).fixedSize().disabled(session.appURL == nil || session.busy != nil)
                .help("Back to the scenario's baseline: its data, an empty browser storage, a fresh page and its restoration steps")
            UIStudioLogButton(log: session.sessionLog, shown: $showingLog)
            Button { session.captureNow() } label: { Image(systemName: "camera") }
                .buttonStyle(.plain).foregroundColor(palette.textDim).disabled(session.appURL == nil || session.busy != nil)
                .help("Capture the preview, linked to the code revision, the scenario and the rendering conditions")
            Button { showingTrust.toggle() } label: { Image(systemName: "shield.lefthalf.filled") }
                .buttonStyle(.plain).foregroundColor(palette.orange)
                .popover(isPresented: $showingTrust, arrowEdge: .bottom) { trustPanel.frame(width: 420).padding(14) }
                .help("What runs, with which permissions, and where the application and the assistant may connect")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(palette.bgSidebar)
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
        case .ready: return palette.green
        case .degraded: return palette.orange
        case .failed: return palette.red
        case .stopped: return palette.textDim
        case .analyzing, .preparing, .starting: return palette.blue
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
            banner(notice, symbol: "info.circle", color: palette.blue) { session.notice = nil }
        }
        if session.state == .degraded, !session.limitations.isEmpty {
            banner("Degraded: " + session.limitations.joined(separator: " · "), symbol: "exclamationmark.triangle", color: palette.orange) {
                panel = .environment
            }
        }
        if let error = session.fixableErrors.first, session.busy == nil {
            // REQ-017: nothing happens until the person clicks.
            let others = session.fixableErrors.count - 1
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "wrench.and.screwdriver").uiFont(size: 10).foregroundColor(palette.orange)
                Text("The page reported an error: " + String(error.key.prefix(160)) + (others > 0 ? " (and \(others) more)" : ""))
                    .uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer()
                Button("Fix data") { session.fixData(error.key) }.controlSize(.small)
                    .help("The assistant reads the error and the code and corrects the simulated records that caused it, or says the error is not caused by data. Nothing changes until you click.")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(palette.bgBanner)
        }
        if session.state == .preparing, session.busy == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(session.stateDetail).uiFont(size: 10).foregroundColor(palette.text).lineLimit(1)
                Spacer()
                Button("Cancel") { session.cancelWork() }.controlSize(.small)
                    .help("Stop preparing; requests without a rule then end in a controlled error")
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(palette.bgBanner)
        }
        if session.rulesArrivedLate {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle").uiFont(size: 10).foregroundColor(palette.blue)
                Text("New simulation rules are ready for requests this page made before they existed. Reload to render it with them.")
                    .uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reload") { session.reloadPage() }.controlSize(.small)
                    .help("Load this address again: the scenario's data stays, text typed on this page is lost")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(palette.bgBanner)
        }
        if let busy = session.busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(busy + (session.busyDetail.isEmpty ? "" : " — " + session.busyDetail)).uiFont(size: 10).foregroundColor(palette.text).lineLimit(1)
                Spacer()
                Button("Cancel") { session.cancelWork() }.controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(palette.bgBanner)
        }
        UIStudioMapBanner(mapper: session.mapping) { session.cancelMapping() }
    }

    private func banner(_ text: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).uiFont(size: 10).foregroundColor(color)
            Text(text).uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer()
            Button(action: action) { Image(systemName: "xmark").uiFont(size: 9) }.buttonStyle(.plain).foregroundColor(palette.textDim)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(palette.bgBanner)
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
                Image(systemName: "exclamationmark.octagon.fill").foregroundColor(palette.red)
                Text("Stale preview: the application does not build after the change. This is the last working capture.")
                    .uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
                Spacer()
                Button("Show the error page") { showLivePage = true }.controlSize(.small)
            }
            .padding(8).background(palette.bgBanner)
            Text(error).uiFont(size: 10, design: .monospaced).foregroundColor(palette.red).lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(palette.bgSidebar).textSelection(.enabled)
            StudioCaptureImage(url: session.url(of: capture)).opacity(0.55).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.bg)
        .onDisappear { showLivePage = false }
    }

    private var startingPlaceholder: some View {
        VStack(spacing: 12) {
            if [.analyzing, .starting, .preparing].contains(session.state) { ProgressView() }
            Text(session.state.title).uiFont(size: 14, weight: .semibold).foregroundColor(palette.text)
            Text(session.stateDetail).uiFont(size: 11).foregroundColor(palette.textDim).multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            if session.target == nil, session.targets.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.targets, id: \.folder) { target in
                        Button { session.start(target) } label: {
                            Label("\(target.label) — \(target.command)", systemImage: target.isElectron ? "macwindow" : "globe")
                        }
                        .buttonStyle(.plain).foregroundColor(palette.blue)
                    }
                }
            }
            if session.state == .failed {
                Button("Try again") { session.start(session.target) }
            }
            if !session.serverLog.isEmpty {
                ScrollView {
                    Text(session.serverLog).uiFont(size: 10, design: .monospaced).foregroundColor(palette.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxWidth: 700, maxHeight: 240).padding(8).background(palette.bgSidebar)
            }
            Text("Project processes run with your permissions.").uiFont(size: 10).foregroundColor(palette.orange)
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
                            .background(panel == item ? palette.bgActive : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain).foregroundColor(panel == item ? palette.text : palette.textDim)
                    .help(item.rawValue)
                }
            }
            .padding(6)
            Text(panel.rawValue.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(palette.textDim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            Divider().background(palette.border)
            switch panel {
            case .element: elementPanel
            case .history: UIStudioHistoryPanel(session: session) { panel = .evidence }
            case .scenarios: UIStudioScenariosPanel(session: session)
            case .environment: UIStudioEnvironmentPanel(session: session, queue: session.preparation)
            case .evidence: UIStudioEvidencePanel(session: session)
            }
        }
        .background(palette.bgSidebar)
    }

    // MARK: Element

    /// The selected element above the conversation about it: the earlier turns oldest first, the turn the assistant is
    /// answering, and the composer. Nothing of the conversation disappears while the assistant works.
    private var elementPanel: some View {
        VStack(spacing: 0) {
            selectionHeader
            Divider().background(palette.border)
            thread
            Divider().background(palette.border)
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
                                .foregroundColor(palette.textDim).frame(width: 10)
                            Text(selection.tag).uiFont(size: 12, weight: .semibold, design: .monospaced).foregroundColor(palette.text)
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
                    .buttonStyle(.plain).foregroundColor(palette.textDim).uiFont(size: 11).disabled(session.busy != nil)
                }
                if selectionExpanded { selectionDetails(selection) }
            }
            .padding(10)
        } else {
            Text(session.mode == .select
                 ? "Click an element in the preview. In Select mode a click selects; it does not run the element's action. Escape ends selecting."
                 : "Nothing is selected: a request is about the whole page. To point at one element, choose Select in the toolbar and click it.")
                .uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }

    private static let threadEnd = "thread-end"

    /// The conversation: the questions and changes since the session opened or was cleared, oldest at the top, then the
    /// request being answered (BUG-075). It follows the newest turn.
    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.conversation.isEmpty, session.pendingTurn == nil {
                        Text("A new conversation. Ask a question, ask for other data or another state (\"fill it with random numbers\", "
                             + "\"show the error\"), or ask for a change to the interface: the assistant answers, makes a new scenario, or "
                             + "edits the code, and says which. It remembers the last turns, so a follow-up can refer to them. Earlier "
                             + "changes are in History, where they can be undone.")
                            .uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(session.conversation) { operation in
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
        let last = session.conversation.last
        return "\(session.conversation.count)|\(last?.id ?? "")|\(last?.status.rawValue ?? "")|\(session.pendingTurn?.started.timeIntervalSince1970 ?? 0)"
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
        .background(palette.bg).cornerRadius(6)
    }

    /// The request the assistant is working on: what was asked, about which element, what the assistant is doing, Stop.
    private func pendingTurn(_ turn: StudioSession.PendingTurn) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "paperplane").uiFont(size: 10)
                    .foregroundColor(palette.blue)
                Text(turn.request).uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            if !turn.element.isEmpty {
                Text(turn.element).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim).lineLimit(1).truncationMode(.middle)
            }
            StudioAttachmentThumbnails(root: session.root, paths: turn.attachments)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                TimelineView(.periodic(from: turn.started, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(turn.started)))
                    Text((session.busyDetail.isEmpty ? (session.busy ?? "Working") : session.busyDetail)
                         + String(format: " · %d:%02d", seconds / 60, seconds % 60))
                        .uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button("Stop") { session.cancelWork() }.controlSize(.small).help("Stop the assistant")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.bg).cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.blue.opacity(0.4)))
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
                .buttonStyle(.plain).foregroundColor(palette.blue).uiFont(size: 10)
            }
            if let boundary = selection.boundary {
                Text(boundary).uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let snippet = selection.snippet {
                DisclosureGroup("Source around the element") {
                    ScrollView(.horizontal) {
                        Text(snippet).uiFont(size: 10, design: .monospaced).foregroundColor(palette.text).textSelection(.enabled)
                    }
                }
                .uiFont(size: 10).foregroundColor(palette.textDim)
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
                .foregroundColor(palette.yellow)
            Text(operation.question ?? "").uiFont(size: 11).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(operation.options, id: \.self) { option in
                Button(option) { session.answerClarification(operation, choice: option) }
                    .controlSize(.small).disabled(session.busy != nil)
            }
            if session.conversation.last?.id == operation.id {
                Text("Or type the answer below and press Send.").uiFont(size: 10).foregroundColor(palette.textDim)
            }
        }
    }

    private var composer: some View {
        DictationInput(text: $draft, isFocused: { draftFocused }) { voice in
        VStack(alignment: .leading, spacing: 6) {
            ImageAttachmentStrip(attachments: $session.attachments)
            TextEditor(text: $draft)
                .uiFont(size: 12).frame(height: 70)
                .scrollContentBackground(.hidden).background(palette.bgInput).cornerRadius(4)
                .focused($draftFocused)
                .takesImageAttachments($session.attachments, text: $draft)
            voice.status
            HStack {
                Button("Clear") { session.clearConversation() }
                    .disabled(session.conversation.isEmpty || session.busy != nil)
                    .help("Start a new conversation: the thread empties and the assistant forgets it. Every change stays in History, where it can be undone")
                Text(session.selection == nil ? "About the whole page." : "About the selected element.")
                    .uiFont(size: 9).foregroundColor(palette.textDim)
                    .help("The assistant answers a question, makes a new scenario for a request about data or state, or edits the code, "
                          + "and the turn says which. A new scenario and a code change can both be undone.")
                Spacer()
                ImageAttachmentMenu(attachments: $session.attachments)
                voice.mic()
                Button("Send") {
                    // Only a question of this conversation is answered; one from before Clear is not. With one request box, only
                    // the latest turn's question is: a request sent after another turn is a request of its own (DEC-010).
                    let images = session.attachments.items
                    if let pending = session.conversation.last, pending.status == .clarification {
                        session.answerClarification(pending, choice: draft, attachments: images)
                    } else {
                        session.change(draft, attachments: images)
                    }
                    draft = ""
                    session.attachments.removeAll()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSend)
                .help("Send the request (⌘↩), with the images in the box. A question is answered and changes nothing; other data, a state, the "
                      + "route or the clock become a new scenario in the Scenario menu; a change to the interface edits the sources and "
                      + "MarkView verifies the rebuilt application")
            }
            .controlSize(.small)
        }
        .padding(8)
        }
    }

    /// A request needs a text or at least one image.
    private var canSend: Bool {
        session.appURL != nil && session.busy == nil
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.attachments.isEmpty)
    }

    // MARK: Trust

    private var trustPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trusted local projects only").uiFont(size: 13, weight: .semibold).foregroundColor(palette.text)
            Text("Project processes run with your permissions. The development server, its build and the application's code are the "
                 + "project's own and are not isolated from your Mac. Open only projects you trust.")
                .uiFont(size: 11).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
            Text("Requests are intercepted inside the page so that they reach the simulation. This keeps the application away from "
                 + "real services; it is not operating-system isolation and does not make a malicious project safe.")
                .uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Application connections").uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
            Text("The page reaches its development server (\(session.appURL?.absoluteString ?? "not running")), local data: and blob: "
                 + "resources and the addresses you allow in Environment. Everything else is blocked; an unknown request is answered by "
                 + "the simulation or ends in a controlled error.")
                .uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            Text("Model connections").uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
            Text(StudioModelPolicy.description).uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            Text("The simulated user is a test account with test credentials.").uiFont(size: 11).foregroundColor(palette.textDim)
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
    @Environment(\.palette) private var palette
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(palette.bg).overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: url) {
            let file = url
            let loaded = await Task.detached { StudioImageDiff.load(file) }.value
            image = loaded.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }
}

/// The images attached to a request (REQ-005), as a row of small thumbnails; nothing when there are none.
struct StudioAttachmentThumbnails: View {
    @Environment(\.palette) private var palette
    let root: URL
    let paths: [String]

    var body: some View {
        let shown = paths.filter(StudioStore.isAttachmentPath)
        if !shown.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(shown, id: \.self) { path in
                        StudioCaptureImage(url: root.appendingPathComponent(path))
                            .frame(width: 44, height: 44)
                            .background(palette.bgInput).clipShape(RoundedRectangle(cornerRadius: 3))
                            .help("Attached image " + (path as NSString).lastPathComponent)
                    }
                }
            }
            .frame(height: 44)
        }
    }
}

// MARK: - History

struct UIStudioHistoryPanel: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: StudioSession
    var showEvidence: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if session.history.isEmpty {
                    Text("Answers, new scenarios and code changes appear here with their verification. Each change can be undone on its "
                         + "own: a code change is removed from the sources, a new scenario gives way to the one it was made from.")
                        .uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(session.history.reversed()) { operation in
                    UIStudioOperationRow(session: session, operation: operation, compact: false, showEvidence: showEvidence)
                    Divider().background(palette.border)
                }
            }
            .padding(10)
        }
    }
}

struct UIStudioOperationRow: View {
    @Environment(\.palette) private var palette
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
                Image(systemName: kindIcon).uiFont(size: 10)
                    .foregroundColor(palette.blue).help(kindTitle)
                Text(operation.request).uiFont(size: 11, weight: .semibold).foregroundColor(palette.text).lineLimit(compact ? nil : 4)
                    .fixedSize(horizontal: false, vertical: compact)
                Spacer()
                Text(operation.status.rawValue).uiFont(size: 9, weight: .semibold).foregroundColor(statusColor)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(statusColor.opacity(0.6)))
            }
            if !operation.selection.isEmpty {
                Text(operation.selection).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim).lineLimit(1)
            }
            StudioAttachmentThumbnails(root: session.root, paths: operation.attachedImages)
            Text(kindTitle + (operation.kind == .edit && operation.scope != .unknown
                              ? " · Scope: \(operation.scope.title)" + (operation.scopeNote.isEmpty ? "" : " — \(operation.scopeNote)") : ""))
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            if let change = operation.context { contextDetails(change) }
            let text = operation.answer.isEmpty ? operation.summary : operation.answer
            if !text.isEmpty {
                Text(text).uiFont(size: 11).foregroundColor(palette.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let conflict = operation.conflict {
                Text(conflict).uiFont(size: 10).foregroundColor(palette.red).fixedSize(horizontal: false, vertical: true)
                if session.undoConflicts[operation.id] != nil {
                    Button("Write the conflict markers into the files") { session.resolveUndoConflictInEditor(operation.id) }
                        .controlSize(.small)
                        .help("Writes both versions with <<<<<<< markers into the files and opens them, so you resolve the overlap yourself")
                }
            }
            if compact, !operation.checks.isEmpty, operation.checks.allSatisfy(\.passed) {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(palette.green).uiFont(size: 10)
                    Text(operation.checks.count == 1 ? operation.checks[0].name : "\(operation.checks.count) checks passed")
                        .uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1)
                }
                .help(operation.checks.map(\.name).joined(separator: "\n"))
            } else if !operation.checks.isEmpty {
                ForEach(operation.checks, id: \.name) { check in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(check.passed ? palette.green : palette.red).uiFont(size: 10)
                        Text(check.name + (check.detail.isEmpty ? "" : ": " + check.detail)).uiFont(size: 10)
                            .foregroundColor(palette.textDim).lineLimit(3)
                    }
                }
            }
            if !operation.files.isEmpty {
                ForEach(operation.files, id: \.path) { file in
                    Button { workspaceManager.openFile(session.root.appendingPathComponent(file.path)) } label: {
                        Label(file.path, systemImage: file.before == nil ? "doc.badge.plus" : "doc.text").uiFont(size: 10)
                    }
                    .buttonStyle(.plain).foregroundColor(palette.blue)
                }
            }
            if operation.kind != .question {
                HStack(spacing: 6) {
                    if operation.status == .applied {
                        Button("Keep") { session.keep(operation.id) }.help("Keep the change; it can still be undone later")
                    }
                    if canUndo {
                        Button("Undo") { session.undo(operation.id) }
                            .help(operation.kind == .context
                                  ? "Return to the scenario this one was made from; the new scenario stays saved in the Scenario menu"
                                  : "Remove this change only; later independent changes stay, overlapping ones are shown as a conflict")
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
                            session.compare(before, after, enlarge: true)
                            showEvidence()
                        }
                        .help("Before and after at the size of the whole tab: side by side, as a difference, or one at a time")
                    }
                }
                .controlSize(.small).disabled(session.busy != nil)
            }
            UIStudioTrackingLine(session: session, operation: operation)
        }
    }

    private var kindIcon: String {
        switch operation.kind {
        case .question: return "questionmark.bubble"
        case .edit: return "wand.and.stars"
        case .context: return "square.stack.3d.up"
        }
    }

    /// Which kind the assistant chose for the request (DEC-010).
    private var kindTitle: String {
        switch operation.kind {
        case .question: return "Answer"
        case .edit: return "Code change"
        case .context: return "Context change"
        }
    }

    private var canUndo: Bool {
        switch operation.kind {
        case .question: return false
        case .edit: return [.applied, .kept, .conflict].contains(operation.status) && !operation.files.isEmpty
        case .context: return [.applied, .kept, .failed].contains(operation.status) && operation.context?.scenarioId.isEmpty == false
        }
    }

    /// The scenario a context change made and what it changed, with what could not be done (REQ-013).
    @ViewBuilder private func contextDetails(_ change: StudioContextChange) -> some View {
        if !change.scenarioId.isEmpty {
            Text("New scenario \u{201C}\(change.scenarioName)\u{201D}, made from \u{201C}\(change.previousScenarioName)\u{201D}; the source code is not changed")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(change.lines, id: \.self) { line in
            Text(line).uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(change.unsupported, id: \.self) { note in
            Text("Not done: " + note).uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        switch operation.status {
        case .applied, .kept, .answered: return palette.green
        case .undone: return palette.textDim
        case .conflict, .failed: return palette.red
        case .clarification: return palette.yellow
        }
    }
}

// MARK: - Scenarios

struct UIStudioScenariosPanel: View {
    @Environment(\.palette) private var palette
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

                UIStudioBrowserSettings(session: session)

                section("Record restoration steps")
                Text("Recording starts from the scenario's baseline. Use the application; clicks, typing and Enter become steps that "
                     + "rebuild this state after every Reset. Typed passwords are replaced by a test value.")
                    .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
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
                        .foregroundColor(palette.textDim).lineLimit(1)
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
        Text(title.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(palette.textDim).padding(.top, 4)
    }

    private func scenarioRow(_ scenario: StudioScenario, problems: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: scenario.id == session.scenario.id ? "largecircle.fill.circle" : "circle").uiFont(size: 10)
                    .foregroundColor(palette.blue)
                Text(scenario.name).uiFont(size: 11).foregroundColor(palette.text)
                Text(scenario.kind.title).uiFont(size: 9).foregroundColor(palette.textDim)
                Spacer()
                Button("Open") { session.activate(scenario) }.controlSize(.small).disabled(session.busy != nil)
                if !scenario.id.hasPrefix("builtin-") {
                    Button { session.deleteScenario(scenario.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                        .foregroundColor(palette.textDim).help("Delete the saved scenario")
                }
            }
            if let description = scenario.description, !description.isEmpty {
                Text(description).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(2)
                    .help(description)
            }
            if !problems.isEmpty {
                ForEach(problems, id: \.self) { problem in
                    Text(problem).uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
                }
                Button("Update to the current contracts") { session.updateScenario(scenario) }.controlSize(.small)
                    .help("Writes a new revision of the scenario that fits the current entities; what changed is reported")
            }
        }
    }
}

// MARK: - Browser settings and kept browser data (REQ-008)

/// The scenario's answers for location, the clipboard, camera and microphone, and notifications, and the cookies and
/// storage kept across restores.
struct UIStudioBrowserSettings: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: StudioSession
    @State private var placeLabel = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var accuracy = ""
    @State private var clipboard = ""

    private enum LocationChoice: Hashable { case denied, unavailable, place }

    private var profile: StudioBrowserProfile { session.scenario.browserProfile }
    private var idle: Bool { session.busy == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Browser")
            Text("Location, the clipboard, camera and microphone, and notifications answer from these settings; the Mac's own "
                 + "are never used. A change resets the page.")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            Picker("Location", selection: locationChoice) {
                Text("Denied").tag(LocationChoice.denied)
                Text("Unavailable").tag(LocationChoice.unavailable)
                Text("A place").tag(LocationChoice.place)
            }
            .uiFont(size: 11).disabled(!idle)
            if case .place = profile.location { placeForm }
            HStack {
                TextField("Clipboard text the page reads", text: $clipboard).textFieldStyle(.roundedBorder).uiFont(size: 11)
                Button("Apply") { update { $0.clipboardText = String(clipboard.prefix(StudioBrowserProfile.maxClipboard)) } }
                    .disabled(!idle || clipboard == profile.clipboardText)
            }
            .controlSize(.small)
            Picker("Camera and microphone", selection: binding(\.media)) {
                Text("Denied").tag(StudioBrowserProfile.Media.denied)
                Text("Test stream").tag(StudioBrowserProfile.Media.testStream)
            }
            .uiFont(size: 11).disabled(!idle)
            Picker("Notifications", selection: binding(\.notifications)) {
                Text("Not asked yet").tag(StudioBrowserProfile.NotificationPermission.default)
                Text("Granted").tag(StudioBrowserProfile.NotificationPermission.granted)
                Text("Denied").tag(StudioBrowserProfile.NotificationPermission.denied)
            }
            .uiFont(size: 11).disabled(!idle)
            let uses = session.events.filter { $0.kind == .browser }.suffix(8).reversed()
            if !uses.isEmpty {
                Text("Used by the page").uiFont(size: 10, weight: .semibold).foregroundColor(palette.text)
                ForEach(Array(uses)) { event in
                    Text(event.detail).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim).lineLimit(2)
                }
            }

            section("Kept cookies and storage")
            Text("Every restore empties cookies and storage, so the application asks again (cookie consent, onboarding). Kept "
                 + "cookies and localStorage entries are set again before the page loads. Entries that look like sessions or "
                 + "credentials are not kept; the rest is saved in .markview/studio/environment.json.")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            Button("Keep this page's cookies and storage") { session.keepBrowserData() }
                .controlSize(.small).disabled(session.appURL == nil || !idle)
            ForEach(session.keptSkipped, id: \.self) { skipped in
                Text("Not kept: " + skipped).uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let kept = session.spec.keptBrowserData {
                ForEach(kept.cookies) { cookie in
                    keptRow("cookie", cookie.name, cookie.value, note: cookie.httpOnly ? "httpOnly" : "") { session.forgetKeptCookie(cookie.id) }
                }
                ForEach(kept.localStorage, id: \.key) { entry in
                    keptRow("localStorage", entry.key, entry.value, note: "") { session.forgetKeptStorage(entry.key) }
                }
                Button("Forget all") { session.forgetKeptBrowserData() }.controlSize(.small)
                    .help("The next restore starts from empty cookies and storage again")
            }
        }
        .onAppear(perform: load)
        .onChange(of: session.scenario.id) { _ in load() }
    }

    private var placeForm: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Label", text: $placeLabel).textFieldStyle(.roundedBorder)
                Menu("Presets") {
                    ForEach(StudioBrowserProfile.Place.presets, id: \.label) { preset in
                        Button(preset.label) { fill(preset) }
                    }
                }
                .fixedSize()
            }
            HStack {
                TextField("Latitude", text: $latitude).textFieldStyle(.roundedBorder)
                TextField("Longitude", text: $longitude).textFieldStyle(.roundedBorder)
                TextField("Accuracy, m", text: $accuracy).textFieldStyle(.roundedBorder).frame(width: 80)
                Button("Apply") {
                    if let place = formPlace { update { $0.location = .place(place) } }
                }
                .disabled(!idle || formPlace == nil)
            }
            if formPlace == nil {
                Text("Latitude −90…90, longitude −180…180 and an accuracy above 0 meters.").uiFont(size: 9).foregroundColor(palette.orange)
            }
        }
        .uiFont(size: 11).controlSize(.small).padding(.leading, 8)
    }

    private var formPlace: StudioBrowserProfile.Place? {
        func number(_ text: String) -> Double? { Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
        guard let latitude = number(latitude), let longitude = number(longitude) else { return nil }
        let place = StudioBrowserProfile.Place(latitude: latitude, longitude: longitude, accuracy: number(accuracy) ?? 25,
                                               label: String(placeLabel.trimmingCharacters(in: .whitespaces).prefix(200)))
        return place.isValid ? place : nil
    }

    private var locationChoice: Binding<LocationChoice> {
        Binding(get: {
            switch profile.location {
            case .denied: return .denied
            case .unavailable: return .unavailable
            case .place: return .place
            }
        }, set: { choice in
            switch choice {
            case .denied: update { $0.location = .denied }
            case .unavailable: update { $0.location = .unavailable }
            case .place:
                let place = formPlace ?? StudioBrowserProfile.Place.presets[0]
                fill(place)
                update { $0.location = .place(place) }
            }
        })
    }

    private func binding<Value: Equatable>(_ path: WritableKeyPath<StudioBrowserProfile, Value>) -> Binding<Value> {
        Binding(get: { profile[keyPath: path] }, set: { value in update { $0[keyPath: path] = value } })
    }

    private func update(_ change: (inout StudioBrowserProfile) -> Void) {
        var next = profile
        change(&next)
        guard next != profile else { return }
        session.setBrowserProfile(next)
    }

    private func fill(_ place: StudioBrowserProfile.Place) {
        placeLabel = place.label
        latitude = String(place.latitude)
        longitude = String(place.longitude)
        accuracy = String(place.accuracy)
    }

    private func load() {
        clipboard = profile.clipboardText
        if case .place(let place) = profile.location { fill(place) } else if latitude.isEmpty { fill(StudioBrowserProfile.Place.presets[0]) }
    }

    private func keptRow(_ kind: String, _ name: String, _ value: String, note: String, forget: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(kind).uiFont(size: 9, weight: .semibold).foregroundColor(palette.textDim).frame(width: 70, alignment: .leading)
            Text(name).uiFont(size: 10, design: .monospaced).foregroundColor(palette.text).lineLimit(1)
            Text(value.count > 40 ? String(value.prefix(40)) + "…" : value).uiFont(size: 9, design: .monospaced)
                .foregroundColor(palette.textDim).lineLimit(1).truncationMode(.tail)
            if !note.isEmpty { Text(note).uiFont(size: 9).foregroundColor(palette.textDim) }
            Spacer()
            Button(action: forget) { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundColor(palette.textDim)
                .help("Forget this entry: it is no longer set again after a restore")
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(palette.textDim).padding(.top, 4)
    }
}

// MARK: - Environment

struct UIStudioEnvironmentPanel: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: StudioSession
    @ObservedObject var queue: StudioPreparationQueue
    @State private var allowed = ""
    /// Page events opened to their whole text, by group.
    @State private var expandedEvents: Set<String> = []

    /// The development server's own requests to other services (REQ-007): each address simulated or real, secrets with
    /// test values or kept real. A change restarts the server MarkView started.
    @ViewBuilder private var serverConnectionsSection: some View {
        section("Server connections")
        if !session.ownsServer, session.appURL != nil {
            Text("This development server was started outside MarkView: its requests to other services are real and its clock is the "
                 + "real clock. Stop it and open UI Studio again to let MarkView start it with simulated connections and the scenario's clock.")
                .uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("The server's requests to these addresses are answered by the simulation, like the page's. Requests to addresses "
                 + "written in the code itself, databases and other protocols stay real.")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
        if session.serverConnections.isEmpty {
            Text("No service addresses found in the env files or the code.").uiFont(size: 10).foregroundColor(palette.textDim)
        }
        ForEach(session.serverConnections) { connection in
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.variable).uiFont(size: 10, design: .monospaced).foregroundColor(palette.text)
                    Text(connection.origin + connection.basePath + "  ·  " + connection.foundIn).uiFont(size: 9).foregroundColor(palette.textDim)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Picker("", selection: Binding(get: { connection.mode }, set: { session.setConnectionMode(connection.variable, $0) })) {
                    Text("Simulated").tag(StudioServerConnection.Mode.simulated)
                    Text("Real").tag(StudioServerConnection.Mode.real)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.mini)
                .disabled(session.busy != nil || !session.ownsServer)
            }
        }
        if !session.serverSecrets.isEmpty {
            Text("Secrets get test values; the real ones never reach the server while it is simulated.")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            ForEach(session.serverSecrets, id: \.self) { name in
                Toggle(isOn: Binding(get: { (session.spec.keptSecrets ?? []).contains(name) },
                                     set: { session.setSecretKeptReal(name, $0) })) {
                    Text("Keep \(name) real").uiFont(size: 10, design: .monospaced)
                }
                .toggleStyle(.checkbox).controlSize(.small).disabled(session.busy != nil || !session.ownsServer)
            }
        }
        ForEach(session.serverNotes, id: \.self) { note in
            Text(note).uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Project processes run with your permissions.").uiFont(size: 11, weight: .semibold).foregroundColor(palette.orange)
                FactRows(rows: serverRows)
                ForEach(session.disclosures, id: \.self) { note in
                    Label(note, systemImage: "info.circle").uiFont(size: 10).foregroundColor(palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !session.removedEnvironment.isEmpty {
                    Text("Not passed to the server: " + session.removedEnvironment.sorted().joined(separator: ", "))
                        .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                }

                section("Application connections")
                Text("Allowed: the development server, data: and blob: resources, and these addresses. Everything else is blocked.")
                    .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                ForEach(session.spec.allowedRequests, id: \.self) { pattern in
                    HStack {
                        Text(pattern).uiFont(size: 10, design: .monospaced).foregroundColor(palette.text)
                        Spacer()
                        Button { session.disallow(pattern) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                            .foregroundColor(palette.textDim).disabled(session.busy != nil)
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

                serverConnectionsSection

                UIStudioMapSection(session: session, mapper: session.mapping)

                section("Model connections")
                Text(StudioModelPolicy.description).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)

                section("Dependencies")
                if session.dependencies.isEmpty {
                    Text("None seen yet.").uiFont(size: 10).foregroundColor(palette.textDim)
                }
                ForEach(session.dependencies) { dependency in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(dependency.mode.rawValue).uiFont(size: 9, weight: .semibold).foregroundColor(color(dependency.mode))
                                .frame(width: 70, alignment: .leading)
                            Text(dependency.id).uiFont(size: 10, design: .monospaced).foregroundColor(palette.text).lineLimit(2)
                        }
                        if !dependency.note.isEmpty {
                            Text(dependency.note).uiFont(size: 9).foregroundColor(palette.textDim).padding(.leading, 74)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(dependency.evidence, id: \.self) { evidence in
                            Text("\(evidence.kind.rawValue): \(evidence.detail)").uiFont(size: 9).foregroundColor(palette.textDim)
                                .padding(.leading, 74).lineLimit(2)
                        }
                    }
                }

                section("Unknown requests")
                if queue.ordered.isEmpty {
                    Text("Every request so far had a rule.").uiFont(size: 10).foregroundColor(palette.textDim)
                }
                ForEach(queue.ordered) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(record.contract).uiFont(size: 10, design: .monospaced).foregroundColor(palette.text).lineLimit(1)
                            Spacer()
                            Text(record.status.rawValue).uiFont(size: 9, weight: .semibold).foregroundColor(palette.textDim)
                            if [.failed, .timedOut, .cancelled, .limit, .stale].contains(record.status) {
                                Button("Retry") { session.retryPreparation(record.contract) }.controlSize(.small)
                                    .disabled(session.busy != nil)
                            }
                        }
                        if !record.message.isEmpty {
                            Text(record.message).uiFont(size: 9).foregroundColor(palette.textDim).lineLimit(3)
                        }
                    }
                }

                section("Requests")
                ForEach(session.requests.suffix(80).reversed()) { request in
                    HStack(spacing: 4) {
                        Text(request.status.map(String.init) ?? "…").uiFont(size: 9, design: .monospaced).frame(width: 28, alignment: .leading)
                        Text(request.outcome).uiFont(size: 9).foregroundColor(palette.textDim).frame(width: 62, alignment: .leading)
                        Text(request.transport).uiFont(size: 9).foregroundColor(request.transport == "server" ? palette.orange : palette.textDim)
                            .frame(width: 38, alignment: .leading)
                            .help(request.transport == "server" ? "Made by the development server through a simulated connection" : "Made by the page")
                        Text("\(request.method) \(request.url)").uiFont(size: 9, design: .monospaced).foregroundColor(palette.text)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }

                section("Page events")
                if session.rejectedMessages > 0 {
                    Text("\(session.rejectedMessages) message(s) from the page were rejected (wrong frame, origin, session or generation).")
                        .uiFont(size: 10).foregroundColor(palette.orange)
                }
                ForEach(StudioEventGrouping.group(session.events.map { (kind: $0.kind, detail: $0.detail) }).prefix(60)) { group in
                    eventRow(group)
                }

                if !session.serverLog.isEmpty {
                    section("Server output")
                    Text(session.serverLog).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim).textSelection(.enabled)
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
            if target.isElectron {
                rows.append(("Electron preload bridge", StudioIPC.summary(session.spec, globals: session.electronGlobals)))
            }
        }
        if let url = session.appURL { rows.append(("Address", url.absoluteString)) }
        rows.append(("Server", session.appURL == nil ? "—" : session.ownsServer
                     ? "Started by this session; stopped when it closes" : "Already running; left running when the session closes"))
        return rows
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(palette.textDim).padding(.top, 4)
    }

    /// One page event with its repeats counted; a long one (a React hydration diff) opens to its whole text.
    private func eventRow(_ group: StudioEventGrouping.Group) -> some View {
        let expanded = expandedEvents.contains(group.id)
        let long = group.detail.count > 200 || group.detail.contains("\n")
        let color = group.kind == .runtimeError || group.kind == .logged || group.kind == .buildError ? palette.red : palette.textDim
        return HStack(alignment: .top, spacing: 4) {
            if long {
                Button {
                    if expanded { expandedEvents.remove(group.id) } else { expandedEvents.insert(group.id) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").uiFont(size: 8).frame(width: 10, height: 12)
                }
                .buttonStyle(.plain).foregroundColor(palette.textDim)
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
        case .simulated: return palette.green
        case .allowed: return palette.blue
        case .unsupported: return palette.orange
        case .unresolved: return palette.red
        }
    }
}

// MARK: - Application map (REQ-014)

/// The progress of the application's map while it is made, with Cancel; nothing otherwise.
struct UIStudioMapBanner: View {
    @Environment(\.palette) private var palette
    @ObservedObject var mapper: StudioEnvironmentMapper
    let cancel: () -> Void

    var body: some View {
        if mapper.isRunning, mapper.phase != .idle {
            HStack(spacing: 8) {
                if [.groups, .refilling].contains(mapper.phase), mapper.total > 0 {
                    ProgressView(value: Double(min(mapper.done, mapper.total)), total: Double(mapper.total))
                        .progressViewStyle(.linear).frame(width: 90)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(mapper.progressText).uiFont(size: 10).foregroundColor(palette.text).lineLimit(1)
                Spacer()
                Button("Cancel") { cancel() }.controlSize(.small)
                    .help("Stop mapping: what is prepared stays, the other groups wait for Resume in the Environment panel")
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(palette.bgBanner)
        }
    }
}

/// The application's map in the Environment panel: its services and groups and how far they got, the data check, and the
/// actions Map Again, Refill Data and Resume.
struct UIStudioMapSection: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: StudioSession
    @ObservedObject var mapper: StudioEnvironmentMapper
    @State private var confirmMapAgain = false
    @State private var confirmRefill = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
    }

    @ViewBuilder private var content: some View {
        Text("APPLICATION MAP").uiFont(size: 9, weight: .semibold).foregroundColor(palette.textDim).padding(.top, 4)
        Text("UI Studio lists the API the application's code calls, from the page and from the server, and prepares the simulation "
             + "for it in the background, group by group, with data that fits together. Requests are prepared one by one until their group is ready.")
            .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        if let map = mapper.map {
            FactRows(rows: rows(map))
            if !map.message.isEmpty {
                Text(map.message).uiFont(size: 10).foregroundColor(map.status == .failed ? palette.red : palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(map.services, id: \.name) { service in
                HStack(spacing: 4) {
                    Text(service.name).uiFont(size: 10, design: .monospaced).foregroundColor(palette.text).frame(width: 130, alignment: .leading)
                        .lineLimit(1)
                    Text(address(service)).uiFont(size: 9).foregroundColor(palette.textDim).lineLimit(1).truncationMode(.middle)
                }
            }
            ForEach(map.groups) { group in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(group.status.rawValue).uiFont(size: 9, weight: .semibold).foregroundColor(color(group.status))
                            .frame(width: 70, alignment: .leading)
                        Text(group.id).uiFont(size: 10, design: .monospaced).foregroundColor(palette.text).lineLimit(1)
                        Spacer()
                        Text("\(group.endpoints.count) endpoint\(group.endpoints.count == 1 ? "" : "s")"
                             + (group.rules.isEmpty ? "" : " · \(group.rules.count) rule\(group.rules.count == 1 ? "" : "s")"))
                            .uiFont(size: 9).foregroundColor(palette.textDim)
                    }
                    .help(group.endpoints.map { "\($0.method) \($0.path)" + ($0.callSite.isEmpty ? "" : " — \($0.callSite)") }.joined(separator: "\n"))
                    if !group.message.isEmpty, group.status != .done {
                        Text(group.message).uiFont(size: 9).foregroundColor(palette.textDim).padding(.leading, 74).lineLimit(3)
                    }
                }
            }
            ForEach(map.notes, id: \.self) { note in
                Text(note).uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            if !map.gaps.isEmpty {
                Text("Data gaps").uiFont(size: 10, weight: .semibold).foregroundColor(palette.orange)
                ForEach(map.gaps, id: \.self) { gap in
                    Text(gap).uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text(mapper.isRunning ? "Listing the API…" : "Not mapped yet: mapping starts when the application opens.")
                .uiFont(size: 10).foregroundColor(palette.textDim)
        }
        HStack(spacing: 6) {
            if mapper.canResume {
                Button("Resume") { session.resumeMapping() }
                    .help("Go on with the groups that are not prepared, and try the failed ones again")
            }
            Button("Map Again…") { confirmMapAgain = true }
                .help("Remove the rules and data the assistant prepared, and map the application from the start")
            Button("Refill Data…") { confirmRefill = true }
                .help("New simulated records for every entity, coherent with each other; the rules stay")
                .disabled(session.spec.entities.isEmpty)
        }
        .controlSize(.small)
        .disabled(mapper.isRunning || session.busy != nil || session.appURL == nil)
        .confirmationDialog("Map the application again?", isPresented: $confirmMapAgain) {
            Button("Remove the prepared rules and map again", role: .destructive) { session.mapAgain() }
        } message: {
            Text("The \(session.spec.rules.filter { $0.origin == .agent }.count) rules the assistant prepared and the data only they use are "
                 + "removed; the project's rules and yours stay. Requests are prepared one by one again until the new map is ready.")
        }
        .confirmationDialog("Refill the simulated data?", isPresented: $confirmRefill) {
            Button("Refill the data of \(session.spec.entities.count) entities") { session.refillData() }
        } message: {
            Text("The assistant writes new records for every entity, so references point at records that exist and every value a list "
                 + "filters by has records. The rules stay. The scenario is reset when the records are ready; scenarios with their own "
                 + "records keep them.")
        }
    }

    private func rows(_ map: StudioEnvironmentMap) -> [(String, String)] {
        var rows: [(String, String)] = [("Status", map.status.rawValue + (mapper.isRunning ? " (running)" : "")),
                                        ("Groups", "\(map.finishedGroups) of \(map.groups.count) finished, \(map.endpointCount) endpoints"),
                                        ("Services", "\(map.services.count)")]
        if !map.appFolder.isEmpty { rows.append(("Folder", map.appFolder)) }
        if let finished = map.finished { rows.append(("Finished", finished.formatted(date: .abbreviated, time: .shortened))) }
        return rows
    }

    private func address(_ service: StudioMapService) -> String {
        let side = service.side.rawValue
        if service.isApplication { return "the application's server · \(side)" }
        let address = service.address.flatMap { $0.isEmpty ? nil : $0 } ?? "address unknown"
        return address + (service.variable.isEmpty ? "" : " · \(service.variable)") + " · \(side)"
    }

    private func color(_ status: StudioMapGroup.Status) -> Color {
        switch status {
        case .done: return palette.green
        case .preparing: return palette.blue
        case .pending: return palette.textDim
        case .failed: return palette.red
        case .unsupported: return palette.orange
        }
    }
}

// MARK: - Evidence

struct UIStudioEvidencePanel: View {
    @Environment(\.palette) private var palette
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
                Text("Choose two captures to compare them.").uiFont(size: 10).foregroundColor(palette.textDim)
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
                            Text(capture.label).uiFont(size: 10).foregroundColor(palette.text).lineLimit(1)
                            Text("\(capture.revision.label) · \(capture.rendering.viewport.width)×\(capture.rendering.viewport.height) · \(capture.rendering.colorScheme)")
                                .uiFont(size: 9).foregroundColor(palette.textDim).lineLimit(1)
                        }
                    }
                }
                Button("Compare") {
                    guard chosen.count == 2 else { return }
                    let ordered = session.captures.filter { chosen.contains($0.id) }.map(\.id)
                    session.compare(ordered[0], ordered[1])
                }
                .controlSize(.small).disabled(chosen.count != 2)
                .help("Compare in this panel; the arrow in the comparison opens it at the size of the whole tab")

                section("Export as a feature")
                if session.exportableOperations.isEmpty {
                    Text("Applied or kept changes can be exported with their code changes, revisions, scenario, captures and checks.")
                        .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
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
                                Text(package.title).uiFont(size: 11).foregroundColor(palette.text)
                                Spacer()
                                Text(package.status == .current ? "current" : "needs revalidation").uiFont(size: 9, weight: .semibold)
                                    .foregroundColor(package.status == .current ? palette.green : palette.orange)
                            }
                            if !package.changedSince.isEmpty {
                                Text("Changed since export: " + package.changedSince.joined(separator: ", ")).uiFont(size: 9)
                                    .foregroundColor(palette.orange).lineLimit(3)
                            }
                            if !package.featureSlug.isEmpty {
                                Button("Show feature \(package.featureSlug)") { workspaceManager.showFeatureContext(package.featureSlug) }
                                    .buttonStyle(.plain).foregroundColor(palette.blue).uiFont(size: 10)
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
                Text("Comparison").uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
                Spacer()
                Picker("", selection: $showDifference) {
                    Text("Side by side").tag(false)
                    Text("Difference").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                Button { session.comparisonEnlarged = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).help("Open the comparison at the size of the whole tab")
                Button { session.comparison = nil; session.comparisonEnlarged = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            if !comparison.reasons.isEmpty {
                ForEach(comparison.reasons, id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.triangle").uiFont(size: 10).foregroundColor(palette.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let ratio = comparison.changedRatio {
                Text(String(format: "%.2f %% of the pixels changed", ratio * 100)).uiFont(size: 10).foregroundColor(palette.textDim)
            }
            if showDifference {
                if let diff = comparison.diffFile {
                    StudioCaptureImage(url: diff)
                } else {
                    Text("These captures have different sizes, so there is no pixel difference.").uiFont(size: 10).foregroundColor(palette.textDim)
                }
            } else {
                HStack(alignment: .top, spacing: 4) {
                    VStack(spacing: 2) {
                        Text("Before").uiFont(size: 9).foregroundColor(palette.textDim)
                        StudioCaptureImage(url: session.url(of: comparison.before))
                    }
                    VStack(spacing: 2) {
                        Text("After").uiFont(size: 9).foregroundColor(palette.textDim)
                        StudioCaptureImage(url: session.url(of: comparison.after))
                    }
                }
            }
        }
        .padding(8).background(palette.bg).cornerRadius(6)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(palette.textDim).padding(.top, 4)
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
                            ("Route", session.route), ("Changes", String(session.history.filter { $0.kind != .question }.count)),
                            ("Captures", String(session.captures.count))])
                .padding(10)
        }
    }
}

// MARK: - Log

/// The toolbar's Log button (REQ-011): opens the log drawer under the preview and counts the problems in the log.
struct UIStudioLogButton: View {
    @ObservedObject var log: StudioLog
    @Binding var shown: Bool

    var body: some View {
        Button { shown.toggle() } label: {
            Label(log.problems > 0 ? "Log \(log.problems)" : "Log", systemImage: shown ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
        }
        .controlSize(.small).fixedSize()
        .help((shown ? "Hide" : "Show") + " the log: navigations and redirects, requests, rule preparations, page events, server output "
              + "and notices" + (log.problems > 0 ? " (\(log.problems) problem\(log.problems == 1 ? "" : "s"))" : ""))
    }
}

/// The log drawer under the preview (REQ-011): the session's entries, newest first, filtered, redacted, selectable.
struct UIStudioLogDrawer: View {
    @Environment(\.palette) private var palette
    @ObservedObject var log: StudioLog
    /// The page errors Fix data may be offered for now (REQ-017), whether the session is busy, and what the action does.
    var fixable: Set<String> = []
    var busy = false
    var fix: (String) -> Void = { _ in }
    let close: () -> Void
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", problems = "Problems", requests = "Requests", server = "Server"
        var id: String { rawValue }

        func includes(_ entry: StudioLogEntry) -> Bool {
            switch self {
            case .all: return true
            case .problems: return entry.problem
            case .requests: return entry.kind == .request || entry.kind == .preparation
            case .server: return entry.kind == .server
            }
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        let shown = log.entries.filter(filter.includes)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("LOG").uiFont(size: 9, weight: .semibold).foregroundColor(palette.textDim)
                    .help("Every entry is also written to .dde/studio/session.log")
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { item in
                        Text(item == .problems && log.problems > 0 ? "Problems \(log.problems)" : item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                .help("Requests include rule preparations; Problems are errors, failures and requests nothing could answer")
                Text("\(shown.count) of \(log.entries.count)").uiFont(size: 9).foregroundColor(palette.textDim)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(StudioLog.text(shown), forType: .string)
                }
                .controlSize(.small).disabled(shown.isEmpty)
                .help("Copy the entries shown, oldest first, as lines of the log file")
                Button("Clear") { log.clear() }
                    .controlSize(.small).disabled(log.entries.isEmpty)
                    .help("Empty this view; .dde/studio/session.log keeps every line")
                Button(action: close) { Image(systemName: "xmark").uiFont(size: 9) }
                    .buttonStyle(.plain).foregroundColor(palette.textDim)
                    .help("Hide the log")
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(palette.bgSidebar)
            Divider().background(palette.border)
            if shown.isEmpty {
                Text(log.entries.isEmpty ? "Nothing logged yet." : "No entries match this filter.")
                    .uiFont(size: 10).foregroundColor(palette.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let newest = Dictionary(log.entries.compactMap { entry in entry.errorKey.map { ($0, entry.id) } }, uniquingKeysWith: max)
                        ForEach(shown.reversed()) { entry in row(entry, offersFix: entry.errorKey.map { fixable.contains($0) && newest[$0] == entry.id } ?? false) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                }
            }
        }
        .frame(height: 220)
        .background(palette.bg)
    }

    /// `offersFix`: the page still reports this error, and this is its latest row (REQ-017).
    private func row(_ entry: StudioLogEntry, offersFix: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.time.string(from: entry.date)).foregroundColor(palette.textDim)
            Text(entry.kind.rawValue).foregroundColor(color(entry.kind)).frame(width: 72, alignment: .leading)
            Text(entry.text).foregroundColor(entry.problem ? palette.red : palette.text)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if offersFix, let key = entry.errorKey {
                Button("Fix data") { fix(key) }.controlSize(.mini).disabled(busy)
                    .help("The assistant reads this error and the code and corrects the simulated records that caused it. Nothing changes until you click.")
            }
        }
        .uiFont(size: 9, design: .monospaced)
        .textSelection(.enabled)
    }

    private func color(_ kind: StudioLogEntry.Kind) -> Color {
        switch kind {
        case .navigation: return palette.blue
        case .request: return palette.green
        case .preparation: return palette.purple
        case .page: return palette.yellow
        case .server: return palette.orange
        case .notice: return palette.cyan
        }
    }
}
