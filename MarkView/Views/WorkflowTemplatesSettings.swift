import AppKit
import SwiftUI

/// The shared workflow templates in Settings (feature workflow-templates, REQ-001, REQ-003, REQ-004): what is saved, which one new
/// projects start on, what the built-in default asks of GitHub and how to switch the requirements on, and the files that cannot be
/// used. A template is saved from the Workflow tab of a project (Flow → Save as template…); here it is only chosen, found and removed.
struct WorkflowTemplatesSettings: View {
    @Environment(\.palette) private var palette
    @ObservedObject var library: WorkflowTemplateLibrary
    @State private var deleting: WorkflowTemplate?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("My workflow templates").uiFont(size: 12, weight: .semibold)
            Text("A template is a whole workflow: the states and transitions of features and bugs and every process with its delivery settings. Save one from a project's Workflow tab (Flow → Save as template…), then take it into any other project from the same menu. Each template is a file in the folder below; copy the folder to move them to another Mac.")
                .uiFont(.caption).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            newProjects
            if library.loaded && library.templates.isEmpty && library.listing.unusable.isEmpty {
                Text("No templates yet.").uiFont(size: 10.5).foregroundColor(palette.textDim)
            }
            ForEach(library.templates) { template in row(template) }
            ForEach(library.listing.unusable) { file in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundColor(palette.orange)
                    Text("\(file.file) cannot be used: \(file.reason). The file is left as it is.")
                        .uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message { Text(message).uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Button("Open the templates folder") { Task { let folder = await library.ensureFolder(); NSWorkspace.shared.open(folder) } }
                    .controlSize(.small)
                Text(library.store.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .uiFont(size: 10, design: .monospaced).foregroundColor(palette.textDim).lineLimit(1).truncationMode(.middle)
            }
        }
        .task { await library.reload() }
        .confirmationDialog("Delete the template “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let target = deleting else { return }
                deleting = nil
                Task { message = await library.delete(target.id) }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Projects that already took it keep their own copy. New projects fall back to the built-in default if this one was chosen for them.")
        }
    }

    // MARK: New projects

    private var newProjects: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("New projects start on").uiFont(size: 10.5, weight: .semibold)
            if let chosen = library.listing.defaultTemplate {
                Text("“\(chosen.name)”, as it was saved.").uiFont(size: 10.5)
                if chosen.needsGitHub {
                    Text("It asks for a pull request, checks or a release, which need GitHub connected in Settings → GitHub.")
                        .uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
                }
                Button("Use the built-in default instead") { Task { message = await library.setDefault(nil) } }.controlSize(.small)
            } else {
                if let missing = library.listing.defaultID {
                    Text("The template chosen for new projects (“\(missing)”) is gone or cannot be used, so the built-in default applies.")
                        .uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text("The built-in default: Kanban, where work reaches the default branch directly, with no pull request, checks or release required, so it works without GitHub or CI. A project that has its own Definition of Done keeps what that says.")
                    .uiFont(size: 10.5).fixedSize(horizontal: false, vertical: true)
            }
            Text("To require a merged pull request, passing checks or a published release, open a project's Workflow tab, Processes, choose the process and set “Reaches the branch”, “Checks must pass” and “Delivery event”. They need GitHub connected in Settings → GitHub; without it work cannot be completed under them, and the Workflow tab warns.")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
    }

    // MARK: A template

    private func row(_ template: WorkflowTemplate) -> some View {
        let isDefault = library.listing.defaultID == template.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(template.name).uiFont(size: 11.5, weight: .semibold)
                if isDefault { Text("For new projects").uiFont(size: 10, weight: .medium).foregroundColor(palette.green) }
                if template.needsGitHub { Text("Needs GitHub").uiFont(size: 10, weight: .medium).foregroundColor(palette.orange) }
                Spacer(minLength: 6)
                Text(template.savedAt.formatted(date: .abbreviated, time: .omitted)).uiFont(size: 10).foregroundColor(palette.textDim)
            }
            if !template.note.isEmpty { Text(template.note).uiFont(size: 10.5).fixedSize(horizontal: false, vertical: true) }
            Text((template.bugsDiffer ? "Features: " : "") + template.outline(.feature)).uiFont(size: 10).foregroundColor(palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if template.bugsDiffer {
                Text("Bugs: " + template.outline(.bug)).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if isDefault {
                    Button("Stop using for new projects") { Task { message = await library.setDefault(nil) } }.controlSize(.small)
                } else {
                    Button("Use for new projects") { Task { message = await library.setDefault(template.id) } }.controlSize(.small)
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.store.url(of: template.id)]) }.controlSize(.small)
                Button("Delete…", role: .destructive) { deleting = template }.controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isDefault ? palette.green.opacity(0.6) : Color.clear))
    }
}
