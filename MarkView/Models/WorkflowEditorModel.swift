import Combine
import Foundation
import SwiftUI

/// The state of the Workflow tab (BUG-108). The window keeps it, not the view, so edits that are not saved yet survive a switch
/// to another tab and back. The draft is the workflow being edited; the graphical view and the source view are two ways of editing
/// the same draft, and saving goes through the same checks and the same replacement of items as before (DEC-021).
@MainActor
final class WorkflowEditorModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case visual = "Visual", source = "Source"
        var id: String { rawValue }
    }

    enum Page: String, CaseIterable, Identifiable {
        case features = "Features", bugs = "Bugs", processes = "Processes"
        var id: String { rawValue }
    }

    @Published var draft = ProjectWorkflow.standard
    @Published var mode = Mode.visual
    @Published var page = Page.features
    /// The draft as JSON while the source view is open; what the person types there.
    @Published var sourceText = ""
    /// Why the source text is not a workflow; nil when it is.
    @Published var sourceError: String?
    @Published var impact = WorkflowImpact()
    @Published var statusChoices: [String: String] = [:]
    @Published var variantChoices: [String: String] = [:]
    @Published var message: String?
    @Published var newStatus = ""
    /// The processes whose own transitions are open.
    @Published var expanded: Set<String> = []

    /// The project the draft was read for, and the workflow as it was when read: a draft equal to it has no unsaved change.
    private var projectKey: String?
    private var base: ProjectWorkflow?

    var isDirty: Bool { base.map { $0 != draft } ?? false }

    private static let blankVariant = VariantTemplate.directToMain.variant(kind: .feature, id: "")

    /// A binding to one process of the draft, for the Processes page and for the card of an arrow in the diagram. A process that is
    /// gone (removed from the source view meanwhile) reads as a blank one and writes nothing.
    func variantBinding(_ id: String) -> Binding<RuleVariant> {
        Binding(get: { [unowned self] in
            draft.variants.first { $0.id == id } ?? Self.blankVariant
        }, set: { [unowned self] value in
            guard let index = draft.variants.firstIndex(where: { $0.id == id }) else { return }
            draft.variants[index] = value
        })
    }

    // MARK: Reading

    /// Called when the tab is shown. A different project starts a new draft; the same project keeps unsaved edits and, when there
    /// are none, takes up whatever the file holds now (a repair by hand, a pull from git).
    func attach(to store: FeatureStore) {
        let key = store.root?.standardizedFileURL.path
        if key != projectKey || base == nil {
            projectKey = key
            reload(from: store)
        } else if !isDirty {
            reload(from: store)
        }
    }

    /// Reads the file again and drops every unsaved edit.
    func reload(from store: FeatureStore) {
        store.lifecycle.reloadWorkflow()
        let loaded = store.lifecycle.workflow
        draft = loaded
        base = loaded
        impact = WorkflowImpact()
        statusChoices = [:]
        variantChoices = [:]
        message = nil
        sourceError = nil
        if mode == .source { sourceText = Self.sourceText(for: store) ?? ProjectWorkflowStore.text(of: loaded) }
    }

    /// What the source view shows for a workflow file that cannot be used: the file itself, so that the person sees what is wrong.
    private static func sourceText(for store: FeatureStore) -> String? {
        guard !store.lifecycle.workflowLoad.isEditable, let url = store.lifecycle.workflowStore?.url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Graphical and source views

    func switchMode(_ new: Mode, store: FeatureStore) {
        guard new != mode else { return }
        switch new {
        case .source:
            sourceText = Self.sourceText(for: store) ?? ProjectWorkflowStore.text(of: draft)
            sourceError = nil
            mode = .source
        case .visual:
            if let sourceError {
                message = "The source is not a workflow yet, so the graphical view cannot show it: " + sourceError
                return
            }
            message = nil
            mode = .visual
        }
    }

    /// The source text changed: the draft follows it while it parses; while it does not, the draft keeps its last good state and
    /// saving is off.
    func sourceChanged() {
        guard mode == .source else { return }
        switch ProjectWorkflowStore.parse(Data(sourceText.utf8)) {
        case .success(let workflow):
            sourceError = nil
            if workflow != draft { draft = workflow }
        case .failure(let load):
            switch load {
            case .unsupported(let schema): sourceError = "schema \(schema) is newer than this app understands (\(ProjectWorkflow.currentSchema))"
            case .damaged(let reason): sourceError = reason
            case .missing, .loaded: sourceError = "the text is not a workflow"
            }
        }
    }

    func resetToStandard() {
        var standard = ProjectWorkflow.standard
        standard.revision = draft.revision
        draft = standard
        if mode == .source { sourceText = ProjectWorkflowStore.text(of: standard) }
    }

    // MARK: Saving

    func save(in store: FeatureStore) {
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
            draft = report.workflow
            base = report.workflow
            impact = WorkflowImpact()
            statusChoices = [:]
            variantChoices = [:]
            if mode == .source { sourceText = ProjectWorkflowStore.text(of: report.workflow) }
            message = report.failures.isEmpty
                ? "Saved as revision \(report.workflow.revision)."
                : "The workflow is saved, but not every item could be moved:\n" + report.failures.prefix(5).joined(separator: "\n")
        case .failure(let error):
            if case .invalid = error, !impact.isEmpty {
                message = "Choose a replacement for each item listed above, then save again."
            } else if case .stale(let current) = error {
                message = "The workflow was changed elsewhere meanwhile (it is now revision \(current)), so this edit was not saved over it. Use “Reload from file”, then repeat your change."
            } else {
                message = error.localizedDescription
            }
        }
    }
}
