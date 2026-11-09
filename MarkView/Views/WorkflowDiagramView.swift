import AppKit
import SwiftUI

/// Which transition table the diagram edits: the one of a work-item type, or the own one of a process.
enum WorkflowScope: Hashable {
    case type(IssueKind)
    case process(String)
}

/// The transitions of a type, or of a process with its own, as an editable state diagram (BUG-112). Every status is a state and every
/// transition an arrow (the geometry is `WorkflowDiagram`); the diagram edits the draft of the Workflow tab and nothing else, so what
/// is stored does not change. Click a state to rename it, give it another role or remove it, and to see the arrows into and out of
/// it; click an arrow to change where it starts and ends, its kind and what each actor needs; drag from one state to another to draw
/// an arrow. A process changes only its arrows: its states are those of its type.
struct WorkflowTransitionsEditor: View {
    @Environment(\.palette) private var palette
    @ObservedObject var editor: WorkflowEditorModel
    let scope: WorkflowScope

    private enum Selection: Equatable { case state(String), rule(Int) }
    private struct Pull: Equatable { var from: String; var at: CGPoint }

    @State private var selection: Selection?
    @State private var pull: Pull?
    /// The state or arrow the pointer is over.
    @State private var hover: Selection?
    /// The width the diagram may take; it is drawn at its natural size and scaled down when the window is narrower.
    @State private var available: CGFloat = 0
    @State private var newState = ""
    private static let space = "workflow-diagram"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ownsStates { addStateRow }
            legend
            diagramView
            inspector
            unattachedRules
            Button { addRule() } label: { Label("Add a transition", systemImage: "plus") }
                .buttonStyle(.plain).foregroundColor(palette.blue).uiFont(size: 11)
                .help("Adds a transition and opens it for editing. You can also drag from one state to another.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { available = proxy.size.width }
                .onChange(of: proxy.size.width) { available = $0 }
        })
        .onChange(of: rules.count) { _ in keepSelectionValid() }
    }

    // MARK: Draft access

    private var kind: IssueKind {
        switch scope {
        case .type(let kind): return kind
        case .process(let id): return editor.draft.variant(id)?.kind ?? .feature
        }
    }

    private var ownsStates: Bool {
        if case .type = scope { return true }
        return false
    }

    private var statuses: [WorkflowStatus] { editor.draft.lifecycle(kind).statuses }

    private var rules: [LifecycleRule] {
        switch scope {
        case .type(let kind): return editor.draft.lifecycle(kind).rules
        case .process(let id): return editor.draft.variant(id)?.rules ?? []
        }
    }

    private func setRules(_ rules: [LifecycleRule]) {
        switch scope {
        case .type(let kind):
            var current = editor.draft.lifecycle(kind)
            current.rules = rules
            editor.draft.setLifecycle(kind, current)
        case .process(let id):
            guard let index = editor.draft.variants.firstIndex(where: { $0.id == id }) else { return }
            editor.draft.variants[index].rules = rules
        }
    }

    // A selection can outlive what it points at (a state or a transition removed from the source view, or by removing a state), so
    // every binding checks that its target still exists: a stale one reads a blank value and writes nothing.

    private static let blankRule = LifecycleRule(from: [], to: "", kind: .spec, needs: [:])

    private func ruleBinding(_ index: Int) -> Binding<LifecycleRule> {
        Binding(get: {
            let all = rules
            return all.indices.contains(index) ? all[index] : Self.blankRule
        }, set: { value in
            var all = rules
            guard all.indices.contains(index) else { return }
            all[index] = value
            setRules(all)
        })
    }

    private func statusBinding(_ id: String) -> Binding<WorkflowStatus> {
        Binding(get: {
            statuses.first { $0.id == id } ?? WorkflowStatus(id: id, role: .notStarted)
        }, set: { value in
            var current = editor.draft.lifecycle(kind)
            guard let index = current.statuses.firstIndex(where: { $0.id == id }) else { return }
            current.statuses[index] = value
            editor.draft.setLifecycle(kind, current)
        })
    }

    private func title(of id: String) -> String { statuses.first { $0.id == id }?.title ?? id }

    private func keepSelectionValid() {
        switch selection {
        case .rule(let index)?: if !rules.indices.contains(index) { selection = nil }
        case .state(let id)?: if !statuses.contains(where: { $0.id == id }) { selection = nil }
        case nil: break
        }
    }

    // MARK: Colours

    private func roleColor(_ role: LifecycleRole) -> Color {
        switch role {
        case .notStarted: return palette.textDim
        case .active: return palette.blue
        case .completed: return palette.green
        case .cancelled: return palette.orange
        }
    }

    private func kindColor(_ kind: TransitionKind) -> Color {
        switch kind {
        case .spec: return palette.purple
        case .start: return palette.blue
        case .completion: return palette.green
        case .acceptance: return palette.cyan
        case .reopen: return palette.red
        case .rollback: return palette.yellow
        case .cancellation: return palette.orange
        default: return palette.textDim
        }
    }

    private static let kindOrder: [TransitionKind] = [.spec, .start, .completion, .acceptance, .rollback, .reopen, .cancellation]

    // MARK: Diagram

    private var legend: some View {
        let used = Self.kindOrder.filter { kind in rules.contains { $0.kind == kind } }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(used, id: \.self) { kind in
                HStack(spacing: 4) {
                    Capsule().fill(kindColor(kind)).frame(width: 14, height: 3)
                    Text(kind.editorTitle).uiFont(size: 10).foregroundColor(palette.textDim)
                }
            }
        }
    }

    private var diagramView: some View {
        let width = available > 0 ? available : 760
        // The diagram grows with the tab, and is cut down to fit a narrow one: every length, text size and line width follows the zoom.
        let zoom = WorkflowDiagram.zoom(statuses: statuses, rules: rules, available: width)
        let diagram = WorkflowDiagram(statuses: statuses, rules: rules, width: width, metrics: WorkflowDiagram.Metrics(zoom: zoom))
        // What the pointer is over lights up as a selection does, so the path of a transition can be followed without a click.
        let focus = hover ?? selection
        let involved = involvedStates(focus)
        // The drawing is an overlay of an empty box that takes the width it is given: its own width must not ask the tab for more
        // room than the window has (the tab could then never be narrower than the diagram).
        return Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: diagram.size.height)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in draw(&context, diagram, focus: focus) }
                        .frame(width: diagram.size.width, height: diagram.size.height)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { tap in
                            if let rule = diagram.rule(near: tap.location, tolerance: 7 * zoom) { selection = .rule(rule) } else { selection = nil }
                        })
                    ForEach(diagram.nodes) { node in
                        nodeView(node, involved: involved.contains(node.id), focused: focus == .state(node.id), diagram: diagram)
                    }
                }
                .frame(width: diagram.size.width, height: diagram.size.height, alignment: .topLeading)
                .coordinateSpace(name: Self.space)
                .onContinuousHover { phase in
                    var next: Selection?
                    if case .active(let point) = phase {
                        if let node = diagram.node(at: point) { next = .state(node.id) }
                        else if let rule = diagram.rule(near: point, tolerance: 7 * zoom) { next = .rule(rule) }
                    }
                    if hover != next { hover = next }
                }
            }
    }

    /// The states the focused transition starts from and ends at.
    private func involvedStates(_ focus: Selection?) -> Set<String> {
        guard case .rule(let index)? = focus, rules.indices.contains(index) else { return [] }
        return rules[index].from.union([rules[index].to])
    }

    private func nodeView(_ node: WorkflowDiagram.Node, involved: Bool, focused: Bool, diagram: WorkflowDiagram) -> some View {
        let zoom = diagram.metrics.zoom
        let selected = selection == .state(node.id)
        let color = roleColor(node.role)
        let target = pull.flatMap { diagram.node(at: $0.at) }?.id == node.id && pull?.from != node.id
        let lit = selected || target
        return Text(node.title).uiFont(size: 11.5 * zoom, weight: .medium).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 8 * zoom)
            .frame(width: node.frame.width, height: node.frame.height)
            .background(RoundedRectangle(cornerRadius: 6 * zoom).fill(color.opacity(0.18)))
            .background(RoundedRectangle(cornerRadius: 6 * zoom).fill(palette.bg))
            .overlay(RoundedRectangle(cornerRadius: 6 * zoom).stroke(lit ? palette.accent : (focused || involved ? color : color.opacity(0.55)),
                                                                    lineWidth: (lit ? 2 : (focused || involved ? 1.6 : 1)) * max(1, zoom)))
            .contentShape(Rectangle())
            .onTapGesture { selection = .state(node.id) }
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
                .onChanged { pull = Pull(from: node.id, at: $0.location) }
                .onEnded { value in
                    pull = nil
                    guard let end = diagram.node(at: value.location), end.id != node.id else { return }
                    var all = rules
                    if let index = WorkflowDiagram.connect(node.id, end.id, statuses: statuses, rules: &all) {
                        setRules(all)
                        selection = .rule(index)
                    }
                })
            .help(node.id)
            .accessibilityLabel(Text(node.title))
            .offset(x: node.frame.minX, y: node.frame.minY)
    }

    private func draw(_ context: inout GraphicsContext, _ diagram: WorkflowDiagram, focus: Selection?) {
        let zoom = diagram.metrics.zoom
        for lane in diagram.lanes {
            let frame = Path(roundedRect: lane.frame, cornerRadius: 8 * zoom)
            context.fill(frame, with: .color(palette.bgInput.opacity(0.55)))
            context.stroke(frame, with: .color(palette.border), lineWidth: 1)
            context.draw(Text(lane.role.title).font(.system(size: 11.5 * zoom, weight: .semibold)).foregroundColor(roleColor(lane.role)),
                         at: CGPoint(x: lane.frame.minX + 12 * zoom, y: 15 * zoom), anchor: .leading)
            if let bar = lane.bar {
                let color = kindColor(lane.entryRules.first.flatMap { rules.indices.contains($0) ? rules[$0].kind : nil } ?? .spec)
                var line = Path()
                line.move(to: CGPoint(x: lane.frame.minX + diagram.metrics.barInset, y: bar.lowerBound))
                line.addLine(to: CGPoint(x: lane.frame.minX + diagram.metrics.barInset, y: bar.upperBound))
                context.stroke(line, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 3.5 * zoom, lineCap: .round))
                if lane.isClique {
                    context.draw(Text("any order").font(.system(size: 10.5 * zoom, weight: .medium)).foregroundColor(color),
                                 at: CGPoint(x: lane.frame.maxX - 10 * zoom, y: 15 * zoom), anchor: .trailing)
                }
            }
        }
        // Focusing a state lights the arrows into and out of it; focusing an arrow lights that one. The lit ones are drawn last, over the others.
        var lit: Set<Int> = []
        switch focus {
        case .rule(let index)?: lit = [index]
        case .state(let id)?: lit = Set(rules.indices.filter { rules[$0].to == id || rules[$0].from.contains(id) })
        case nil: break
        }
        for arrow in diagram.arrows.sorted(by: { (lit.contains($0.rule) ? 1 : 0) < (lit.contains($1.rule) ? 1 : 0) }) {
            // The name of the step and who moves it ("Completion · automatic"), not the name of the step alone (BUG-115).
            let label = rules.indices.contains(arrow.rule) ? TransitionStory.make(rules[arrow.rule], processes: []).label : arrow.kind.editorTitle
            drawArrow(&context, arrow, label: label, zoom: zoom, selected: lit.contains(arrow.rule), dimmed: !lit.isEmpty && !lit.contains(arrow.rule))
        }
        if let pull, let from = diagram.nodes.first(where: { $0.id == pull.from }) {
            var line = Path()
            line.move(to: CGPoint(x: from.frame.midX, y: from.frame.midY))
            line.addLine(to: pull.at)
            context.stroke(line, with: .color(palette.accent), style: StrokeStyle(lineWidth: 2 * zoom, lineCap: .round, dash: [5 * zoom, 4 * zoom]))
        }
    }

    private func drawArrow(_ context: inout GraphicsContext, _ arrow: WorkflowDiagram.Arrow, label text: String, zoom: CGFloat, selected: Bool, dimmed: Bool) {
        let color = kindColor(arrow.kind).opacity(selected ? 1 : (dimmed ? 0.2 : 0.85))
        let width: CGFloat = (selected ? 3.4 : 2) * zoom
        for branch in arrow.branches {
            var path = Path()
            for tail in branch.tails { path.addLines(tail) }
            path.addLines(branch.stub)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            let direction: CGFloat = branch.pointsRight ? 1 : -1
            var head = Path()
            head.move(to: branch.tip)
            head.addLine(to: CGPoint(x: branch.tip.x - direction * 10 * zoom, y: branch.tip.y - 5 * zoom))
            head.addLine(to: CGPoint(x: branch.tip.x - direction * 10 * zoom, y: branch.tip.y + 5 * zoom))
            head.closeSubpath()
            context.fill(head, with: .color(color))
            if !branch.isEntry {
                // The name sits on a plate of the page's colour so that the curves that cross it do not cut it up.
                let label = context.resolve(Text(text).font(.system(size: 10.5 * zoom, weight: selected ? .bold : .medium)).foregroundColor(color))
                let size = label.measure(in: CGSize(width: 240 * zoom, height: 24 * zoom))
                let origin = CGPoint(x: branch.pointsRight ? branch.tip.x - 5 * zoom - size.width : branch.tip.x + 5 * zoom,
                                     y: branch.tip.y - 4 * zoom - size.height)
                context.fill(Path(roundedRect: CGRect(origin: origin, size: size).insetBy(dx: -3 * zoom, dy: -1.5 * zoom), cornerRadius: 3 * zoom),
                             with: .color(palette.bg.opacity(0.88)))
                context.draw(label, at: origin, anchor: .topLeading)
            }
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        switch selection {
        case .state(let id)?:
            if statuses.contains(where: { $0.id == id }) { stateInspector(id) }
        case .rule(let index)?:
            if rules.indices.contains(index) { ruleInspector(index) }
        case nil:
            Text(editor.page == .processes
                 ? "Point at a state or an arrow to light its path. Click an arrow to see what makes the step happen and to change it, or a state to see the arrows into and out of it. Drag from one state to another to add an arrow. “automatic” on an arrow: MarkView moves the item by itself when the event happens."
                 : "Point at a state or an arrow to light its path. Click a state to rename it or change its role, an arrow to see what makes the step happen, who may make it and on what evidence. Drag from one state to another to add an arrow. “automatic” on an arrow: MarkView moves the item by itself when the event happens.")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stateInspector(_ id: String) -> some View {
        let into = rules.indices.filter { rules[$0].to == id }
        let out = rules.indices.filter { rules[$0].from.contains(id) }
        return VStack(alignment: .leading, spacing: 6) {
            if ownsStates {
                HStack(spacing: 8) {
                    TextField("Title", text: statusBinding(id).title).textFieldStyle(.roundedBorder)
                        .frame(minWidth: 80, idealWidth: 190, maxWidth: 260)
                    Picker("", selection: statusBinding(id).role) {
                        ForEach(LifecycleRole.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 120)
                    Spacer(minLength: 0)
                    Button { removeState(id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).help("Remove this state and the arrows that end there or start only there. Work items in it are moved to a status you choose when you save.")
                }
                Text(id).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim).lineLimit(1).truncationMode(.middle)
                    .help("The stored id of this status. It cannot be renamed: add the new state and remove the old one.")
            } else {
                Text(title(of: id)).uiFont(size: 11, weight: .semibold)
                Text("The states of a process are those of its type. Change them on the \(kind == .feature ? "Features" : "Bugs") page.")
                    .uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            ruleList("Arrows into this state", into)
            ruleList("Arrows out of this state", out)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
    }

    @ViewBuilder
    private func ruleList(_ heading: String, _ indices: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading).uiFont(size: 10, weight: .semibold).foregroundColor(palette.textDim)
            if indices.isEmpty {
                Text("None").uiFont(size: 10).foregroundColor(palette.textDim)
            } else {
                ForEach(indices, id: \.self) { index in
                    Button { selection = .rule(index) } label: {
                        Text(summary(of: rules[index])).uiFont(size: 11).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain).foregroundColor(palette.blue).help(summary(of: rules[index]))
                }
            }
        }
    }

    /// "Start: 5 states → Implementing".
    private func summary(of rule: LifecycleRule) -> String {
        let from = rule.from.isEmpty ? "no state" : (rule.from.count == 1 ? title(of: rule.from.first ?? "") : "\(rule.from.count) states")
        return "\(rule.kind.editorTitle): \(from) → \(title(of: rule.to))"
    }

    /// The processes whose evidence this transition table decides: those of a type that follow its transitions, or the process itself.
    private var followers: [RuleVariant] {
        switch scope {
        case .type(let kind): return editor.draft.variants(for: kind).filter { $0.rules == nil }
        case .process(let id): return editor.draft.variant(id).map { [$0] } ?? []
        }
    }

    /// The card of an arrow (BUG-115): where it goes, then when it happens, who may make it, and the evidence each process asks for,
    /// with the controls that change them.
    private func ruleInspector(_ index: Int) -> some View {
        let rule = ruleBinding(index)
        let from = "From: " + (rule.wrappedValue.from.isEmpty ? "none" : statuses.filter { rule.wrappedValue.from.contains($0.id) }.map(\.title).joined(separator: ", "))
        let story = TransitionStory.make(rule.wrappedValue, processes: followers)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(statuses) { status in
                        Toggle(status.title, isOn: Binding(
                            get: { rule.wrappedValue.from.contains(status.id) },
                            set: { on in
                                if on { rule.wrappedValue.from.insert(status.id) } else { rule.wrappedValue.from.remove(status.id) }
                            }))
                    }
                } label: {
                    Text(from).lineLimit(1).truncationMode(.tail)
                }
                .controlSize(.small)
                // The menu takes what the row has left and truncates: a step that starts from every status (cancellation) names
                // them all, and a label of that length once made the whole editor wider than its window (BUG-108).
                .frame(minWidth: 50, maxWidth: .infinity, alignment: .leading)
                .help(from)
                Image(systemName: "arrow.right").foregroundColor(palette.textDim)
                Picker("", selection: rule.to) { ForEach(statuses) { Text($0.title).tag($0.id) } }
                    .labelsHidden().frame(minWidth: 80, maxWidth: 150)
                Picker("", selection: rule.kind) {
                    ForEach(Self.editableKinds, id: \.self) { Text($0.editorTitle).tag($0) }
                }
                .labelsHidden().frame(minWidth: 80, maxWidth: 130)
                Button { removeRule(index) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Remove this transition")
            }
            cardSection("When") {
                Text(story.trigger).uiFont(size: 11, weight: .medium).fixedSize(horizontal: false, vertical: true)
            }
            cardSection("Who") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(story.actors, id: \.actor) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            actorMenu(rule, line.actor, text: line.text).frame(width: 96, alignment: .leading)
                            Text(line.text).uiFont(size: 10).foregroundColor(line.allowed ? palette.text : palette.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            cardSection("Evidence") { evidence(story) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
    }

    @ViewBuilder
    private func evidence(_ story: TransitionStory) -> some View {
        if story.parts.isEmpty {
            Text("This step reads no setting of a process: only the conditions above.").uiFont(size: 10).foregroundColor(palette.textDim)
        } else if followers.isEmpty {
            Text("No process follows these transitions.").uiFont(size: 10).foregroundColor(palette.textDim)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(followers) { process in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(process.name).uiFont(size: 10, weight: .semibold)
                        ForEach(story.processes.first { $0.id == process.id }?.lines ?? [], id: \.self) { line in
                            Text("• " + line).uiFont(size: 10).fixedSize(horizontal: false, vertical: true)
                        }
                        WorkflowProcessControls(variant: editor.variantBinding(process.id), parts: story.parts)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    private func cardSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(palette.textDim).frame(width: 52, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actorMenu(_ rule: Binding<LifecycleRule>, _ actor: LifecycleActorKind, text: String) -> some View {
        let needs = rule.wrappedValue.needs[actor]
        return Menu {
            Toggle("May make this step", isOn: Binding(
                get: { rule.wrappedValue.needs[actor] != nil },
                set: { on in rule.wrappedValue.needs[actor] = on ? (rule.wrappedValue.needs[actor] ?? []) : nil }))
            Divider()
            ForEach(Self.editableConditions, id: \.self) { condition in
                Toggle(condition.words, isOn: Binding(
                    get: { rule.wrappedValue.needs[actor]?.contains(condition) == true },
                    set: { on in
                        var list = rule.wrappedValue.needs[actor] ?? []
                        list.removeAll { $0 == condition }
                        if on { list.append(condition) }
                        rule.wrappedValue.needs[actor] = list
                    }))
                .disabled(needs == nil)
            }
        } label: {
            Text(Self.actorTitle(actor)).lineLimit(1)
        }
        .controlSize(.small)
        .help(text)
    }

    private static let editableKinds: [TransitionKind] = [.spec, .start, .completion, .acceptance, .reopen, .rollback, .cancellation]
    private static let editableConditions: [LifecycleCondition] = [.startEvidence, .deliveryEvidence, .acceptanceEvidence, .regressionEvidence,
                                                                   .cancellationEvidence, .reason, .humanAcceptance]

    private static func actorTitle(_ actor: LifecycleActorKind) -> String {
        switch actor {
        case .human: return "Person"
        case .ai: return "AI"
        case .system: return "MarkView"
        }
    }

    // MARK: Transitions that have no arrow

    /// A transition without a source, or with a status the type does not have, has no arrow to click: it is edited from here.
    @ViewBuilder
    private var unattachedRules: some View {
        let diagram = WorkflowDiagram(statuses: statuses, rules: rules, width: 760)
        if !diagram.unattached.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Transitions that cannot be drawn").uiFont(size: 10, weight: .semibold).foregroundColor(palette.red)
                ForEach(diagram.unattached, id: \.self) { index in
                    Button { selection = .rule(index) } label: {
                        Text(summary(of: rules[index])).uiFont(size: 11).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain).foregroundColor(palette.blue)
                }
            }
        }
    }

    // MARK: Changes

    private var addStateRow: some View {
        HStack(spacing: 8) {
            TextField("new-status-id", text: $newState).textFieldStyle(.roundedBorder).frame(minWidth: 100, idealWidth: 190, maxWidth: 190)
            Button("Add a state") { addState() }.controlSize(.small).disabled(IssueStatus.normalize(newState).isEmpty)
            Text("Lower-case words joined by hyphens. An id cannot be renamed: add the new one and remove the old one.")
                .uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addState() {
        let id = IssueStatus.normalize(newState)
        var current = editor.draft.lifecycle(kind)
        guard !id.isEmpty, !current.isKnown(id) else { editor.message = "\(id) is already a status."; return }
        current.statuses.append(WorkflowStatus(id: id, role: .notStarted))
        editor.draft.setLifecycle(kind, current)
        newState = ""
        editor.message = nil
        selection = .state(id)
    }

    private func removeState(_ id: String) {
        let dropped = editor.draft.removeStatus(id, kind: kind)
        editor.message = dropped == 0 ? nil : "Removing \(id) also removed \(dropped) transition\(dropped == 1 ? "" : "s") that ended there or started only there."
        selection = nil
    }

    private func removeRule(_ index: Int) {
        var all = rules
        guard all.indices.contains(index) else { return }
        all.remove(at: index)
        setRules(all)
        selection = nil
    }

    private func addRule() {
        guard let first = statuses.first(where: { $0.role == .notStarted }) ?? statuses.first,
              let target = statuses.first(where: { $0.role == .active }) ?? statuses.last else { return }
        var all = rules
        let kind = WorkflowDiagram.inferredKind(from: first, to: target, statuses: statuses)
        all.append(LifecycleRule(from: [first.id], to: target.id, kind: kind, needs: WorkflowDiagram.defaultNeeds(for: kind)))
        setRules(all)
        selection = .rule(all.count - 1)
    }
}
