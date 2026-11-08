import AppKit
import SwiftUI

/// The Workflow tab of the project window (BUG-108; feature-3, REQ-001, REQ-002, REQ-005). The workflow belongs to the project, so it
/// is configured inside the project's window, not in Settings: the statuses of features and bugs with their lifecycle roles, the
/// transitions between them and the conditions each kind of actor must meet, and the processes that say how an item of a type is
/// worked on, delivered and accepted (a process may have transitions of its own, as a quick feature does). The same draft is edited
/// graphically or as the JSON of `.dde/workflow/workflow.json`. Saving is checked as a whole; a status or process that work items
/// still use is removed only after a person chose what replaces it (DEC-021).
struct WorkflowTabView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var store: FeatureStore
    @ObservedObject var editor: WorkflowEditorModel

    private var load: WorkflowLoad { store.lifecycle.workflowLoad }
    private var editable: Bool { load.isEditable && store.root != nil }
    private var problems: [WorkflowProblem] { editor.draft.validate() }

    /// Which transition table a row edits: the one of a type, or the own one of a process.
    private enum Scope: Hashable {
        case type(IssueKind)
        case process(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch editor.mode {
                case .visual: visualBody
                case .source: sourceBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(palette.bg)
        .onAppear { editor.attach(to: store) }
        .onChange(of: editor.sourceText) { _ in editor.sourceChanged() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Workflow").uiFont(size: 15, weight: .semibold)
                Text(".dde/workflow/workflow.json").uiFont(size: 10, design: .monospaced).foregroundColor(palette.textDim).lineLimit(1)
                Spacer(minLength: 8)
                Picker("", selection: Binding(get: { editor.mode }, set: { editor.switchMode($0, store: store) })) {
                    ForEach(WorkflowEditorModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            Text("How work moves in this project: the statuses of features and bugs, who may make each step and on what evidence, and the processes an item can follow. This is the authority for transitions; the Definition of Done and the project instructions only guide the work. Settings keeps the templates a process starts from.")
                .uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            if let problem = load.problem {
                Text(problem).uiFont(size: 11).foregroundColor(palette.red).fixedSize(horizontal: false, vertical: true)
            }
            if editor.mode == .visual {
                HStack(spacing: 8) {
                    Text("Name").uiFont(size: 11)
                    TextField("Workflow name", text: $editor.draft.name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Spacer(minLength: 0)
                    Text("Revision \(editor.draft.revision)").uiFont(size: 10).foregroundColor(palette.textDim)
                }
                Picker("", selection: $editor.page) {
                    ForEach(WorkflowEditorModel.Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .padding(16)
    }

    // MARK: Views

    private var visualBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch editor.page {
                case .features: lifecycleEditor(.feature)
                case .bugs: lifecycleEditor(.bug)
                case .processes: processesEditor
                }
                if !editor.impact.isEmpty { impactEditor }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .disabled(!editable)
    }

    private var sourceBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(editable
                 ? "The workflow as JSON. It follows what you type while it is valid; the graphical view shows the same draft."
                 : "The file as it is on disk. Repair it outside MarkView, then use “Reload from file”.")
                .uiFont(size: 10).foregroundColor(palette.textDim)
            WorkflowSourceEditor(text: $editor.sourceText, editable: editable)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border))
            if let error = editor.sourceError {
                Text("The text is not a workflow: " + error).uiFont(size: 10).foregroundColor(palette.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    // MARK: Draft access

    private static let blankRule = LifecycleRule(from: [], to: "", kind: .spec, needs: [:])

    private func kind(of scope: Scope) -> IssueKind {
        switch scope {
        case .type(let kind): return kind
        case .process(let id): return editor.draft.variant(id)?.kind ?? .feature
        }
    }

    private func rules(of scope: Scope) -> [LifecycleRule] {
        switch scope {
        case .type(let kind): return editor.draft.lifecycle(kind).rules
        case .process(let id): return editor.draft.variant(id)?.rules ?? []
        }
    }

    private func setRules(_ rules: [LifecycleRule], of scope: Scope) {
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

    // The rows are drawn from the draft while a row may just have been removed, so every binding checks its row still exists: a
    // stale row reads a blank value and writes nothing instead of failing on an index that is gone.

    private func ruleBinding(_ scope: Scope, _ index: Int) -> Binding<LifecycleRule> {
        Binding(get: {
            let all = rules(of: scope)
            return all.indices.contains(index) ? all[index] : Self.blankRule
        }, set: { value in
            var all = rules(of: scope)
            guard all.indices.contains(index) else { return }
            all[index] = value
            setRules(all, of: scope)
        })
    }

    private func statusBinding(_ kind: IssueKind, _ id: String) -> Binding<WorkflowStatus> {
        Binding(get: {
            editor.draft.lifecycle(kind).statuses.first { $0.id == id } ?? WorkflowStatus(id: id, role: .notStarted)
        }, set: { value in
            var current = editor.draft.lifecycle(kind)
            guard let index = current.statuses.firstIndex(where: { $0.id == id }) else { return }
            current.statuses[index] = value
            editor.draft.setLifecycle(kind, current)
        })
    }

    // MARK: Statuses and transitions of a type

    private func lifecycleEditor(_ kind: IssueKind) -> some View {
        let definition = editor.draft.lifecycle(kind)
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Statuses", "The statuses every \(kind.rawValue) process shares. The role tells the rest of MarkView what a status means: completion, reopening, progress and GitHub follow roles, not names. A role alone never proves delivery.")
            ForEach(definition.statuses) { status in
                HStack(spacing: 8) {
                    Text(status.id).uiFont(size: 11, design: .monospaced).lineLimit(1).truncationMode(.middle)
                        .frame(minWidth: 60, idealWidth: 130, maxWidth: 130, alignment: .leading).help(status.id)
                    TextField("Title", text: statusBinding(kind, status.id).title).textFieldStyle(.roundedBorder)
                        .frame(minWidth: 80, idealWidth: 190, maxWidth: 260)
                    Picker("", selection: statusBinding(kind, status.id).role) {
                        ForEach(LifecycleRole.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 120)
                    Spacer(minLength: 0)
                    Button { removeStatus(status.id, kind) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).help("Remove this status. Work items in it are moved to a status you choose when you save.")
                }
            }
            HStack(spacing: 8) {
                TextField("new-status-id", text: $editor.newStatus).textFieldStyle(.roundedBorder).frame(minWidth: 100, idealWidth: 190, maxWidth: 190)
                Button("Add status") { addStatus(kind) }.controlSize(.small).disabled(IssueStatus.normalize(editor.newStatus).isEmpty)
                Text("Lower-case words joined by hyphens. An id cannot be renamed: add the new one and remove the old one.")
                    .uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            sectionTitle("Transitions", "Who may move an item from a status to another and what each must have, for the processes that follow the transitions of the type. A step no one is listed for is not offered; only a person can force it, with a reason.")
            transitionRows(.type(kind))
        }
    }

    private func transitionRows(_ scope: Scope) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<rules(of: scope).count, id: \.self) { index in
                ruleRow(scope, index)
            }
            Button { addRule(scope) } label: { Label("Add a transition", systemImage: "plus") }
                .buttonStyle(.plain).foregroundColor(palette.blue).uiFont(size: 11)
        }
    }

    private func ruleRow(_ scope: Scope, _ index: Int) -> some View {
        let rule = ruleBinding(scope, index)
        let statuses = editor.draft.lifecycle(kind(of: scope)).statuses
        let from = "From: " + (rule.wrappedValue.from.isEmpty ? "none" : rule.wrappedValue.from.sorted().joined(separator: ", "))
        return VStack(alignment: .leading, spacing: 4) {
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
                    ForEach(Self.editableKinds, id: \.self) { Text(Self.kindTitle($0)).tag($0) }
                }
                .labelsHidden().frame(minWidth: 80, maxWidth: 130)
                Button { removeRule(scope, index) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Remove this transition")
            }
            HStack(spacing: 10) {
                ForEach([LifecycleActorKind.human, .ai, .system], id: \.self) { actor in
                    actorMenu(rule, actor).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
    }

    private func actorMenu(_ rule: Binding<LifecycleRule>, _ actor: LifecycleActorKind) -> some View {
        let needs = rule.wrappedValue.needs[actor]
        let summary = Self.actorTitle(actor) + ": " + (needs.map { $0.isEmpty ? "nothing needed" : $0.map(\.words).joined(separator: ", ") } ?? "not allowed")
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
            Text(summary).lineLimit(1).truncationMode(.tail)
        }
        // The three actors share the row; a long list of conditions is cut with an ellipsis and read in full from the tooltip.
        .controlSize(.small)
        .help(summary)
    }

    private static let editableKinds: [TransitionKind] = [.spec, .start, .completion, .acceptance, .reopen, .rollback, .cancellation]
    private static let editableConditions: [LifecycleCondition] = [.startEvidence, .deliveryEvidence, .acceptanceEvidence, .regressionEvidence,
                                                                   .cancellationEvidence, .reason, .humanAcceptance]

    private static func kindTitle(_ kind: TransitionKind) -> String {
        switch kind {
        case .spec: return "Specification"
        case .start: return "Start"
        case .completion: return "Completion"
        case .acceptance: return "Acceptance"
        case .reopen: return "Reopening"
        case .rollback: return "Step back"
        case .cancellation: return "Cancellation"
        default: return kind.rawValue
        }
    }

    private static func actorTitle(_ actor: LifecycleActorKind) -> String {
        switch actor {
        case .human: return "Person"
        case .ai: return "AI"
        case .system: return "MarkView"
        }
    }

    private func addStatus(_ kind: IssueKind) {
        let id = IssueStatus.normalize(editor.newStatus)
        var current = editor.draft.lifecycle(kind)
        guard !id.isEmpty, !current.isKnown(id) else { editor.message = "\(id) is already a status."; return }
        current.statuses.append(WorkflowStatus(id: id, role: .notStarted))
        editor.draft.setLifecycle(kind, current)
        editor.newStatus = ""
        editor.message = nil
    }

    private func removeStatus(_ id: String, _ kind: IssueKind) {
        let dropped = editor.draft.removeStatus(id, kind: kind)
        editor.message = dropped == 0 ? nil : "Removing \(id) also removed \(dropped) transition\(dropped == 1 ? "" : "s") that ended there or started only there."
    }

    private func removeRule(_ scope: Scope, _ index: Int) {
        var all = rules(of: scope)
        guard all.indices.contains(index) else { return }
        all.remove(at: index)
        setRules(all, of: scope)
    }

    private func addRule(_ scope: Scope) {
        let statuses = editor.draft.lifecycle(kind(of: scope)).statuses
        guard let first = statuses.first, let last = statuses.last else { return }
        var all = rules(of: scope)
        all.append(LifecycleRule(from: [first.id], to: last.id == first.id ? first.id : last.id, kind: .spec, needs: [.human: []]))
        setRules(all, of: scope)
    }

    // MARK: Processes

    private var processesEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Processes", "A process is how one kind of work moves: how it reaches the default branch, which checks must pass, which event counts as delivery, who accepts it and, when it has transitions of its own, which steps it takes between the statuses of its type. A person picks one for each item; the workflow's current rules apply to its next step.")
            ForEach(Self.allKinds, id: \.self) { kind in
                Text(kind.rawValue.capitalized + " processes").uiFont(size: 11, weight: .semibold).padding(.top, 4)
                ForEach(editor.draft.variants(for: kind)) { processRow($0.id) }
            }
            addProcessMenu
            HStack(spacing: 12) {
                defaultPicker(.feature, $editor.draft.defaultFeatureVariant)
                defaultPicker(.bug, $editor.draft.defaultBugVariant)
            }
        }
    }

    private var addProcessMenu: some View {
        Menu {
            ForEach(Self.allKinds, id: \.self) { kind in
                Menu(kind.rawValue.capitalized) {
                    Section("With transitions of its own") {
                        ForEach(ProcessTemplate.allCases.filter { $0.applies(to: kind) }) { template in
                            Button(template.title) { addProcess(template, kind) }
                        }
                    }
                    Section("Following the transitions of the type") {
                        ForEach(VariantTemplate.allCases, id: \.self) { template in
                            Button(template.title) { addProcess(template, kind) }
                        }
                    }
                }
            }
        } label: { Label("New process from a template", systemImage: "plus") }
        .fixedSize().controlSize(.small)
    }

    private func defaultPicker(_ kind: IssueKind, _ selection: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text("Default for new \(kind.rawValue)s").uiFont(size: 11)
            Picker("", selection: selection) { ForEach(editor.draft.variants(for: kind)) { Text($0.name).tag($0.id) } }
                .labelsHidden().frame(width: 190)
        }
    }

    private static let blankVariant = VariantTemplate.directToMain.variant(kind: .feature, id: "")

    private func variantBinding(_ id: String) -> Binding<RuleVariant> {
        Binding(get: {
            editor.draft.variants.first { $0.id == id } ?? Self.blankVariant
        }, set: { value in
            guard let index = editor.draft.variants.firstIndex(where: { $0.id == id }) else { return }
            editor.draft.variants[index] = value
        })
    }

    private func processRow(_ id: String) -> some View {
        let variant = variantBinding(id)
        let own = variant.wrappedValue.rules != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Name", text: variant.name).textFieldStyle(.roundedBorder)
                Text(id).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim).lineLimit(1)
                Button { removeProcess(id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Remove this process. Items that use it follow a process you choose when you save.")
            }
            flowStrip(id)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { startAndBranch(variant); checksToggle(variant) }
                VStack(alignment: .leading, spacing: 6) { startAndBranch(variant); checksToggle(variant) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { deliveryAndAcceptance(variant) }
                VStack(alignment: .leading, spacing: 6) { deliveryAndAcceptance(variant) }
            }
            Text(variant.wrappedValue.description).uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            transitionsSection(id, own: own)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
    }

    @ViewBuilder
    private func startAndBranch(_ variant: Binding<RuleVariant>) -> some View {
        labeled("Start") {
            Picker("", selection: variant.start) { ForEach(StartEvidenceMode.allCases, id: \.self) { Text($0.title).tag($0) } }
        }
        labeled("Reaches the branch") {
            Picker("", selection: variant.integration) { ForEach(IntegrationPath.allCases, id: \.self) { Text($0.title).tag($0) } }
        }
    }

    private func checksToggle(_ variant: Binding<RuleVariant>) -> some View {
        Toggle("Checks must pass", isOn: variant.checks).toggleStyle(.checkbox).uiFont(size: 11)
    }

    @ViewBuilder
    private func deliveryAndAcceptance(_ variant: Binding<RuleVariant>) -> some View {
        labeled("Delivery event") {
            Picker("", selection: eventKind(variant)) {
                Text("None").tag(EventKind.none)
                Text("A published GitHub release").tag(EventKind.release)
                Text("A person confirms…").tag(EventKind.person)
            }
        }
        if case .humanConfirmed = variant.wrappedValue.delivery {
            TextField("Event, for example: installed on the other Mac", text: eventName(variant)).textFieldStyle(.roundedBorder)
        }
        labeled("Accepted by") {
            Picker("", selection: variant.acceptance) { ForEach(AcceptanceMode.allCases, id: \.self) { Text($0.title).tag($0) } }
        }
    }

    /// The statuses of the type in order, the ones this process uses lit and coloured by role, the others dim: the shape of the
    /// process at a glance.
    private func flowStrip(_ id: String) -> some View {
        let kind = editor.draft.variant(id)?.kind ?? .feature
        let statuses = editor.draft.lifecycle(kind).statuses
        let table = editor.draft.lifecycle(kind, variant: id).rules
        let used = table.reduce(into: Set<String>()) { $0.formUnion($1.from); $0.insert($1.to) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(statuses) { status in
                    let lit = used.contains(status.id)
                    Text(status.title).uiFont(size: 9, weight: .medium)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundColor(lit ? roleColor(status.role) : palette.textDim)
                        .background(Capsule().fill((lit ? roleColor(status.role) : palette.textDim).opacity(lit ? 0.16 : 0.08)))
                        .help(lit ? "\(status.title): used by this process" : "\(status.title): this process has no transition to or from it")
                }
            }
        }
    }

    private func roleColor(_ role: LifecycleRole) -> Color {
        switch role {
        case .notStarted: return palette.textDim
        case .active: return palette.blue
        case .completed: return palette.green
        case .cancelled: return palette.orange
        }
    }

    private func transitionsSection(_ id: String, own: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if own {
                DisclosureGroup(isExpanded: Binding(get: { editor.expanded.contains(id) },
                                                    set: { if $0 { editor.expanded.insert(id) } else { editor.expanded.remove(id) } })) {
                    VStack(alignment: .leading, spacing: 8) {
                        transitionRows(.process(id))
                        Button("Follow the transitions of the type again") { followType(id) }
                            .controlSize(.small).help("Drops the transitions of this process; it reads those of its type.")
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Own transitions (\(rules(of: .process(id)).count))").uiFont(size: 11, weight: .medium)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Follows the transitions of its type.").uiFont(size: 10).foregroundColor(palette.textDim)
                    Button("Give it its own transitions") { giveOwnTransitions(id) }.controlSize(.small)
                        .help("Starts from a copy of the transitions of the type, to change for this process only.")
                }
            }
        }
    }

    private enum EventKind: Hashable { case none, release, person }

    private func eventKind(_ variant: Binding<RuleVariant>) -> Binding<EventKind> {
        Binding(get: {
            switch variant.wrappedValue.delivery {
            case .none: return .none
            case .githubRelease: return .release
            case .humanConfirmed: return .person
            }
        }, set: { kind in
            switch kind {
            case .none: variant.wrappedValue.delivery = .none
            case .release: variant.wrappedValue.delivery = .githubRelease
            case .person:
                if case .humanConfirmed = variant.wrappedValue.delivery { return }
                variant.wrappedValue.delivery = .humanConfirmed(name: "")
            }
        })
    }

    private func eventName(_ variant: Binding<RuleVariant>) -> Binding<String> {
        Binding(get: {
            if case .humanConfirmed(let name) = variant.wrappedValue.delivery { return name }
            return ""
        }, set: { variant.wrappedValue.delivery = .humanConfirmed(name: $0) })
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) {
            Text(title).uiFont(size: 10).foregroundColor(palette.textDim)
            content().labelsHidden().fixedSize().controlSize(.small)
        }
    }

    private func addProcess(_ template: ProcessTemplate, _ kind: IssueKind) {
        let base = template == .quickFeature ? ProcessTemplate.quickFeatureID : kind.rawValue + "-" + template.rawValue
        let id = editor.draft.freshVariantID(base)
        editor.draft.variants.append(template.variant(kind: kind, id: id, in: editor.draft))
        editor.expanded.insert(id)
    }

    private func addProcess(_ template: VariantTemplate, _ kind: IssueKind) {
        let id = editor.draft.freshVariantID(kind.rawValue + "-" + template.rawValue)
        editor.draft.variants.append(template.variant(kind: kind, id: id))
    }

    private func removeProcess(_ id: String) {
        editor.draft.variants.removeAll { $0.id == id }
        editor.expanded.remove(id)
    }

    private func giveOwnTransitions(_ id: String) {
        guard let index = editor.draft.variants.firstIndex(where: { $0.id == id }) else { return }
        editor.draft.variants[index].rules = editor.draft.lifecycle(editor.draft.variants[index].kind).rules
        editor.expanded.insert(id)
    }

    private func followType(_ id: String) {
        guard let index = editor.draft.variants.firstIndex(where: { $0.id == id }) else { return }
        editor.draft.variants[index].rules = nil
        editor.expanded.remove(id)
    }

    // MARK: Items that lose a status or a process (DEC-021)

    private var impactEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Work items that need a replacement", "Some work items use a status or a process this change removes. Choose what they move to; each move is recorded in the item's history.")
            ForEach(editor.impact.statuses.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { kind in
                ForEach((editor.impact.statuses[kind] ?? [:]).keys.sorted(), id: \.self) { status in
                    HStack(spacing: 8) {
                        Text("\(kind.rawValue.capitalized) status “\(status)” — \((editor.impact.statuses[kind]?[status] ?? []).joined(separator: ", "))")
                            .uiFont(size: 11).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Picker("", selection: Binding(get: { editor.statusChoices["\(kind.rawValue):\(status)"] ?? "" },
                                                      set: { editor.statusChoices["\(kind.rawValue):\(status)"] = $0 })) {
                            Text("Choose…").tag("")
                            ForEach(editor.draft.lifecycle(kind).statuses) { Text($0.title).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 170)
                    }
                }
            }
            ForEach(editor.impact.variants.keys.sorted(), id: \.self) { variant in
                HStack(spacing: 8) {
                    Text("Process “\(variant)” — \((editor.impact.variants[variant] ?? []).joined(separator: ", "))")
                        .uiFont(size: 11).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Picker("", selection: Binding(get: { editor.variantChoices[variant] ?? "" }, set: { editor.variantChoices[variant] = $0 })) {
                        Text("Choose…").tag("")
                        ForEach(editor.draft.variants(for: store.lifecycle.workflow.variant(variant)?.kind ?? .feature)) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 170)
                }
            }
        }
        .padding(8)
        .background(palette.orange.opacity(0.08)).cornerRadius(6)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(problems.prefix(4).enumerated()), id: \.offset) { _, problem in
                Text("• " + problem.message).uiFont(size: 10).foregroundColor(palette.red).fixedSize(horizontal: false, vertical: true)
            }
            if problems.count > 4 { Text("… and \(problems.count - 4) more").uiFont(size: 10).foregroundColor(palette.red) }
            if let message = editor.message { Text(message).uiFont(size: 11).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    resetButton
                    reloadButton
                    Spacer(minLength: 8)
                    dirtyLabel
                    saveButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { dirtyLabel; Spacer(minLength: 8); saveButton }
                    HStack(spacing: 8) { resetButton; reloadButton; Spacer(minLength: 0) }
                }
            }
        }
        .padding(16)
    }

    private var resetButton: some View {
        Button("Reset to Standard") { editor.resetToStandard() }.controlSize(.small).disabled(!editable)
    }

    private var reloadButton: some View {
        Button("Reload from file") { editor.reload(from: store) }.controlSize(.small)
            .help("Reads .dde/workflow/workflow.json again and drops the edits that are not saved.")
    }

    private var dirtyLabel: some View {
        Text(editor.isDirty ? "Unsaved changes" : "Saved").uiFont(size: 10).foregroundColor(editor.isDirty ? palette.orange : palette.textDim)
    }

    private var saveButton: some View {
        Button(editor.impact.isEmpty ? "Save" : "Save and move items") { editor.save(in: store) }
            .disabled(!editable || !problems.isEmpty || editor.sourceError != nil || !editor.isDirty && editor.impact.isEmpty)
    }

    private func sectionTitle(_ title: String, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).uiFont(size: 12, weight: .semibold)
            Text(help).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let allKinds: [IssueKind] = [.feature, .bug]
}

/// A plain monospaced text view for the source of the workflow. Typing quotes must stay straight quotes and nothing may be
/// corrected, so every substitution that a SwiftUI `TextEditor` may apply is off.
private struct WorkflowSourceEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    @Environment(\.palette) private var palette

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.string = text
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.textColor = palette.nsText
        view.backgroundColor = NSColor(palette.model.bgInput)
        view.insertionPointColor = palette.nsAccent
        view.isEditable = editable
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            let length = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WorkflowSourceEditor
        init(_ parent: WorkflowSourceEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}
