import SwiftUI

/// The view each tool's tab shows: the one mapping from a tool to its content, next to the tool's descriptor in `ToolRegistry`
/// (`AR-31`). The registry says what a tool is called, looks like and where it is offered; this says what its tab draws.
@MainActor
enum ToolTabViews {
    /// What the view of a tool tab may read: the window, the tab itself (UI Studio and the Cockpit keep their session in its kind) and
    /// the window's review of observed file changes.
    struct Context {
        let workspace: WorkspaceManager
        let tab: OpenTab
        let changeReview: ProjectChangeReview
    }

    private static let builders: [ToolID: (Context) -> AnyView] = [
        .git: { context in
            let workspace = context.workspace
            return AnyView(GitView(git: workspace.gitClient, flow: workspace.flow, codeXRay: workspace.codeXRay, requests: workspace.requests,
                                   layout: workspace.layout, window: workspace))
        },
        .deployments: { context in
            let deployments = context.workspace.toolTabs.deployments
            return AnyView(DeploymentsView(host: deployments, store: deployments.store, operations: context.workspace.projectOperations))
        },
        .workflow: { AnyView(WorkflowTabView(store: $0.workspace.flow.features, editor: $0.workspace.toolTabs.workflowEditor)) },
        .qa: { AnyView(QATabView(model: $0.workspace.toolTabs.qa)) },
        .discussions: { AnyView(DiscussionsView(host: $0.workspace.toolTabs.discussions, store: $0.workspace.toolTabs.discussions.store)) },
        .changeReview: { AnyView(ProjectChangeReviewTab(review: $0.changeReview)) },
        .uiStudio: { context in
            guard case .uiStudio(let session) = context.tab.kind else { return AnyView(EmptyView()) }
            return AnyView(UIStudioView(session: session))
        },
        .cockpit: { context in
            guard case .cockpit(let session) = context.tab.kind else { return AnyView(EmptyView()) }
            return AnyView(CockpitView(session: session))
        }
    ]

    /// The content of the tab of tool `id`. A registered tool without an entry above is a mistake of the change that added it, so it
    /// stops a Debug build and says so on screen instead of drawing a blank tab.
    static func view(for id: ToolID, context: Context) -> AnyView {
        guard let build = builders[id] else {
            assertionFailure("No view is mapped for the tool \(id.rawValue); add it to ToolTabViews")
            return AnyView(Text("No view is mapped for the tool \(id.rawValue).").padding())
        }
        return build(context)
    }
}
