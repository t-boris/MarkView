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
                    flowButton
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

    // MARK: Flows

    @State private var choosingFlow = false
    @ObservedObject private var library = WorkflowTemplateLibrary.shared

    private var flowButton: some View {
        Button { choosingFlow = true } label: {
            Text("Flow: " + (editor.currentFlow?.title ?? library.template(matching: editor.draft)?.name ?? "custom"))
        }
        .controlSize(.small).disabled(!editable)
        .help("Load a classic flow (Kanban, Scrum, …) or one of your saved templates into the draft, or save this workflow as a template. Nothing is saved to the project until you press Save.")
        .task { await library.reload() }
        .popover(isPresented: $choosingFlow, arrowEdge: .bottom) {
            WorkflowFlowPicker(editor: editor, library: library,
                               choose: { flow in editor.apply(flow); choosingFlow = false },
                               chooseTemplate: { template in editor.apply(template); choosingFlow = false })
        }
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

    // MARK: States and transitions of a type

    private func lifecycleEditor(_ kind: IssueKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("States and transitions", "Each state is a status of every \(kind.rawValue) process, in the column of its role: the role tells the rest of MarkView what a status means (completion, reopening, progress and GitHub follow roles, not names; a role alone never proves delivery). Each arrow is a step someone may make, with what each of them must have, for the processes that follow the transitions of the type. A step no arrow offers is not offered; only a person can force it, with a reason.")
            WorkflowTransitionsEditor(editor: editor, scope: .type(kind))
        }
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

    private func processRow(_ id: String) -> some View {
        let variant = editor.variantBinding(id)
        let own = variant.wrappedValue.rules != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Name", text: variant.name).textFieldStyle(.roundedBorder)
                Text(id).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim).lineLimit(1)
                Button { removeProcess(id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Remove this process. Items that use it follow a process you choose when you save.")
            }
            flowStrip(id)
            WorkflowProcessControls(variant: variant, parts: .all)
            Text(variant.wrappedValue.description).uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            transitionsSection(id, own: own)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
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
                        WorkflowTransitionsEditor(editor: editor, scope: .process(id))
                        Button("Follow the transitions of the type again") { followType(id) }
                            .controlSize(.small).help("Drops the transitions of this process; it reads those of its type.")
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Own transitions (\(editor.draft.variant(id)?.rules?.count ?? 0))").uiFont(size: 11, weight: .medium)
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
