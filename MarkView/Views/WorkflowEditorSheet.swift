import SwiftUI

/// The project workflow editor (feature-3, REQ-001, REQ-002, REQ-005): the statuses of features and bugs with their lifecycle roles,
/// the transitions between them and the conditions each kind of actor must meet, and the rule variants that say how the start,
/// delivery and acceptance of an item are judged. Saving is checked as a whole; a status or variant that work items still use is
/// removed only after a person chose what replaces it (DEC-021). Opened from Settings.
struct WorkflowEditorSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FeatureStore

    private enum Tab: String, CaseIterable, Identifiable {
        case features = "Features", bugs = "Bugs", variants = "Rule variants"
        var id: String { rawValue }
    }

    @State private var draft = ProjectWorkflow.standard
    @State private var tab = Tab.features
    @State private var newStatus = ""
    @State private var impact = WorkflowImpact()
    @State private var statusChoices: [String: String] = [:]
    @State private var variantChoices: [String: String] = [:]
    @State private var message: String?

    private var load: WorkflowLoad { store.lifecycle.workflowLoad }
    private var editable: Bool { load.isEditable && store.root != nil }
    private var problems: [WorkflowProblem] { draft.validate() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project workflow").uiFont(size: 14, weight: .semibold)
            Text("How features and bugs move in this project: their statuses, who may make each step and on what evidence, and the rule variants an item can follow. This is the authority for transitions; the Definition of Done and the project instructions only guide the work.")
                .uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            if let problem = load.problem {
                Text(problem).uiFont(size: 11).foregroundColor(palette.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text("Name").uiFont(size: 11)
                TextField("Workflow name", text: $draft.name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Text("Revision \(draft.revision)").uiFont(size: 10).foregroundColor(palette.textDim)
            }
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch tab {
                    case .features: lifecycleEditor(.feature)
                    case .bugs: lifecycleEditor(.bug)
                    case .variants: variantsEditor
                    }
                    if !impact.isEmpty { impactEditor }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            .frame(height: 400)
            .disabled(!editable)
            footer
        }
        .padding(18)
        .frame(width: 760)
        .onAppear { draft = store.lifecycle.workflow }
    }

    // MARK: Statuses and transitions

    // The rows below are drawn from the draft while a row may just have been removed, so every binding checks its row still exists:
    // a stale row reads a blank value and writes nothing instead of failing on an index that is gone.

    private static let blankRule = LifecycleRule(from: [], to: "", kind: .spec, needs: [:])

    private func ruleBinding(_ kind: IssueKind, _ index: Int) -> Binding<LifecycleRule> {
        Binding(get: {
            let rules = draft.lifecycle(kind).rules
            return rules.indices.contains(index) ? rules[index] : Self.blankRule
        }, set: { value in
            var current = draft.lifecycle(kind)
            guard current.rules.indices.contains(index) else { return }
            current.rules[index] = value
            draft.setLifecycle(kind, current)
        })
    }

    private func statusBinding(_ kind: IssueKind, _ id: String) -> Binding<WorkflowStatus> {
        Binding(get: {
            draft.lifecycle(kind).statuses.first { $0.id == id } ?? WorkflowStatus(id: id, role: .notStarted)
        }, set: { value in
            var current = draft.lifecycle(kind)
            guard let index = current.statuses.firstIndex(where: { $0.id == id }) else { return }
            current.statuses[index] = value
            draft.setLifecycle(kind, current)
        })
    }

    private func lifecycleEditor(_ kind: IssueKind) -> some View {
        let definition = draft.lifecycle(kind)
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Statuses", "The role tells the rest of MarkView what a status means: completion, reopening, progress and GitHub follow roles, not names. A role alone never proves delivery.")
            ForEach(definition.statuses) { status in
                HStack(spacing: 8) {
                    Text(status.id).uiFont(size: 11, design: .monospaced).frame(width: 130, alignment: .leading)
                    TextField("Title", text: statusBinding(kind, status.id).title).textFieldStyle(.roundedBorder).frame(width: 190)
                    Picker("", selection: statusBinding(kind, status.id).role) {
                        ForEach(LifecycleRole.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    Spacer(minLength: 0)
                    Button { removeStatus(status.id, kind) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).help("Remove this status. Work items in it are moved to a status you choose when you save.")
                }
            }
            HStack(spacing: 8) {
                TextField("new-status-id", text: $newStatus).textFieldStyle(.roundedBorder).frame(width: 190)
                Button("Add status") { addStatus(kind) }.controlSize(.small).disabled(IssueStatus.normalize(newStatus).isEmpty)
                Text("Lower-case words joined by hyphens. An id cannot be renamed: add the new one and remove the old one.")
                    .uiFont(size: 9).foregroundColor(palette.textDim)
            }
            sectionTitle("Transitions", "Who may move an item from a status to another and what each must have. A step no one is listed for is not offered; only a person can force it, with a reason.")
            ForEach(0..<definition.rules.count, id: \.self) { index in
                ruleRow(kind, index)
            }
            Button { addRule(kind) } label: { Label("Add a transition", systemImage: "plus") }
                .buttonStyle(.plain).foregroundColor(palette.blue).uiFont(size: 11)
        }
    }

    private func ruleRow(_ kind: IssueKind, _ index: Int) -> some View {
        let rule = ruleBinding(kind, index)
        let statuses = draft.lifecycle(kind).statuses
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
                    Text("From: " + (rule.wrappedValue.from.isEmpty ? "none" : rule.wrappedValue.from.sorted().joined(separator: ", "))).lineLimit(1)
                }
                .fixedSize().controlSize(.small)
                Image(systemName: "arrow.right").foregroundColor(palette.textDim)
                Picker("", selection: rule.to) { ForEach(statuses) { Text($0.title).tag($0.id) } }
                    .labelsHidden().frame(width: 150)
                Picker("", selection: rule.kind) {
                    ForEach(Self.editableKinds, id: \.self) { Text(Self.kindTitle($0)).tag($0) }
                }
                .labelsHidden().frame(width: 130)
                Spacer(minLength: 0)
                Button { removeRule(kind, index) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Remove this transition")
            }
            HStack(spacing: 10) {
                ForEach([LifecycleActorKind.human, .ai, .system], id: \.self) { actor in
                    actorMenu(rule, actor)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bg))
    }

    private func actorMenu(_ rule: Binding<LifecycleRule>, _ actor: LifecycleActorKind) -> some View {
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
            Text(Self.actorTitle(actor) + ": " + (needs.map { $0.isEmpty ? "nothing needed" : $0.map(\.words).joined(separator: ", ") } ?? "not allowed"))
                .lineLimit(1)
        }
        .fixedSize().controlSize(.small)
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
        let id = IssueStatus.normalize(newStatus)
        var current = draft.lifecycle(kind)
        guard !id.isEmpty, !current.isKnown(id) else { message = "\(id) is already a status."; return }
        current.statuses.append(WorkflowStatus(id: id, role: .notStarted))
        draft.setLifecycle(kind, current)
        newStatus = ""
        message = nil
    }

    private func removeStatus(_ id: String, _ kind: IssueKind) {
        var current = draft.lifecycle(kind)
        let before = current.rules.count
        current.statuses.removeAll { $0.id == id }
        current.rules = current.rules.compactMap { rule in
            guard rule.to != id else { return nil }
            var rule = rule
            rule.from.remove(id)
            return rule.from.isEmpty ? nil : rule
        }
        draft.setLifecycle(kind, current)
        let dropped = before - current.rules.count
        message = dropped == 0 ? nil : "Removing \(id) also removed \(dropped) transition\(dropped == 1 ? "" : "s") that ended there or started only there."
    }

    private func removeRule(_ kind: IssueKind, _ index: Int) {
        var current = draft.lifecycle(kind)
        guard current.rules.indices.contains(index) else { return }
        current.rules.remove(at: index)
        draft.setLifecycle(kind, current)
    }

    private func addRule(_ kind: IssueKind) {
        var current = draft.lifecycle(kind)
        guard let first = current.statuses.first, let last = current.statuses.last else { return }
        current.rules.append(LifecycleRule(from: [first.id], to: last.id == first.id ? first.id : last.id, kind: .spec, needs: [.human: []]))
        draft.setLifecycle(kind, current)
    }

    // MARK: Rule variants

    private var variantsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Rule variants", "A variant says how the work of an item reaches the default branch, which checks must pass, which event counts as delivery and who accepts. A person picks one for each item; the workflow's current rules apply to its next step.")
            ForEach(draft.variants) { variant in variantRow(variant.id) }
            Menu {
                ForEach(IssueKind.allKinds, id: \.self) { kind in
                    Menu(kind.rawValue.capitalized) {
                        ForEach(VariantTemplate.allCases, id: \.self) { template in
                            Button(template.title) { addVariant(template, kind) }
                        }
                    }
                }
            } label: { Label("Add a variant from a template", systemImage: "plus") }
            .fixedSize().controlSize(.small)
            HStack(spacing: 12) {
                defaultPicker(.feature, $draft.defaultFeatureVariant)
                defaultPicker(.bug, $draft.defaultBugVariant)
            }
        }
    }

    private func defaultPicker(_ kind: IssueKind, _ selection: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text("Default for new \(kind.rawValue)s").uiFont(size: 11)
            Picker("", selection: selection) { ForEach(draft.variants(for: kind)) { Text($0.name).tag($0.id) } }
                .labelsHidden().frame(width: 190)
        }
    }

    private static let blankVariant = VariantTemplate.directToMain.variant(kind: .feature, id: "")

    private func variantBinding(_ id: String) -> Binding<RuleVariant> {
        Binding(get: {
            draft.variants.first { $0.id == id } ?? Self.blankVariant
        }, set: { value in
            guard let index = draft.variants.firstIndex(where: { $0.id == id }) else { return }
            draft.variants[index] = value
        })
    }

    private func variantRow(_ id: String) -> some View {
        let variant = variantBinding(id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(variant.wrappedValue.kind.rawValue.uppercased()).uiFont(size: 9, weight: .bold).foregroundColor(palette.textDim).frame(width: 52, alignment: .leading)
                TextField("Name", text: variant.name).textFieldStyle(.roundedBorder)
                Text(id).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim)
                Button { removeVariant(id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Remove this variant. Items that use it follow a variant you choose when you save.")
            }
            HStack(spacing: 10) {
                labeled("Start") {
                    Picker("", selection: variant.start) { ForEach(StartEvidenceMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                }
                labeled("Reaches the branch") {
                    Picker("", selection: variant.integration) { ForEach(IntegrationPath.allCases, id: \.self) { Text($0.title).tag($0) } }
                }
                Toggle("Checks must pass", isOn: variant.checks).toggleStyle(.checkbox).uiFont(size: 11)
            }
            HStack(spacing: 10) {
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
            Text(variant.wrappedValue.description).uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bg))
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

    private func addVariant(_ template: VariantTemplate, _ kind: IssueKind) {
        var id = kind.rawValue + "-" + template.rawValue
        var suffix = 2
        while draft.variant(id) != nil { id = kind.rawValue + "-" + template.rawValue + "-\(suffix)"; suffix += 1 }
        draft.variants.append(template.variant(kind: kind, id: id))
    }

    private func removeVariant(_ id: String) {
        draft.variants.removeAll { $0.id == id }
    }

    // MARK: Items that lose a status or a variant (DEC-021)

    private var impactEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Work items that need a replacement", "Some work items use a status or a variant this change removes. Choose what they move to; each move is recorded in the item's history.")
            ForEach(impact.statuses.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { kind in
                ForEach((impact.statuses[kind] ?? [:]).keys.sorted(), id: \.self) { status in
                    HStack(spacing: 8) {
                        Text("\(kind.rawValue.capitalized) status “\(status)” — \((impact.statuses[kind]?[status] ?? []).joined(separator: ", "))")
                            .uiFont(size: 11).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Picker("", selection: Binding(get: { statusChoices["\(kind.rawValue):\(status)"] ?? "" },
                                                      set: { statusChoices["\(kind.rawValue):\(status)"] = $0 })) {
                            Text("Choose…").tag("")
                            ForEach(draft.lifecycle(kind).statuses) { Text($0.title).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 170)
                    }
                }
            }
            ForEach(impact.variants.keys.sorted(), id: \.self) { variant in
                HStack(spacing: 8) {
                    Text("Variant “\(variant)” — \((impact.variants[variant] ?? []).joined(separator: ", "))")
                        .uiFont(size: 11).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Picker("", selection: Binding(get: { variantChoices[variant] ?? "" }, set: { variantChoices[variant] = $0 })) {
                        Text("Choose…").tag("")
                        ForEach(draft.variants(for: store.lifecycle.workflow.variant(variant)?.kind ?? .feature)) { Text($0.name).tag($0.id) }
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
            if let message { Text(message).uiFont(size: 11).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Reset to Standard") { draft = ProjectWorkflow.standard.withRevision(draft.revision) }.controlSize(.small).disabled(!editable)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(impact.isEmpty ? "Save" : "Save and move items") { save() }
                    .keyboardShortcut(.defaultAction).disabled(!editable || !problems.isEmpty)
            }
        }
    }

    private func save() {
        message = nil
        impact = store.lifecycle.workflowImpact(of: draft)
        var statusReplacements: [IssueKind: [String: String]] = [:]
        for (kind, removed) in impact.statuses {
            for status in removed.keys {
                if let chosen = statusChoices["\(kind.rawValue):\(status)"], !chosen.isEmpty { statusReplacements[kind, default: [:]][status] = chosen }
            }
        }
        var variantReplacements: [String: String] = [:]
        for variant in impact.variants.keys {
            if let chosen = variantChoices[variant], !chosen.isEmpty { variantReplacements[variant] = chosen }
        }
        switch store.lifecycle.saveWorkflow(draft, statusReplacements: statusReplacements, variantReplacements: variantReplacements,
                                            by: .human(store.lifecycleActor)) {
        case .success(let report):
            if report.failures.isEmpty {
                dismiss()
            } else {
                draft = report.workflow
                impact = WorkflowImpact()
                message = "The workflow is saved, but not every item could be moved:\n" + report.failures.prefix(5).joined(separator: "\n")
            }
        case .failure(let error):
            if case .invalid = error, !impact.isEmpty {
                message = "Choose a replacement for each item listed above, then save again."
            } else if case .stale(let current) = error {
                message = "The workflow was changed elsewhere meanwhile (it is now revision \(current)), so this edit was not saved over it. Close this window, open it again and repeat your change."
            } else {
                message = error.localizedDescription
            }
        }
    }

    private func sectionTitle(_ title: String, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).uiFont(size: 12, weight: .semibold)
            Text(help).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension IssueKind {
    static let allKinds: [IssueKind] = [.feature, .bug]
}

private extension ProjectWorkflow {
    /// The standard workflow keeping the revision being edited, so that saving it is a change of that revision.
    func withRevision(_ revision: Int) -> ProjectWorkflow {
        var copy = self
        copy.revision = revision
        return copy
    }
}
