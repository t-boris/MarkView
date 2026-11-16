import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What a GitHub tab shows, in which repository ("owner/name"); `title` is the tab's name.
enum GitHubItem: Hashable, Codable {
    case run(id: Int, repo: String, title: String)
    case issue(number: Int, repo: String, title: String)
    case pullRequest(number: Int, repo: String, title: String)

    var title: String {
        switch self {
        case .run(_, _, let title), .issue(_, _, let title), .pullRequest(_, _, let title): return title
        }
    }

    var repo: String {
        switch self {
        case .run(_, let repo, _), .issue(_, let repo, _), .pullRequest(_, let repo, _): return repo
        }
    }

    /// Placeholder file name of the tab (never read or written).
    var marker: String {
        let repo = self.repo.replacingOccurrences(of: "/", with: "-")
        switch self {
        case .run(let id, _, _): return ProjectPaths.placeholderName("github-\(repo)-run-\(id)")
        case .issue(let number, _, _): return ProjectPaths.placeholderName("github-\(repo)-issue-\(number)")
        case .pullRequest(let number, _, _): return ProjectPaths.placeholderName("github-\(repo)-pr-\(number)")
        }
    }
}
