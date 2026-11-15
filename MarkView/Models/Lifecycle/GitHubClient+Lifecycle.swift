import Foundation

// What the feature lifecycle reads from GitHub (pull-request events, CI runs). The parsers are Lifecycle's own
// (`LifecycleGitHub`, `LifecycleCICapture`, `LifecycleGit`); the client only supplies the `gh` call, so the Git domain names no
// Lifecycle type.
extension GitHubClient {
    /// Lifecycle events of the pull requests that are, or close, issues `numbers` (one query), and
    /// each such pull request's last commit (whose CI runs `ciCaptures` reads).
    func lifecycleCaptures(numbers: [Int]) async throws -> (captures: [LifecycleGitHub.Capture], heads: [(note: String, sha: String)]) {
        let parts = repo.slug.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !numbers.isEmpty else { return ([], []) }
        let text = try await gh(["api", "graphql", "-f", "query=" + LifecycleGitHub.query(numbers: numbers),
                                 "-f", "owner=" + parts[0], "-f", "name=" + parts[1]])
        let data = Data(text.utf8)
        return (LifecycleGitHub.captures(from: data), LifecycleGitHub.heads(from: data))
    }

    /// The Actions runs of commit `sha`: one call gives both the CI events (request, start, re-runs)
    /// and, when every run succeeded, the time the last one finished.
    func ciRuns(commit sha: String, note: String) async throws -> (captures: [LifecycleGitHub.Capture], passed: Date?) {
        let json = try await gh(["run", "list"] + r + ["--commit", sha, "-L", "100", "--json", LifecycleCICapture.runFields])
        let data = Data(json.utf8)
        return (LifecycleCICapture.captures(runsJSON: data, note: note), LifecycleGit.ciPassed(runsJSON: data))
    }
}
