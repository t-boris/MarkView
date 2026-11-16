import Foundation

/// The scope an X-Ray tab shows: the whole project (empty), one folder (its path relative to the project root) or the pull request's
/// change (`pullRequest`). The window's tab only carries the string; what it means belongs to the X-Ray.
enum XRayScope {
    /// Scope of the PR X-Ray tab: the project's X-Ray seen through one change.
    static let pullRequest = "#pr"

    /// What the X-Ray page is told about the tab it draws: "pr" for the PR X-Ray, "folder" for the X-Ray of one folder
    /// (it has no comparison view to open), nil for the project's X-Ray.
    static func mode(scope: String) -> String? {
        if scope == pullRequest { return "pr" }
        return scope.isEmpty ? nil : "folder"
    }
}
