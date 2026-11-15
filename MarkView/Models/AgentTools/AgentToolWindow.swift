import Foundation

/// What a window offers agents through the tool server (`AgentToolServer`): its workspace and project folder, the stores the
/// project, deployments and discussions tools work on, and the browser tools of its own tabs. A closure answers for a part that the
/// window may not have (yet): nil, or an error reply.
struct AgentToolWindow {
    /// The window's workspace, for the control tools (`ControlToolRunner`); nil once the window is gone.
    var workspace: () -> WorkspaceManager? = { nil }
    /// The window's project folder (agents outside its terminals are matched by their folder).
    var root: () -> URL?
    /// The window's features and bugs, for the project tools (`ProjectToolRunner`).
    var features: () -> FeatureStore? = { nil }
    /// The window's Deployments, for the deployments tools (`DeploymentToolRunner`).
    var deployments: () -> DeploymentStore? = { nil }
    /// The window's Discussions, for the discussions tools (`DiscussionToolRunner`).
    var discussions: () -> DiscussionStore? = { nil }
    /// Runs one browser tool (`browser_*`) in this window's browser tabs. The server knows no tab: the Browser domain answers.
    var browser: @MainActor (String, [String: Any]) async -> BrowserAgentTools.Reply = { _, _ in .error("This window has no browser.") }
}
