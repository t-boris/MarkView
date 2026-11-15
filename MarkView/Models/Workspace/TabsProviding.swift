import Foundation

/// What a feature that works with the open documents needs from its window, and nothing more (`AR-14`, `AR-17`). `WorkspaceManager`
/// conforms: showing a file also means starting a single-file workspace and showing the feature the file belongs to.
@MainActor
protocol TabsProviding: AnyObject {
    /// The tab the person is looking at; nil on the Welcome tab.
    var activeTab: OpenTab? { get }
    /// Shows `url` in a tab of the window.
    func openFile(_ url: URL)
    /// Shows the tab of a GitHub issue, pull request or workflow run of the project at `root`, or returns to it.
    func showGitHubTab(_ item: GitHubItem, root: URL)
    /// Open tabs take the text of files that changed on disk (after a branch switch, or what an assistant wrote).
    func reloadChangedOpenFiles(all: Bool) async
}
