import SwiftUI

// End-to-End QA (feature end-to-end-qa): the scenario list, the graph editor and the generation sheet. The graph is native SwiftUI over
// QAGraphLayout (a pure layered layout), so it needs no bridge to the web editor. Every edit goes through QAModel, which saves it.

// MARK: - The tab

struct QATabView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var model: QAModel
    @State private var showGenerate = false
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
        .sheet(isPresented: $showGenerate) {
            QAGenerateSheet(model: model, isPresented: $showGenerate)
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
        .contextMenu { Button("Delete…", role: .destructive) { confirmDelete = scenario.id } }
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

struct QAEditorView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var model: QAModel
    let wide: Bool
    private enum Panel: Hashable { case branches, step, setup }
    @State private var panel: Panel = .branches

    var body: some View {
        if let scenario = model.current {
            VStack(spacing: 0) {
                header(scenario)
                Divider()
                if wide {
                    HSplitView {
                        VStack(spacing: 0) {
                            QAGraphCanvas(model: model, scenario: scenario)
                            Divider()
                            QABranchList(model: model, scenario: scenario).frame(height: 190)
                        }
                        .frame(minWidth: 380)
                        QAInspector(model: model, scenario: scenario, part: .all).frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                    }
                } else {
                    QAGraphCanvas(model: model, scenario: scenario)
                    Divider()
                    Picker("", selection: $panel) {
                        Text("Branches").tag(Panel.branches)
                        Text("Step").tag(Panel.step)
                        Text("Applications and players").tag(Panel.setup)
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.vertical, 6)
                    Group {
                        switch panel {
                        case .branches: QABranchList(model: model, scenario: scenario)
                        case .step: QAInspector(model: model, scenario: scenario, part: .step)
                        case .setup: QAInspector(model: model, scenario: scenario, part: .setup)
                        }
                    }
                    .frame(height: 250)
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
                Picker("", selection: Binding(get: { scenario.appKind }, set: { value in model.edit { $0.appKind = value } })) {
                    Text("Web").tag(QAAppKind.web)
                    Text("macOS app").tag(QAAppKind.nativeMacOS)
                }
                .pickerStyle(.segmented).frame(width: 170).labelsHidden()
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

    private static let space = "qa-graph"
    private static let zoomRange: ClosedRange<CGFloat> = 0.3...1.6

    var body: some View {
        let layout = QAGraphLayout.make(scenario)
        let lit = litNodes
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
                let fit = max(Self.zoomRange.lowerBound, min(1, (geometry.size.width - 12) / max(1, layout.size.width), (geometry.size.height - 12) / max(1, layout.size.height)))
                // Fitting shrinks the graph to the area but never below a size that can be read; a bigger graph scrolls.
                let scale = zoom ?? max(0.6, fit)
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in draw(&context, layout, lit: lit) }
                            .frame(width: layout.size.width, height: layout.size.height)
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                if let node = layout.node(at: tap.location) { model.selectedNode = node.id; model.selectedEdge = nil }
                                else if let edge = layout.edge(near: tap.location) {
                                    model.selectedEdge = QAEdge(from: edge.from, to: edge.to, label: edge.label); model.selectedNode = nil
                                } else { model.selectedNode = nil; model.selectedEdge = nil }
                            })
                        ForEach(layout.nodes) { node in nodeView(node, layout: layout, lit: lit) }
                    }
                    .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                    .coordinateSpace(name: Self.space)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
                    .padding(6)
                }
                .overlay(alignment: .bottomTrailing) { zoomControls(scale: scale) }
            }
            .background(palette.bg)
        }
    }

    private func zoomControls(scale: CGFloat) -> some View {
        HStack(spacing: 2) {
            Button { zoom = max(Self.zoomRange.lowerBound, scale - 0.15) } label: { Image(systemName: "minus") }.help("Zoom out")
            Button { zoom = nil } label: { Text("\(Int((scale * 100).rounded()))%").frame(minWidth: 34) }.help("Fit the whole graph")
            Button { zoom = min(Self.zoomRange.upperBound, scale + 0.15) } label: { Image(systemName: "plus") }.help("Zoom in")
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
                Text("Drag from one step to another to connect them").uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1).fixedSize()
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
    @State private var showApps = true
    @State private var showPlayers = true
    enum Part { case all, step, setup }
    let part: Part

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if part != .setup {
                    if let id = model.selectedNode, let node = scenario.node(id) {
                        nodeSection(node)
                    } else if let edge = model.selectedEdge {
                        edgeSection(edge)
                    } else if part == .step {
                        Text("Select a step or a connection in the graph to edit it.").uiFont(size: 11).foregroundColor(palette.textDim)
                    }
                }
                if part != .step {
                    DisclosureGroup(isExpanded: $showApps) { appsSection.padding(.top, 6) } label: { heading("Applications (\(scenario.apps.count))") }
                    DisclosureGroup(isExpanded: $showPlayers) { actorsSection.padding(.top, 6) } label: { heading("Players (\(scenario.actors.count))") }
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
                Text("How to set it up").uiFont(size: 10.5).foregroundColor(palette.textDim)
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
                        Picker("", selection: Binding(get: { app.profile }, set: { value in model.edit { s in if let i = s.apps.firstIndex(where: { $0.id == app.id }) { s.apps[i].profile = value } } })) {
                            ForEach(QAReviewProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                        .help("What this application is reviewed against")
                        if scenario.apps.count > 1 {
                            Button { removeApp(app.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                                .help("Remove this application")
                        }
                    }
                    TextEditor(text: Binding(get: { app.requirements.isEmpty ? app.profile.presetRequirements : app.requirements },
                                             set: { value in model.edit { s in if let i = s.apps.firstIndex(where: { $0.id == app.id }) { s.apps[i].requirements = value == app.profile.presetRequirements ? "" : value } } }))
                        .uiFont(size: 10.5).frame(height: 84)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border))
                }
            }
        }
    }

    private var actorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button { addActor() } label: { Label("Add player", systemImage: "plus") }.buttonStyle(.borderless).uiFont(size: 11)
                    .disabled(scenario.actors.count >= QAGeneration.maxActors)
            }
            ForEach(scenario.actors) { actor in
                HStack {
                    TextField("Name", text: Binding(get: { actor.name }, set: { value in model.edit { s in if let i = s.actors.firstIndex(where: { $0.id == actor.id }) { s.actors[i].name = value } } }))
                        .textFieldStyle(.roundedBorder)
                    if scenario.apps.count > 1 {
                        Picker("", selection: Binding(get: { actor.app ?? "" }, set: { value in model.edit { s in if let i = s.actors.firstIndex(where: { $0.id == actor.id }) { s.actors[i].app = value.isEmpty ? nil : value } } })) {
                            Text("—").tag("")
                            ForEach(scenario.apps) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 130)
                        .help("The application this player uses")
                    }
                    Button { removeActor(actor.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        .disabled(scenario.nodes.contains { $0.actor == actor.id })
                        .help(scenario.nodes.contains { $0.actor == actor.id } ? "This player has steps" : "Remove this player")
                }
            }
        }
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

// MARK: - The generation sheet

struct QAGenerateSheet: View {
    @Environment(\.palette) private var palette
    @ObservedObject var model: QAModel
    @Binding var isPresented: Bool
    @State private var goal = ""
    @State private var kind: QAAppKind = .web
    @State private var apps: [QAApp] = [QAApp(id: "app1", name: "")]
    @State private var players = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New scenario").uiFont(size: 15, weight: .semibold)
            Text("What should a person be able to do? Say who takes part and which applications are involved. The assistant writes the steps, the alternatives and the failures.")
                .uiFont(size: 11.5).foregroundColor(palette.textDim)
            TextEditor(text: $goal).uiFont(size: 12).frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border))
            Picker("Applications are", selection: $kind) {
                Text("Web").tag(QAAppKind.web)
                Text("Native macOS").tag(QAAppKind.nativeMacOS)
            }
            .pickerStyle(.segmented)
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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(attempt > 1 ? "Try \(attempt): " : "")\(activity)").uiFont(size: 11).foregroundColor(palette.textDim)
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
        model.generate(QAGenerationRequest(goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), appKind: kind, apps: named, actorNames: names, now: Date()))
    }
}
