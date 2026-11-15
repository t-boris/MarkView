import SwiftUI

/// The list of flows behind the Flow button of the Workflow tab: the classic flows (feature workflow-flows, REQ-003), each with where
/// it comes from, what it is for and its columns, and the person's own templates from the shared folder (feature
/// workflow-templates, REQ-001, REQ-002), with a way to save the workflow being edited as a new one. Choosing only loads the flow or
/// template into the draft.
struct WorkflowFlowPicker: View {
    @Environment(\.palette) private var palette
    @ObservedObject var editor: WorkflowEditorModel
    @ObservedObject var library: WorkflowTemplateLibrary
    let choose: (WorkflowFlow) -> Void
    let chooseTemplate: (WorkflowTemplate) -> Void

    @State private var saving = false
    @State private var name = ""
    @State private var note = ""
    @State private var saveMessage: String?
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a flow").uiFont(size: 13, weight: .semibold)
            Text("A flow replaces the states and transitions of features and bugs and keeps the delivery settings of the processes. A template replaces all of it, processes included. Nothing is saved until you press Save.")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    saveBlock
                    sectionTitle("My templates")
                    if library.loaded && library.templates.isEmpty {
                        Text("None yet. Set the workflow up, then save it above; every project can take it from here.")
                            .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(library.templates) { template in templateRow(template) }
                    ForEach(library.listing.unusable) { file in
                        Text("\(file.file) cannot be used: \(file.reason).").uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    sectionTitle("Classic flows")
                    ForEach(WorkflowFlow.catalogue) { flow in row(flow) }
                }
            }
        }
        .padding(14)
        .frame(width: 460, height: 560)
        .task { await library.reload() }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).uiFont(size: 10, weight: .semibold).foregroundColor(palette.textDim).padding(.top, 2)
    }

    // MARK: Saving the workflow as a template

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The template this name would write over: the same name, whatever the case.
    private var sameName: WorkflowTemplate? { library.templates.first { $0.name.lowercased() == trimmedName.lowercased() } }

    private var saveBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if saving {
                Text("Save this workflow as a template").uiFont(size: 11, weight: .semibold)
                TextField("Name, for example “Kanban with GitHub”", text: $name).textFieldStyle(.roundedBorder).uiFont(size: 11)
                TextField("What it is for (optional)", text: $note).textFieldStyle(.roundedBorder).uiFont(size: 11)
                let problems = editor.draft.validate()
                if !problems.isEmpty {
                    Text("The workflow cannot be a template yet: " + problems.map(\.message).joined(separator: " "))
                        .uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(sameName == nil ? "Save template" : "Replace “\(sameName?.name ?? "")”") { save() }
                        .controlSize(.small).disabled(trimmedName.isEmpty || !problems.isEmpty)
                    Button("Cancel") { saving = false; saveMessage = nil }.controlSize(.small)
                }
                Text("It keeps the states, transitions and every process as they are in the draft now, saved or not.")
                    .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Save as template…") { saving = true; saveMessage = nil }.controlSize(.small)
            }
            if let saveMessage {
                Text(saveMessage).uiFont(size: 10).foregroundColor(saveFailed ? palette.orange : palette.green).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
    }

    private func save() {
        let target = sameName?.id
        let workflow = editor.draft
        let (title, text) = (trimmedName, note)
        Task {
            switch await library.save(name: title, note: text, workflow: workflow, replacing: target) {
            case .success(let template):
                saveFailed = false
                saveMessage = "Saved “\(template.name)”. Any project can take it from this list."
                saving = false
                name = ""; note = ""
            case .failure(let error):
                saveFailed = true
                saveMessage = error.localizedDescription
            }
        }
    }

    // MARK: Rows

    private func templateRow(_ template: WorkflowTemplate) -> some View {
        let current = library.template(matching: editor.draft)?.id == template.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(template.name).uiFont(size: 12, weight: .semibold)
                if template.needsGitHub { Text("Needs GitHub").uiFont(size: 10, weight: .medium).foregroundColor(palette.orange) }
                Spacer(minLength: 6)
                if current {
                    Text("In use").uiFont(size: 10, weight: .medium).foregroundColor(palette.green)
                } else {
                    Button("Use") { chooseTemplate(template) }.controlSize(.small)
                }
            }
            if !template.note.isEmpty { Text(template.note).uiFont(size: 10.5).fixedSize(horizontal: false, vertical: true) }
            Text((template.bugsDiffer ? "Features: " : "") + template.outline(.feature)).uiFont(size: 10).foregroundColor(palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if template.bugsDiffer {
                Text("Bugs: " + template.outline(.bug)).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(current ? palette.green.opacity(0.6) : Color.clear))
    }

    private func row(_ flow: WorkflowFlow) -> some View {
        let current = editor.currentFlow?.id == flow.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(flow.title).uiFont(size: 12, weight: .semibold)
                Text(flow.origin).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1)
                Spacer(minLength: 6)
                if current {
                    Text("In use").uiFont(size: 10, weight: .medium).foregroundColor(palette.green)
                } else {
                    Button("Use") { choose(flow) }.controlSize(.small)
                }
            }
            Text(flow.summary).uiFont(size: 10.5).fixedSize(horizontal: false, vertical: true)
            Text((flow.bugsDiffer ? "Features: " : "") + flow.outline(.feature)).uiFont(size: 10).foregroundColor(palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if flow.bugsDiffer {
                Text("Bugs: " + flow.outline(.bug)).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(current ? palette.green.opacity(0.6) : Color.clear))
    }
}
