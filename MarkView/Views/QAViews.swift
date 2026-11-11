import SwiftUI
import UniformTypeIdentifiers

// End-to-End QA (feature end-to-end-qa): the scenario list, the graph editor and the generation sheet. The graph is native SwiftUI over
// QAGraphLayout (a pure layered layout), so it needs no bridge to the web editor. Every edit goes through QAModel, which saves it.

// MARK: - The tab

struct QATabView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var model: QAModel
    @State private var showGenerate = false
    /// The scenario the New scenario sheet starts from when it was opened from a scenario's menu.
    @State private var generateBase: String?
    @State private var confirmDelete: String?

    /// Below this width the list is not shown beside the editor: the centre area of a window shares its width with the side panels.
    private static let wideWidth: CGFloat = 1000

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= Self.wideWidth
            Group {
                if wide {
                    HStack(spacing: 0) {
                        list.frame(width: 250)
                        Divider()
                        if model.current != nil { QAEditorView(model: model, wide: true) } else { placeholder.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                } else if model.current != nil {
                    QAEditorView(model: model, wide: false)
                } else {
                    list
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(palette.bg)
        .sheet(isPresented: $showGenerate, onDismiss: { generateBase = nil }) {
            QAGenerateSheet(model: model, isPresented: $showGenerate, baseID: generateBase)
        }
        .onDisappear { model.flush() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scenarios").uiFont(size: 12, weight: .semibold)
                Spacer()
                Button { showGenerate = true } label: { Label("New", systemImage: "plus") }
                    .uiFont(size: 11)
                    .help("Describe a goal and let the assistant write a scenario")
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.scenarios.isEmpty && model.unreadable.isEmpty {
                        Text("No scenarios yet. Describe what to check and the assistant writes the first one.")
                            .uiFont(size: 11).foregroundColor(palette.textDim).padding(10)
                    }
                    ForEach(model.scenarios) { scenario in
                        row(scenario)
                    }
                    ForEach(model.unreadable, id: \.file) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.file).uiFont(size: 11, weight: .medium)
                            Text(item.message).uiFont(size: 10).foregroundColor(palette.orange)
                        }
                        .padding(8)
                        .help("This file is left untouched")
                    }
                }
                .padding(6)
            }
            if let notice = model.notice {
                Divider()
                Text(notice).uiFont(size: 10.5).foregroundColor(palette.textDim).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(palette.bgSidebar)
        .alert("Delete this scenario?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let id = confirmDelete { model.delete(id) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("The file is removed from the project. Runs already made stay.")
        }
    }

    private func row(_ scenario: QAScenario) -> some View {
        let selected = model.current?.id == scenario.id
        let problems = scenario.problems().count
        return Button { model.open(scenario.id) } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scenario.title.isEmpty ? scenario.id : scenario.title).uiFont(size: 11.5, weight: .medium).lineLimit(1)
                    Text("\(scenario.nodes.count) steps · \(scenario.apps.count) \(scenario.apps.count == 1 ? "app" : "apps") · \(scenario.actors.count) \(scenario.actors.count == 1 ? "player" : "players")")
                        .uiFont(size: 10).foregroundColor(palette.textDim)
                }
                Spacer(minLength: 0)
                if problems > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").uiFont(size: 10).foregroundColor(palette.orange).help("\(problems) to fix")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? palette.selection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Duplicate") { model.duplicate(scenario.id) }
            Button("New Scenario Based on This…") { generateBase = scenario.id; showGenerate = true }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete = scenario.id }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist.checked").uiFont(size: 34).foregroundColor(palette.textDim)
            Text("End-to-End QA").uiFont(size: 15, weight: .semibold)
            Text("Describe what a person should be able to do. The assistant writes a scenario with its branches, and you decide which branches to check.")
                .uiFont(size: 12).foregroundColor(palette.textDim).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("New scenario…") { showGenerate = true }.buttonStyle(.borderedProminent)
        }
        .padding(30)
    }
}

// MARK: - The editor

enum QAPanel: String, Hashable, WindowUIStorable { case branches, step, setup, run }

struct QAEditorView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var model: QAModel
    @ObservedObject private var run: QARunModel
    @ObservedObject private var archive: QARunArchive
    let wide: Bool
    /// Which part of the inspector is open. It belongs to the window and survives a switch to another tab of the window and back.
    @WindowStorage("qa.panel") private var panel = QAPanel.branches
    @WindowStorage("qa.inspectorWidth") private var inspectorWidth = 380.0
    @State private var dragStartWidth: CGFloat?

    init(model: QAModel, wide: Bool) {
        self.model = model
        self.wide = wide
        _run = ObservedObject(wrappedValue: model.run)
        _archive = ObservedObject(wrappedValue: model.archive)
    }

    var body: some View {
        if let scenario = model.current {
            VStack(spacing: 0) {
                header(scenario)
                Divider()
                if run.phase != .idle, run.scenario?.id == scenario.id, !run.dismissed {
                    QALiveRunView(run: run) { run.dismiss() }
                } else if let opened = archive.opened, opened.scenarioID == scenario.id {
                    QARunReportView(archive: archive, scenario: scenario, record: opened) { archive.close() }
                } else if wide {
                    GeometryReader { geometry in
                        let width = min(max(320, inspectorWidth), max(320, geometry.size.width - 387))
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                QAGraphCanvas(model: model, scenario: scenario)
                                Divider()
                                QABranchList(model: model, scenario: scenario).frame(height: 190)
                            }
                            .frame(minWidth: 380, maxWidth: .infinity)
                            Rectangle().fill(palette.border).frame(width: 1)
                                .padding(.horizontal, 3)
                                .contentShape(Rectangle())
                                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        let start = dragStartWidth ?? width
                                        dragStartWidth = start
                                        inspectorWidth = min(max(320, start - value.translation.width), max(320, geometry.size.width - 387))
                                    }
                                    .onEnded { _ in dragStartWidth = nil })
                                .accessibilityElement()
                                .accessibilityLabel("Resize QA inspector")
                                .accessibilityValue("\(Int(width)) points")
                                .help("Drag to resize the QA inspector")
                            VStack(spacing: 0) {
                                Picker("", selection: Binding(get: { panel == .branches ? .step : panel }, set: { panel = $0 })) {
                                    Text("Step").tag(QAPanel.step)
                                    Text("Setup").tag(QAPanel.setup)
                                    Text("Run").tag(QAPanel.run)
                                }
                                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.vertical, 6)
                                QAInspector(model: model, scenario: scenario, panel: panel == .branches ? .step : panel)
                            }
                            .frame(width: width)
                        }
                    }
                } else {
                    // The graph and the panel under it share the height; the person drags the divider to give either more.
                    VSplitView {
                        QAGraphCanvas(model: model, scenario: scenario).frame(minHeight: 180)
                        VStack(spacing: 0) {
                            Picker("", selection: $panel) {
                                Text("Branches").tag(QAPanel.branches)
                                Text("Step").tag(QAPanel.step)
                                Text("Setup").tag(QAPanel.setup)
                                Text("Run").tag(QAPanel.run)
                            }
                            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.vertical, 6)
                            switch panel {
                            case .branches: QABranchList(model: model, scenario: scenario)
                            case .step, .setup, .run: QAInspector(model: model, scenario: scenario, panel: panel)
                            }
                        }
                        .frame(minHeight: 160, idealHeight: 320)
                    }
                }
            }
            .onChange(of: model.selectedNode) { if $0 != nil { panel = .step } }
            .onChange(of: model.selectedEdge) { if $0 != nil { panel = .step } }
        }
    }

    private func header(_ scenario: QAScenario) -> some View {
        let problems = scenario.problems()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !wide {
                    Button { model.close() } label: { Label("Scenarios", systemImage: "chevron.left") }.buttonStyle(.borderless).uiFont(size: 11)
                }
                TextField("Title", text: Binding(get: { scenario.title }, set: { value in model.edit { $0.title = value } }))
                    .textFieldStyle(.plain).uiFont(size: 15, weight: .semibold)
                Spacer()
                Button { model.duplicate(scenario.id) } label: { Image(systemName: "plus.square.on.square") }
                    .buttonStyle(.borderless)
                    .help("Duplicate this scenario: the copy opens at once and the original stays as it is")
                    .accessibilityLabel("Duplicate this scenario")
                Picker("", selection: Binding(get: { scenario.appKind }, set: { value in model.edit { $0.appKind = value } })) {
                    Text("Web").tag(QAAppKind.web)
                    Text("macOS app").tag(QAAppKind.nativeMacOS)
                    Text("HTTP API").tag(QAAppKind.api)
                }
                .pickerStyle(.menu).frame(width: 130).labelsHidden()
                .help("All applications of a scenario are of one type")
            }
            TextField("Goal", text: Binding(get: { scenario.goal }, set: { value in model.edit { $0.goal = value } }), axis: .vertical)
                .textFieldStyle(.plain).uiFont(size: 11.5).foregroundColor(palette.textDim).lineLimit(1...3)
            if !problems.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                            Text("• " + problem.message).uiFont(size: 10.5).foregroundColor(palette.text)
                                .onTapGesture { if scenario.node(problem.subject) != nil { model.selectedNode = problem.subject } }
                        }
                    }
                } label: {
                    Label("\(problems.count) \(problems.count == 1 ? "thing" : "things") to fix before this can run", systemImage: "exclamationmark.triangle.fill")
                        .uiFont(size: 11, weight: .medium).foregroundColor(palette.orange)
                }
            }
        }
        .padding(12)
    }
}

// MARK: - The graph

struct QAGraphCanvas: View {
    @Environment(\.palette) private var palette
    @ObservedObject var model: QAModel
    let scenario: QAScenario
    @State private var pull: (from: String, at: CGPoint)?
    /// nil fits the whole graph into the area; a number is the scale the person chose.
    @State private var zoom: CGFloat?
    /// Where the graph's top-left corner is, from the margin: moved by dragging the background and by zooming around the cursor.
    @State private var pan: CGSize = .zero
    /// The pan a background drag started from; nil while no drag runs, and for a drag that began on a step (that one connects steps).
    @State private var dragBase: CGSize?
    @State private var dragIgnored = false
    /// The area the graph is shown in, for the buttons that zoom around its centre.
    @State private var viewport: CGSize = .zero

    private static let space = "qa-graph"
    private static let margin: CGFloat = 6
    private static let zoomRange: ClosedRange<CGFloat> = 0.1...2.5

    var body: some View {
        let layout = QAGraphLayout.make(scenario)
        let lit = litNodes
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
                let scale = zoom ?? fitScale(layout, in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in draw(&context, layout, lit: lit) }
                        .frame(width: layout.size.width, height: layout.size.height)
                    ForEach(layout.nodes) { node in nodeView(node, layout: layout, lit: lit) }
                }
                .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                .coordinateSpace(name: Self.space)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: Self.margin + pan.width, y: Self.margin + pan.height)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                // One gesture for the whole area: a press that hardly moves is a click (select a step or a connection, or nothing), and a drag that
                // starts on empty space moves the graph. A drag that starts on a step connects it to another step instead (see `nodeView`).
                .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if dragBase == nil {
                            dragIgnored = layout.node(at: graphPoint(value.startLocation, scale: scale)) != nil
                            dragBase = pan
                        }
                        guard !dragIgnored, let base = dragBase, hypot(value.translation.width, value.translation.height) >= 4 else { return }
                        if zoom == nil { zoom = scale }
                        pan = CGSize(width: base.width + value.translation.width, height: base.height + value.translation.height)
                    }
                    .onEnded { value in
                        defer { dragBase = nil; dragIgnored = false }
                        guard hypot(value.translation.width, value.translation.height) < 4 else { return }
                        let point = graphPoint(value.location, scale: scale)
                        if let node = layout.node(at: point) { model.selectedNode = node.id; model.selectedEdge = nil }
                        else if let edge = layout.edge(near: point) {
                            model.selectedEdge = QAEdge(from: edge.from, to: edge.to, label: edge.label); model.selectedNode = nil
                        } else { model.selectedNode = nil; model.selectedEdge = nil }
                    })
                .background(QAGraphWheel(
                    onZoom: { point, factor in zoom(by: factor, around: point, scale: zoom ?? fitScale(layout, in: geometry.size)) },
                    onPan: { dx, dy in
                        if zoom == nil { zoom = fitScale(layout, in: geometry.size) }
                        pan = CGSize(width: pan.width + dx, height: pan.height + dy)
                    }))
                .overlay(alignment: .bottomTrailing) { zoomControls(scale: scale, layout: layout) }
                .onAppear { viewport = geometry.size }
                .onChange(of: geometry.size) { viewport = $0 }
                // Another scenario starts fitted, not where the last one was moved to.
                .onChange(of: scenario.id) { _ in zoom = nil; pan = .zero }
            }
            .background(palette.bg)
        }
    }

    /// The scale at which the whole graph is in the area, never above 1.
    private func fitScale(_ layout: QAGraphLayout, in size: CGSize) -> CGFloat {
        let width = (size.width - 2 * Self.margin) / max(1, layout.size.width)
        let height = (size.height - 2 * Self.margin) / max(1, layout.size.height)
        return max(Self.zoomRange.lowerBound, min(1, width, height))
    }

    /// A point of the area in the graph's own coordinates.
    private func graphPoint(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (point.x - Self.margin - pan.width) / scale, y: (point.y - Self.margin - pan.height) / scale)
    }

    /// Changes the scale and keeps the point of the graph under `point` (in the area's own coordinates) where it is.
    private func zoom(by factor: CGFloat, around point: CGPoint, scale: CGFloat) {
        let target = min(max(scale * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let graphPoint = CGPoint(x: (point.x - Self.margin - pan.width) / scale, y: (point.y - Self.margin - pan.height) / scale)
        zoom = target
        pan = CGSize(width: point.x - Self.margin - graphPoint.x * target, height: point.y - Self.margin - graphPoint.y * target)
    }

    private func zoomControls(scale: CGFloat, layout: QAGraphLayout) -> some View {
        let centre = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        return HStack(spacing: 2) {
            Button { zoom(by: 1 / 1.25, around: centre, scale: scale) } label: { Image(systemName: "minus") }.help("Zoom out")
            Button { zoom = nil; pan = .zero } label: { Text("\(Int((scale * 100).rounded()))%").frame(minWidth: 34) }.help("Fit the whole graph")
            Button { zoom(by: 1.25, around: centre, scale: scale) } label: { Image(systemName: "plus") }.help("Zoom in")
        }
        .buttonStyle(.borderless).uiFont(size: 10.5)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgBanner.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border))
        .padding(8)
    }

    private var litNodes: Set<String> {
        guard let id = model.lit else { return [] }
        return Set(id.split(separator: ">").map(String.init))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach([QANodeKind.action, .check, .alternative, .failure], id: \.self) { kind in
                    Button(kindTitle(kind)) { add(kind) }
                }
            } label: { Label("Add step", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                .help(model.selectedNode == nil ? "Adds a step; the first one becomes the start" : "Adds a step after the selected one")
            Button { removeSelection() } label: { Label("Delete", systemImage: "trash").labelStyle(.iconOnly) }
                .disabled(model.selectedNode == nil && model.selectedEdge == nil)
                .help("Delete the selected step or connection")
            Spacer()
            ViewThatFits(in: .horizontal) {
                Text("Wheel zooms · drag the background to move · drag from one step to another to connect them").uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1).fixedSize()
                EmptyView()
            }
        }
        .uiFont(size: 11)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func add(_ kind: QANodeKind) {
        let parent = model.selectedNode ?? scenario.nodes.last?.id
        var created: String?
        model.edit { created = $0.addNode(kind, title: kindTitle(kind), after: $0.nodes.isEmpty ? nil : parent) }
        if let created { model.selectedNode = created; model.selectedEdge = nil }
    }

    private func removeSelection() {
        if let id = model.selectedNode {
            model.edit { $0.removeNode(id, reconnect: true) }
            model.selectedNode = nil
        } else if let edge = model.selectedEdge {
            model.edit { $0.disconnect(edge.from, edge.to) }
            model.selectedEdge = nil
        }
    }

    private func nodeView(_ node: QAGraphLayout.Node, layout: QAGraphLayout, lit: Set<String>) -> some View {
        let item = scenario.node(node.id)
        let selected = model.selectedNode == node.id
        let color = item.map { kindColor($0.kind) } ?? palette.textDim
        let target = pull.flatMap { layout.node(at: $0.at) }?.id == node.id && pull?.from != node.id
        let actor = item.flatMap { scenario.actorID(of: $0) }.flatMap { id in scenario.actors.first { $0.id == id }?.name }
        let app = item.flatMap { scenario.appID(of: $0) }.flatMap { scenario.app($0)?.name }
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(item?.title ?? node.id).uiFont(size: 11.5, weight: .medium).lineLimit(2)
            Text([actor, scenario.apps.count > 1 ? app : nil].compactMap { $0 }.joined(separator: " · "))
                .uiFont(size: 9.5).foregroundColor(palette.textDim).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(width: node.frame.width, height: node.frame.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(palette.bg))
        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(lit.contains(node.id) ? 0.34 : 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected || target ? palette.accent : color.opacity(0.6), lineWidth: selected || target ? 2 : 1))
        .contentShape(Rectangle())
        // A button, so a step can be reached from the keyboard and by assistive technology; dragging from it connects it to another step.
        return Button { model.selectedNode = node.id; model.selectedEdge = nil } label: { content }
            .buttonStyle(.plain)
            .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.space))
                .onChanged { pull = (node.id, $0.location) }
                .onEnded { value in
                    pull = nil
                    guard let end = layout.node(at: value.location), end.id != node.id else { return }
                    model.edit { _ = $0.connect(node.id, end.id) }
                })
            .accessibilityLabel(Text(item?.title ?? node.id))
            .offset(x: node.frame.minX, y: node.frame.minY)
    }

    private func draw(_ context: inout GraphicsContext, _ layout: QAGraphLayout, lit: Set<String>) {
        for edge in layout.edges {
            let selected = model.selectedEdge.map { $0.from == edge.from && $0.to == edge.to } ?? false
            let onBranch = lit.contains(edge.from) && lit.contains(edge.to)
            var path = Path()
            path.move(to: edge.curve[0])
            path.addCurve(to: edge.curve[3], control1: edge.curve[1], control2: edge.curve[2])
            let color = selected ? palette.accent : (onBranch ? palette.text : palette.textDim.opacity(0.7))
            context.stroke(path, with: .color(color), lineWidth: selected || onBranch ? 2 : 1.2)
            // Arrow head at the end.
            let end = edge.curve[3], before = edge.curve[2]
            let angle = atan2(end.y - before.y, end.x - before.x)
            var head = Path()
            head.move(to: end)
            head.addLine(to: CGPoint(x: end.x - 8 * cos(angle - .pi / 7), y: end.y - 8 * sin(angle - .pi / 7)))
            head.addLine(to: CGPoint(x: end.x - 8 * cos(angle + .pi / 7), y: end.y - 8 * sin(angle + .pi / 7)))
            head.closeSubpath()
            context.fill(head, with: .color(color))
            if let label = edge.label, !label.isEmpty {
                context.draw(Text(label).font(.system(size: 10)).foregroundColor(palette.text), at: edge.labelPoint)
            }
        }
        if let pull, let from = layout.node(pull.from) {
            var line = Path()
            line.move(to: CGPoint(x: from.frame.maxX, y: from.frame.midY))
            line.addLine(to: pull.at)
            context.stroke(line, with: .color(palette.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }

    private func kindColor(_ kind: QANodeKind) -> Color {
        switch kind {
        case .action: return palette.blue
        case .check: return palette.green
        case .alternative: return palette.purple
        case .failure: return palette.red
        }
    }

    private func kindTitle(_ kind: QANodeKind) -> String {
        switch kind {
        case .action: return "Action"
        case .check: return "Check"
        case .alternative: return "Alternative"
        case .failure: return "Failure"
        }
    }
}

// MARK: - The branches

struct QABranchList: View {
    @Environment(\.palette) private var palette
    @ObservedObject var model: QAModel
    let scenario: QAScenario

    var body: some View {
        let enumeration = scenario.enumerateBranches()
        let selected = Set(scenario.selected)
        VStack(spacing: 0) {
            HStack {
                Text("Branches").uiFont(size: 11.5, weight: .semibold)
                Text("\(selected.intersection(Set(enumeration.branches.map(\.id))).count) of \(enumeration.branches.count) chosen")
                    .uiFont(size: 10.5).foregroundColor(palette.textDim)
                Spacer()
                Button("All") { model.edit { $0.selectAllBranches() } }
                Button("None") { model.edit { $0.clearSelection() } }
            }
            .uiFont(size: 11)
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if enumeration.branches.isEmpty {
                Text("A branch is a path from the start to an end. Add steps and connect them to get branches.")
                    .uiFont(size: 11).foregroundColor(palette.textDim).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(enumeration.branches, id: \.id) { branch in
                            row(branch, isOn: selected.contains(branch.id))
                        }
                        if enumeration.truncated {
                            Text("Only the first \(enumeration.branches.count) branches are listed.").uiFont(size: 10).foregroundColor(palette.orange).padding(8)
                        }
                    }
                    .padding(4)
                }
            }
        }
        .background(palette.bgSidebar)
    }

    private func row(_ branch: QABranch, isOn: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { isOn }, set: { value in model.edit { $0.setSelected(branch.id, value) } }))
                .labelsHidden().toggleStyle(.checkbox)
            Text(scenario.label(of: branch)).uiFont(size: 11).lineLimit(2)
            Spacer(minLength: 0)
            if scenario.apps.count > 1 {
                Text(scenario.apps(in: branch).compactMap { scenario.app($0)?.name }.joined(separator: " + "))
                    .uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(model.lit == branch.id ? palette.bgHover : Color.clear))
        .onHover { inside in
            if inside { model.lit = branch.id } else if model.lit == branch.id { model.lit = nil }
        }
    }
}

// MARK: - The inspector

struct QAInspector: View {
    @Environment(\.palette) private var palette
    @ObservedObject var model: QAModel
    let scenario: QAScenario
    @WindowStorage("qa.showApps") private var showApps = true
    @WindowStorage("qa.showPlayers") private var showPlayers = true
    @WindowStorage("qa.showEnvironments") private var showEnvironments = true
    @WindowStorage("qa.showBaseline") private var showBaseline = false
    let panel: QAPanel
    /// The sign-in being added for a player; one at a time.
    @State private var loginDraft: QALoginDraft?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch panel {
                case .step, .branches:
                    if let id = model.selectedNode, let node = scenario.node(id) {
                        nodeSection(node)
                    } else if let edge = model.selectedEdge {
                        edgeSection(edge)
                    } else {
                        Text("Select a step or a connection in the graph to edit it.").uiFont(size: 11).foregroundColor(palette.textDim)
                    }
                case .setup:
                    DisclosureGroup(isExpanded: $showApps) { appsSection.padding(.top, 6) } label: { heading("Applications (\(scenario.apps.count))") }
                    DisclosureGroup(isExpanded: $showPlayers) { actorsSection.padding(.top, 6) } label: { heading("Players (\(scenario.actors.count))") }
                    DisclosureGroup(isExpanded: $showEnvironments) { environmentsSection.padding(.top, 6) } label: { heading("Environments (\(scenario.targets.count))") }
                    DisclosureGroup(isExpanded: $showBaseline) { baselineSection.padding(.top, 6) } label: { heading("Baseline") }
                case .run:
                    QARunPanel(model: model, scenario: scenario)
                }
            }
            .padding(12)
        }
        .background(palette.bgSidebar)
    }

    // A step

    private func nodeSection(_ node: QANode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Step \(node.id)")
            TextField("Title", text: node.binding(model, \.title)).textFieldStyle(.roundedBorder)
            Picker("Kind", selection: node.binding(model, \.kind)) {
                Text("Action").tag(QANodeKind.action)
                Text("Check").tag(QANodeKind.check)
                Text("Alternative").tag(QANodeKind.alternative)
                Text("Failure").tag(QANodeKind.failure)
            }
            Text(node.kind == .check || node.kind == .failure ? "What must hold" : "What happens").uiFont(size: 10.5).foregroundColor(palette.textDim)
            TextEditor(text: node.binding(model, \.detail)).uiFont(size: 11.5).frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border))
            Picker("Player", selection: Binding(get: { node.actor ?? "" }, set: { value in model.edit { $0.update(node: node.id) { $0.actor = value.isEmpty ? nil : value } } })) {
                Text("Same as before").tag("")
                ForEach(scenario.actors) { Text($0.name).tag($0.id) }
            }
            if scenario.apps.count > 1 {
                Picker("Application", selection: Binding(get: { node.app ?? "" }, set: { value in model.edit { $0.update(node: node.id) { $0.app = value.isEmpty ? nil : value } } })) {
                    Text("The player's own").tag("")
                    ForEach(scenario.apps) { Text($0.name).tag($0.id) }
                }
            }
            Picker("Changes data", selection: node.binding(model, \.changesData)) {
                Text("Unknown").tag(QADataChange.unknown)
                Text("Yes").tag(QADataChange.yes)
                Text("No").tag(QADataChange.no)
            }
            .help("A step that changes data needs a prepared baseline before each check")
            if scenario.appKind == .api { QAAPIRequestEditor(model: model, node: node) }
            conditionSection(node)
            HStack {
                Button("Add step after") { var id: String?; model.edit { id = $0.addNode(.action, title: "Action", after: node.id) }; if let id { model.selectedNode = id } }
                Spacer()
                Button("Delete", role: .destructive) { model.edit { $0.removeNode(node.id, reconnect: true) }; model.selectedNode = nil }
            }
            .uiFont(size: 11)
        }
    }

    private func conditionSection(_ node: QANode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Needs a condition", isOn: Binding(get: { node.condition != nil }, set: { on in
                model.edit { $0.update(node: node.id) { $0.condition = on ? QACondition(kind: .state, establish: "", verify: "") : nil } }
            }))
            if let condition = node.condition {
                Picker("Kind", selection: Binding(get: { condition.kind }, set: { value in
                    changeCondition(node.id) { condition in
                        condition.kind = value
                        if value == .networkFault && condition.fault == nil { condition.fault = QAFault(urlPattern: "", mode: .fail) }
                    }
                })) {
                    Text("State").tag(QAConditionKind.state)
                    Text("Data").tag(QAConditionKind.data)
                    Text("Network fault").tag(QAConditionKind.networkFault)
                    Text("Delay").tag(QAConditionKind.delay)
                }
                if condition.kind == .state || condition.kind == .data {
                    Toggle("I set it up myself", isOn: Binding(get: { condition.manual == true }, set: { on in changeCondition(node.id) { $0.manual = on ? true : nil } }))
                        .help("For what the application's pages cannot do: the run asks you to do it before the check and does not try itself")
                }
                Text(condition.manual == true ? "What you do" : "How to set it up").uiFont(size: 10.5).foregroundColor(palette.textDim)
                TextField("Establish", text: Binding(get: { condition.establish }, set: { value in changeCondition(node.id) { $0.establish = value } }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                Text("How to confirm it holds").uiFont(size: 10.5).foregroundColor(palette.textDim)
                TextField("Verify", text: Binding(get: { condition.verify }, set: { value in changeCondition(node.id) { $0.verify = value } }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                if condition.kind == .networkFault || condition.kind == .delay {
                    TextField("Address pattern", text: Binding(get: { condition.fault?.urlPattern ?? "" }, set: { value in
                        changeCondition(node.id) { condition in
                            var fault = condition.fault ?? QAFault(urlPattern: "", mode: condition.kind == .delay ? .delay : .fail)
                            fault.urlPattern = value
                            condition.fault = fault
                        }
                    })).textFieldStyle(.roundedBorder)
                }
            }
        }
        .uiFont(size: 11)
    }

    /// Edits the condition of a step as one value, so the change touches the scenario once.
    private func changeCondition(_ id: String, _ change: @escaping (inout QACondition) -> Void) {
        model.edit { scenario in
            scenario.update(node: id) { node in
                guard var condition = node.condition else { return }
                change(&condition)
                node.condition = condition
            }
        }
    }

    // A connection

    private func edgeSection(_ edge: QAEdge) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("\(scenario.node(edge.from)?.title ?? edge.from) → \(scenario.node(edge.to)?.title ?? edge.to)")
            TextField("Label (for example: card declined)", text: Binding(get: { scenario.edges.first { $0.from == edge.from && $0.to == edge.to }?.label ?? "" }, set: { value in
                model.edit { $0.setLabel(value, from: edge.from, to: edge.to) }
            })).textFieldStyle(.roundedBorder)
            HStack {
                Button("Insert step") { var id: String?; model.edit { id = $0.insertNode(.action, title: "Action", between: edge.from, and: edge.to) }; if let id { model.selectedNode = id; model.selectedEdge = nil } }
                Spacer()
                Button("Remove connection", role: .destructive) { model.edit { $0.disconnect(edge.from, edge.to) }; model.selectedEdge = nil }
            }
            .uiFont(size: 11)
        }
    }

    // Applications and players

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button { addApp() } label: { Label("Add application", systemImage: "plus") }.buttonStyle(.borderless).uiFont(size: 11)
                    .disabled(scenario.apps.count >= QAGeneration.maxApps)
            }
            ForEach(scenario.apps) { app in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Name", text: Binding(get: { app.name }, set: { value in model.edit { s in if let i = s.apps.firstIndex(where: { $0.id == app.id }) { s.apps[i].name = value } } }))
                            .textFieldStyle(.roundedBorder)
                        if scenario.apps.count > 1 {
                            Button { removeApp(app.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                                .help("Remove this application")
                        }
                    }
                    HStack {
                        Text("Review as").uiFont(size: 10.5).foregroundColor(palette.textDim)
                        Spacer()
                        Picker("", selection: Binding(get: { app.profile }, set: { value in model.edit { s in if let i = s.apps.firstIndex(where: { $0.id == app.id }) { s.apps[i].profile = value } } })) {
                            ForEach(QAReviewProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 150)
                        .help("What this application is reviewed against")
                    }
                    DisclosureGroup("Review requirements") {
                        TextEditor(text: Binding(get: { app.requirements.isEmpty ? app.profile.presetRequirements : app.requirements },
                                             set: { value in model.edit { s in if let i = s.apps.firstIndex(where: { $0.id == app.id }) { s.apps[i].requirements = value == app.profile.presetRequirements ? "" : value } } }))
                        .uiFont(size: 10.5).frame(height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border))
                    }
                    .uiFont(size: 10.5)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput.opacity(0.35)))
            }
        }
    }

    private var actorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button { addActor() } label: { Label("Add player", systemImage: "plus") }.buttonStyle(.borderless).uiFont(size: 11)
                    .disabled(scenario.actors.count >= QAGeneration.maxActors)
            }
            ForEach(scenario.actors) { actor in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Name", text: Binding(get: { actor.name }, set: { value in model.edit { s in if let i = s.actors.firstIndex(where: { $0.id == actor.id }) { s.actors[i].name = value } } }))
                            .textFieldStyle(.roundedBorder)
                        Button { removeActor(actor.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            .disabled(scenario.nodes.contains { $0.actor == actor.id })
                            .help(scenario.nodes.contains { $0.actor == actor.id } ? "This player has steps" : "Remove this player")
                    }
                    if scenario.apps.count > 1 {
                        HStack {
                            Text("Application").uiFont(size: 10.5).foregroundColor(palette.textDim)
                            Picker("", selection: Binding(get: { actor.app ?? "" }, set: { value in model.edit { s in if let i = s.actors.firstIndex(where: { $0.id == actor.id }) { s.actors[i].app = value.isEmpty ? nil : value } } })) {
                                Text("—").tag("")
                                ForEach(scenario.apps) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden().frame(maxWidth: .infinity)
                            .help("The application this player uses")
                        }
                    }
                    HStack(spacing: 8) {
                        loginMenu(actor)
                            .popover(isPresented: Binding(get: { loginDraft?.actor == actor.id }, set: { if !$0 { loginDraft = nil } }), arrowEdge: .bottom) {
                                if let draft = loginDraft {
                                    QALoginForm(draft: draft, onCancel: { loginDraft = nil }) { host, username, password in
                                        let saved = await model.saveLogin(host: host, username: username, password: password)
                                        if saved {
                                            setLogin(actor.id, QALoginReference(host: host, username: username))
                                            loginDraft = nil
                                        }
                                        return saved
                                    }
                                }
                            }
                        Toggle("Test account", isOn: Binding(get: { actor.createTestAccount }, set: { value in model.edit { s in if let i = s.actors.firstIndex(where: { $0.id == actor.id }) { s.actors[i].createTestAccount = value } } }))
                            .toggleStyle(.checkbox).uiFont(size: 10.5)
                            .fixedSize(horizontal: true, vertical: false)
                            .help("Create an account that exists only for this test, instead of signing in with a saved login")
                            .disabled(actor.login != nil)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput.opacity(0.35)))
            }
            Text("A login is chosen from the passwords the browser saved, or added here: it is saved in the macOS Keychain, the same place. Passwords are never copied into the scenario.")
                .uiFont(size: 10).foregroundColor(palette.textDim)
        }
        .onAppear { model.loadSavedLogins() }
    }

    /// The hosts the player's application runs on, from the addresses of the environments.
    private func hosts(of actor: QAActor) -> [String] {
        let appID = actor.app ?? scenario.apps.first?.id
        var seen: [String] = []
        for target in scenario.targets {
            let urls = appID.flatMap { target.locations[$0]?.url }.map { [$0] } ?? target.locations.values.compactMap(\.url)
            for url in urls {
                if let host = PasswordRules.host(fromInput: url), !seen.contains(host) { seen.append(host) }
            }
        }
        return seen
    }

    private func loginMenu(_ actor: QAActor) -> some View {
        let current = actor.login
        let own = hosts(of: actor)
        // The logins of this player's own hosts first, then the rest of what the browser saved.
        let mine = model.savedLogins.filter { own.contains($0.host) }
        let others = model.savedLogins.filter { !own.contains($0.host) }
        func item(_ login: SavedLogin) -> some View {
            Button("\(login.username.isEmpty ? "(no user name)" : login.username) — \(login.host)") { setLogin(actor.id, QALoginReference(host: login.host, username: login.username)) }
        }
        return Menu {
            Button("No login") { setLogin(actor.id, nil) }
            Button("Add login…") { loginDraft = QALoginDraft(actor: actor.id, host: own.first ?? "") }
            Divider()
            if model.savedLogins.isEmpty {
                Text("No saved logins yet")
            }
            ForEach(mine) { item($0) }
            if !mine.isEmpty && !others.isEmpty { Divider() }
            ForEach(others) { item($0) }
        } label: {
            Label(current.map { "\($0.username) — \($0.host)" } ?? "No login", systemImage: "key")
                .uiFont(size: 10.5).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(current.map { "\($0.username) — \($0.host)" } ?? "The saved login this player signs in with")
    }

    private func setLogin(_ id: String, _ login: QALoginReference?) {
        model.edit { s in
            guard let i = s.actors.firstIndex(where: { $0.id == id }) else { return }
            s.actors[i].login = login
            if login != nil { s.actors[i].createTestAccount = false }
            s.updated = Date()
        }
    }

    // Environments

    private var environmentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Menu {
                    Button("Local") { addEnvironment(.local) }
                    Button("Development") { addEnvironment(.development) }
                    Button("Production") { addEnvironment(.production) }
                } label: { Label("Add environment", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().uiFont(size: 11)
            }
            if scenario.targets.isEmpty {
                Text("Say where the applications run: on this Mac, on a development server or in production.").uiFont(size: 10.5).foregroundColor(palette.textDim)
            }
            ForEach(scenario.targets) { target in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        TextField("Name", text: Binding(get: { target.name }, set: { value in editTarget(target.id) { $0.name = value } })).textFieldStyle(.roundedBorder)
                        Picker("", selection: Binding(get: { target.kind }, set: { value in editTarget(target.id) { $0.kind = value } })) {
                            Text("Local").tag(QATargetKind.local)
                            Text("Development").tag(QATargetKind.development)
                            Text("Production").tag(QATargetKind.production)
                        }
                        .labelsHidden().frame(width: 130)
                        Button { removeEnvironment(target.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove this environment")
                    }
                    if target.kind == .production {
                        Label("Actions that change data need your confirmation", systemImage: "exclamationmark.shield").uiFont(size: 10).foregroundColor(palette.orange)
                    }
                    ForEach(scenario.apps) { app in
                        locationRow(target, app)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput.opacity(0.5)))
            }
        }
    }

    @ViewBuilder private func locationRow(_ target: QATarget, _ app: QAApp) -> some View {
        let location = target.locations[app.id]
        HStack(spacing: 6) {
            if scenario.apps.count > 1 { Text(app.name).uiFont(size: 10.5).foregroundColor(palette.textDim).frame(width: 90, alignment: .leading).lineLimit(1) }
            if scenario.appKind != .nativeMacOS {
                TextField("https://…", text: Binding(get: { location?.url ?? "" }, set: { value in
                    editTarget(target.id) { $0.locations[app.id] = QALocation(url: value.isEmpty ? nil : value) }
                })).textFieldStyle(.roundedBorder)
            } else {
                Button { chooseApplication(target.id, app.id) } label: {
                    Label(location?.application.map { "\($0.name) (\($0.bundleIdentifier))" } ?? "Choose an installed application…", systemImage: "app.dashed").uiFont(size: 10.5).lineLimit(1)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func addEnvironment(_ kind: QATargetKind) {
        model.edit { s in
            let base = kind.rawValue
            var id = base, number = 2
            while s.targets.contains(where: { $0.id == id }) { id = base + String(number); number += 1 }
            var target = QATarget(id: id, kind: kind, name: kind == .local ? "Local" : (kind == .development ? "Development" : "Production"))
            if s.appKind != .nativeMacOS && kind == .local { for app in s.apps { target.locations[app.id] = QALocation(url: "http://localhost:3000") } }
            s.targets.append(target)
            s.updated = Date()
        }
    }

    private func removeEnvironment(_ id: String) {
        model.edit { s in
            s.targets.removeAll { $0.id == id }
            s.updated = Date()
        }
    }

    private func editTarget(_ id: String, _ change: (inout QATarget) -> Void) {
        model.edit { s in
            guard let i = s.targets.firstIndex(where: { $0.id == id }) else { return }
            change(&s.targets[i])
            s.updated = Date()
        }
    }

    /// A native application is chosen from the installed ones; MarkView launches it for each check (DEC-008).
    private func chooseApplication(_ target: String, _ app: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the installed application to check"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? FileManager.default.displayName(atPath: url.path)
        editTarget(target) { $0.locations[app] = QALocation(application: QAApplication(bundleIdentifier: identifier, name: name)) }
    }

    // Baseline

    private var baselineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The checks run one after another and each starts from the same state. Say how the application is brought back to it, and how to tell that it is.")
                .uiFont(size: 10.5).foregroundColor(palette.textDim)
            Toggle("Restore a baseline before each check", isOn: Binding(get: { scenario.baseline != nil }, set: { on in
                model.edit { s in s.baseline = on ? QACondition(kind: .state, establish: "", verify: "") : nil; s.updated = Date() }
            }))
            if let baseline = scenario.baseline {
                Toggle("I restore it myself", isOn: Binding(get: { baseline.manual == true }, set: { on in model.edit { s in s.baseline?.manual = on ? true : nil; s.updated = Date() } }))
                    .help("For what the application's pages cannot do (restoring a snapshot, seeding a database): the run asks you to do it before each check and does not try itself")
                TextField(baseline.manual == true ? "What you do to restore it" : "How to restore it", text: Binding(get: { baseline.establish }, set: { value in model.edit { s in s.baseline?.establish = value; s.updated = Date() } }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                TextField("How to confirm it", text: Binding(get: { baseline.verify }, set: { value in model.edit { s in s.baseline?.verify = value; s.updated = Date() } }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
            }
        }
        .uiFont(size: 11)
    }

    private func addApp() {
        model.edit { s in
            var number = s.apps.count + 1
            while s.apps.contains(where: { $0.id == "app\(number)" }) { number += 1 }
            s.apps.append(QAApp(id: "app\(number)", name: "Application \(number)"))
            s.updated = Date()
        }
    }

    private func removeApp(_ id: String) {
        model.edit { s in
            s.apps.removeAll { $0.id == id }
            for index in s.actors.indices where s.actors[index].app == id { s.actors[index].app = nil }
            for index in s.nodes.indices where s.nodes[index].app == id { s.nodes[index].app = nil }
            for index in s.targets.indices { s.targets[index].locations[id] = nil }
            s.updated = Date()
        }
    }

    private func addActor() {
        model.edit { s in
            var number = s.actors.count + 1
            while s.actors.contains(where: { $0.id == "player\(number)" }) { number += 1 }
            s.actors.append(QAActor(id: "player\(number)", name: "Player \(number)", app: s.apps.count == 1 ? s.apps[0].id : nil))
            s.updated = Date()
        }
    }

    private func removeActor(_ id: String) {
        model.edit { s in
            s.actors.removeAll { $0.id == id }
            s.updated = Date()
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).uiFont(size: 11.5, weight: .semibold).lineLimit(2)
    }
}

private extension QANode {
    /// A binding that writes one field of this step through the model, so the edit is saved.
    func binding<Value>(_ model: QAModel, _ keyPath: WritableKeyPath<QANode, Value>) -> Binding<Value> {
        let id = self.id
        let current = self[keyPath: keyPath]
        return Binding(get: { model.current?.node(id)?[keyPath: keyPath] ?? current },
                       set: { value in model.edit { $0.update(node: id) { $0[keyPath: keyPath] = value } } })
    }
}

// MARK: - The run: what would be done, and the approval

struct QARunPanel: View {
    @Environment(\.palette) private var palette
    @ObservedObject var model: QAModel
    @ObservedObject private var run: QARunModel
    let scenario: QAScenario
    @State private var acknowledged = false
    @State private var permissions = QANativePermissions.current

    init(model: QAModel, scenario: QAScenario) {
        self.model = model
        self.scenario = scenario
        _run = ObservedObject(wrappedValue: model.run)
    }

    var body: some View {
        let plan = model.plan
        VStack(alignment: .leading, spacing: 12) {
            environment
            if let plan {
                summary(plan)
                if !plan.problems.isEmpty { problems(plan) }
                if !plan.preparation.isEmpty { preparation(plan) }
                if plan.isProduction && !plan.confirmations.isEmpty { production(plan) }
                approval(plan)
                start
            }
            QARunsList(archive: model.archive, scenarioID: scenario.id, phase: run.phase)
        }
        .onAppear { model.loadSavedLogins() }
        .onChange(of: plan?.fingerprint) { _ in acknowledged = false }
    }

    private var environment: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Environment to check").uiFont(size: 11.5, weight: .semibold)
            if scenario.targets.isEmpty {
                Text("Add an environment in Setup first.").uiFont(size: 11).foregroundColor(palette.textDim)
            } else {
                Picker("", selection: Binding(get: { model.effectiveTargetID ?? "" }, set: { model.targetID = $0.isEmpty ? nil : $0 })) {
                    if model.effectiveTargetID == nil { Text("Choose…").tag("") }
                    ForEach(scenario.targets) { target in Text("\(target.name) (\(target.kind.rawValue))").tag(target.id) }
                }
                .labelsHidden()
            }
        }
    }

    private func summary(_ plan: QAExecutionPlan) -> some View {
        let count = plan.branches.count
        return Text("\(count) \(count == 1 ? "branch" : "branches") chosen · \(plan.preparation.count) \(plan.preparation.count == 1 ? "step" : "steps") of preparation")
            .uiFont(size: 11).foregroundColor(palette.textDim)
    }

    private func problems(_ plan: QAExecutionPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(plan.problems.enumerated()), id: \.offset) { _, problem in
                Label { Text(problem.message).uiFont(size: 10.5).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: problem.blocks ? "xmark.octagon.fill" : "exclamationmark.triangle.fill").foregroundColor(problem.blocks ? palette.red : palette.orange)
                }
            }
        }
    }

    private func preparation(_ plan: QAExecutionPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Before the checks").uiFont(size: 11.5, weight: .semibold)
            ForEach(plan.preparation) { step in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon(step.kind)).foregroundColor(palette.textDim).frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title).uiFont(size: 11)
                        if !step.detail.isEmpty { Text(step.detail).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(3) }
                        if step.automated { Text("MarkView brings this about itself").uiFont(size: 10).foregroundColor(palette.textDim) }
                    }
                    Spacer(minLength: 0)
                    if step.manual { Text("you do this").uiFont(size: 9.5).foregroundColor(palette.blue) }
                    else if step.changesData != .no { Text(step.changesData == .yes ? "changes data" : "may change data").uiFont(size: 9.5).foregroundColor(palette.orange) }
                }
            }
        }
    }

    private func production(_ plan: QAExecutionPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Production", systemImage: "exclamationmark.shield.fill").uiFont(size: 11.5, weight: .semibold).foregroundColor(palette.red)
            Text("These \(plan.confirmations.count) actions may change data on production. Each one asks for your yes when the run reaches it.")
                .uiFont(size: 10.5).fixedSize(horizontal: false, vertical: true)
            ForEach(plan.confirmations) { item in
                Text("• \(item.title) — \(item.reason)").uiFont(size: 10.5).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("I understand and accept that these actions may change data on production", isOn: $acknowledged)
                .toggleStyle(.checkbox).uiFont(size: 10.5)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.red.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.red.opacity(0.5)))
    }

    @ViewBuilder private func approval(_ plan: QAExecutionPlan) -> some View {
        if let gate = model.gate, gate.canPrepare, let at = gate.approvedAt {
            VStack(alignment: .leading, spacing: 6) {
                Label("Approved \(at.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.seal.fill").uiFont(size: 11.5, weight: .semibold).foregroundColor(palette.green)
                Text("Any change to the steps, players, environment or chosen branches takes the approval back.").uiFont(size: 10.5).foregroundColor(palette.textDim)
                Button("Withdraw approval") { model.withdrawApproval() }.uiFont(size: 11)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button("Approve preparation and scenario") { model.approve(acknowledgedProduction: acknowledged) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!plan.canBeApproved || (plan.isProduction && !plan.confirmations.isEmpty && !acknowledged))
                Text("Nothing is prepared and nothing is run before you approve.").uiFont(size: 10.5).foregroundColor(palette.textDim)
            }
        }
    }

    /// Starting the check, once the plan is approved: what to record and how closely to review the screens, then the button.
    @ViewBuilder private var start: some View {
        if let gate = model.gate, gate.canPrepare {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if scenario.appKind == .api {
                    Text("Requests, status codes, response checks and timings are saved in the run report.").uiFont(size: 10.5).foregroundColor(palette.textDim)
                } else {
                    Toggle("Record a video with subtitles", isOn: Binding(get: { run.recordVideo }, set: { run.recordVideo = $0 }))
                        .toggleStyle(.checkbox).uiFont(size: 11)
                        .help("The video shows the players side by side; a band below says what is done, where and why")
                    HStack {
                        Text("Review the screens").uiFont(size: 11)
                        Spacer()
                        Picker("", selection: Binding(get: { run.reviewDepth }, set: { run.reviewDepth = $0 })) {
                            ForEach(QARunModel.ReviewDepth.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 150)
                    }
                    .help("After a step the assistant looks at the screen and says what could be better: layout, fonts, missing or superfluous controls, extra stages")
                }
                if scenario.appKind == .nativeMacOS {
                    QANativePermissionsView(status: permissions, refresh: { permissions = QANativePermissions.current })
                }
                if run.isRunning {
                    Button("Show the run") { run.show() }
                } else {
                    HStack {
                        Button("Start the check") { run.show(); model.startRun() }.buttonStyle(.borderedProminent)
                            .disabled(scenario.appKind == .nativeMacOS && permissions != .granted)
                        if run.phase == .finished && run.scenario?.id == scenario.id {
                            Button("Show the last run") { run.show() }
                        }
                    }
                }
            }
        }
    }

    private func icon(_ kind: QAPreparationStep.Kind) -> String {
        switch kind {
        case .login: return "person.crop.circle.badge.checkmark"
        case .createAccount: return "person.crop.circle.badge.plus"
        case .baseline: return "arrow.counterclockwise"
        case .condition: return "bolt.horizontal"
        }
    }
}

// MARK: - The generation sheet

struct QAGenerateSheet: View {
    @Environment(\.palette) private var palette
    @ObservedObject var model: QAModel
    @Binding var isPresented: Bool
    @State private var goal = ""
    @State private var editorFocused = false
    @State private var attachments: [URL] = []
    @State private var problem: String?
    /// The scenario the new one starts from; nil writes one from nothing.
    @State private var baseID: String?
    @State private var kind: QAAppKind = .web
    @State private var apps: [QAApp] = [QAApp(id: "app1", name: "")]
    @State private var players = ""

    init(model: QAModel, isPresented: Binding<Bool>, baseID: String? = nil) {
        self.model = model
        _isPresented = isPresented
        _baseID = State(initialValue: baseID)
        if let base = model.scenarios.first(where: { $0.id == baseID }) {
            _kind = State(initialValue: base.appKind)
            _apps = State(initialValue: base.apps.isEmpty ? [QAApp(id: "app1", name: "")] : base.apps)
            _players = State(initialValue: base.actors.map(\.name).joined(separator: ", "))
        }
    }

    private var base: QAScenario? { model.scenarios.first { $0.id == baseID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New scenario").uiFont(size: 15, weight: .semibold)
            Text("Assistant: \(model.isGenerating ? model.generationAssistant : model.assistantSummary)")
                .uiFont(size: 11).foregroundColor(palette.textDim)
            if !model.scenarios.isEmpty {
                Picker("Based on", selection: $baseID) {
                    Text("Nothing: write it from the goal").tag(String?.none)
                    ForEach(model.scenarios) { scenario in
                        Text(scenario.title.isEmpty ? scenario.id : scenario.title).tag(Optional(scenario.id))
                    }
                }
                .onChange(of: baseID) { _ in useBase() }
                .help("Start from a scenario that is alike: the assistant keeps it and changes what you write below")
            }
            Text(base == nil
                 ? "What should a person be able to do? Say who takes part and which applications are involved. The assistant writes the steps, the alternatives and the failures."
                 : "What should be different from “\(base?.title ?? "")”? The assistant keeps its steps and changes what you write here. The original stays as it is.")
                .uiFont(size: 11.5).foregroundColor(palette.textDim)
            DictationInput(text: $goal, isFocused: { editorFocused }) { voice in
                VStack(alignment: .leading, spacing: 4) {
                    IntakeTextEditor(text: $goal, focused: $editorFocused, attach: { urls in
                        attachments += urls.filter { !attachments.contains($0) }
                    }, failed: { problem = $0 })
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(voice.isRecording ? palette.red : palette.border, lineWidth: voice.isRecording ? 2 : 1))
                        .overlay(alignment: .bottomTrailing) { voice.mic().padding(6) }
                    voice.status
                }
            }
            IntakeAttachmentBar(attachments: $attachments, projectRoot: model.root,
                                hint: "screens, designs, specifications: paste images with ⌘V or drop files")
            if let problem { Text(problem).uiFont(size: 11).foregroundColor(palette.red).textSelection(.enabled) }
            Picker("Applications are", selection: $kind) {
                Text("Web").tag(QAAppKind.web)
                Text("Native macOS").tag(QAAppKind.nativeMacOS)
                Text("HTTP API").tag(QAAppKind.api)
            }
            .pickerStyle(.segmented)
            if kind == .api {
                Text("Describe the backend flow. Attach an OpenAPI/Swagger file or API documentation; the assistant also reads the project's routes and tests. It proposes requests and response checks for you to review before running.")
                    .uiFont(size: 11).foregroundColor(palette.textDim)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Applications").uiFont(size: 11.5, weight: .semibold)
                    Spacer()
                    Button { addApp() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).disabled(apps.count >= QAGeneration.maxApps)
                }
                ForEach($apps) { $app in
                    HStack {
                        TextField(apps.count == 1 ? "Name (optional)" : "Name, for example Customer app", text: $app.name).textFieldStyle(.roundedBorder)
                        Picker("", selection: $app.profile) {
                            ForEach(QAReviewProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                        .help("A user-facing application is judged on looks and readiness, an administration application on speed and automation")
                        if apps.count > 1 {
                            Button { apps.removeAll { $0.id == app.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Players (optional)").uiFont(size: 11.5, weight: .semibold)
                TextField("One per line or separated by commas, for example Buyer, Seller, Courier", text: $players, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
            }
            progress
            HStack {
                Spacer()
                Button("Cancel") { if model.isGenerating { model.cancelGeneration() }; isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Write scenario") { start() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isGenerating)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onChange(of: model.phase) { phase in
            // The sheet closes when the scenario has been written.
            if phase == .idle, started { isPresented = false }
        }
    }

    @State private var started = false

    @ViewBuilder private var progress: some View {
        switch model.phase {
        case .generating(let attempt, let activity):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    // The clock runs even when the assistant says nothing for a while.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = model.generationStarted.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
                        Text("\(attempt > 1 ? "Try \(attempt): " : "")\(activity) · \(DictationStatusView.clock(seconds))")
                            .uiFont(size: 11).foregroundColor(palette.textDim)
                    }
                }
                Text("The assistant reads the project and attached files first. There is no time limit; Cancel stops generation.")
                    .uiFont(size: 10).foregroundColor(palette.textDim)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").uiFont(size: 11).foregroundColor(palette.red)
        case .idle:
            EmptyView()
        }
    }

    private func addApp() {
        var number = apps.count + 1
        while apps.contains(where: { $0.id == "app\(number)" }) { number += 1 }
        apps.append(QAApp(id: "app\(number)", name: ""))
    }

    private func start() {
        model.dismissFailure()
        let named: [QAApp] = apps.enumerated().map { index, app in
            var app = app
            app.name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if app.name.isEmpty { app.name = apps.count == 1 ? "Application" : "Application \(index + 1)" }
            return app
        }
        let names = players.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        started = true
        var request = QAGenerationRequest(goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), appKind: kind, apps: named, actorNames: names, now: Date())
        request.base = base
        request.targets = base?.targets ?? []
        request.attachments = attachments
        model.generate(request)
    }

    /// Choosing a scenario to start from takes its kind, applications and players, which the person can still change.
    private func useBase() {
        guard let base else { return }
        kind = base.appKind
        apps = base.apps.isEmpty ? [QAApp(id: "app1", name: "")] : base.apps
        players = base.actors.map(\.name).joined(separator: ", ")
    }
}


/// Wheel, trackpad scroll and pinch over the graph: the wheel zooms around the cursor, ⇧+wheel moves the graph and a pinch zooms (as in the
/// canvas and image viewers). The view takes no clicks; it listens to the scroll events that fall inside it.
private struct QAGraphWheel: NSViewRepresentable {
    var onZoom: (CGPoint, CGFloat) -> Void
    var onPan: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> QAGraphWheelView {
        let view = QAGraphWheelView()
        view.onZoom = onZoom
        view.onPan = onPan
        return view
    }

    func updateNSView(_ view: QAGraphWheelView, context: Context) {
        view.onZoom = onZoom
        view.onPan = onPan
    }
}

final class QAGraphWheelView: NSView {
    var onZoom: ((CGPoint, CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    private var monitor: Any?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return event }
        if event.type == .magnify {
            onZoom?(point, 1 + event.magnification)
            return nil
        }
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.shift) {
            let step: CGFloat = precise ? 1 : 12
            onPan?(event.scrollingDeltaX * step, event.scrollingDeltaY * step)
            return nil
        }
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return nil }
        onZoom?(point, exp(delta * (precise ? 0.01 : 0.08)))
        return nil
    }
}


// MARK: - Adding a login

/// A sign-in being typed for a player. The password is held in memory only until it is saved or the form is closed.
struct QALoginDraft: Identifiable, Equatable {
    let id = UUID()
    var actor: String
    var host: String
    var username = ""
    var password = ""
}

/// Host, user name and password of a login. It saves into the browser's Keychain store through `save`; a scenario keeps only host and user name.
struct QALoginForm: View {
    @Environment(\.palette) private var palette
    @State var draft: QALoginDraft
    let onCancel: () -> Void
    /// Returns false when the Keychain refused the login.
    let save: (String, String, String) async -> Bool
    @State private var saving = false
    @State private var failed = false

    private var host: String? { PasswordRules.host(fromInput: draft.host) }
    private var valid: Bool { host != nil && !draft.username.isEmpty && !draft.password.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a login").uiFont(size: 12, weight: .semibold)
            TextField("Site, e.g. dev.example.com", text: $draft.host).textFieldStyle(.roundedBorder)
            TextField("User name", text: $draft.username).textFieldStyle(.roundedBorder).textContentType(.username)
            SecureField("Password", text: $draft.password).textFieldStyle(.roundedBorder).textContentType(.password)
            if !draft.host.isEmpty, host == nil {
                Text("That is not a site address.").uiFont(size: 10).foregroundColor(palette.red)
            }
            if failed {
                Text("The Keychain did not accept this login.").uiFont(size: 10).foregroundColor(palette.red)
            }
            Text("Saved in the macOS Keychain with the browser's passwords. The scenario keeps only the site and the user name.")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { submit() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!valid || saving)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func submit() {
        guard let host, valid else { return }
        saving = true; failed = false
        let username = draft.username, password = draft.password
        Task {
            let saved = await save(host, username, password)
            saving = false
            failed = !saved
        }
    }
}
