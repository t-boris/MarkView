import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The local repository's `origin` compared with the chosen GitHub repository (DEC-010): only a
/// missing or identical origin lets the connection continue; another one is never replaced.
enum OriginState: Equatable {
    case none
    case same
    case other(String)

    static func of(currentURL: String?, target slug: String) -> OriginState {
        guard let url = currentURL?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return .none }
        guard let current = githubSlug(fromRemoteURL: url) else { return .other(url) }
        return current.lowercased() == slug.lowercased() ? .same : .other(url)
    }

    /// "owner/name" from git@github.com:owner/name.git or https://github.com/owner/name(.git),
    /// including remotes that reach GitHub through an SSH host alias.
    static func githubSlug(fromRemoteURL url: String) -> String? {
        GitHubClient.slug(fromRemoteURL: url)
    }
}

/// Progress of connecting a project to GitHub, kept in the project's `.dde/` so a retry — now or
/// after a relaunch, from the new-project flow or later — continues with the same repository
/// instead of creating another one (DEC-019).
struct GitHubConnectionRecord: Codable, Equatable {
    var owner: String
    var name: String
    /// "private" or "public", chosen explicitly (DEC-010).
    var visibility: String
    /// MarkView created the repository: it may push into it although it now exists.
    var createdByMarkView: Bool
    var committed: Bool
    var pushed: Bool
    var updated: Date

    var slug: String { owner + "/" + name }

    static let relativePath = ProjectPaths.githubConnectionRelativePath

    private static let store = SchemaVersionedStore<GitHubConnectionRecord>()

    static func url(root: URL) -> URL { root.appendingPathComponent(relativePath) }

    /// What the project's record holds. A record that cannot be read is never taken for "no record": it may stand for a repository
    /// that exists, so the caller must stop and show `problem` rather than create another one.
    static func load(root: URL) -> StoreLoadResult<GitHubConnectionRecord> { store.load(from: url(root: root)) }

    func save(root: URL) throws { try Self.store.save(self, to: Self.url(root: root)) }
}

/// Checks on git's answers during publication.
enum GitPublication {
    /// Paths from `git status --porcelain -z` (the initial commit's review, DEC-018): NUL-separated
    /// and unquoted, so any file name works; a rename or copy is followed by its source path.
    static func changedFiles(porcelainZ: String) -> [String] {
        var paths: [String] = []
        var skipSource = false
        for entry in porcelainZ.split(separator: "\0", omittingEmptySubsequences: true) {
            if skipSource { skipSource = false; continue }
            guard entry.count > 3 else { continue }
            let status = entry.prefix(2)
            paths.append(String(entry.dropFirst(3)))
            if status.contains("R") || status.contains("C") { skipSource = true }
        }
        return paths
    }

    /// The commit a branch points to in `git ls-remote <remote> refs/heads/<branch>` output.
    static func remoteHead(lsRemote: String, branch: String) -> String? {
        for line in lsRemote.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count >= 2, parts[1] == "refs/heads/\(branch)" { return String(parts[0]) }
        }
        return nil
    }

    /// Connected means pushed and linked (DEC-018): the remote branch is the local HEAD and the
    /// branch tracks it.
    static func isPublished(localHead: String, remoteHead: String?, upstream: String, branch: String) -> Bool {
        guard let remoteHead, !localHead.isEmpty else { return false }
        return remoteHead == localHead && upstream == "origin/\(branch)"
    }
}
