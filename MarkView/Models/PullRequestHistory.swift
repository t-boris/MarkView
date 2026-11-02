import Foundation

/// The pull-request part of the history that "I Need to Understand" hands to the answering
/// agent (`XRaySearch.provenance`).
///
/// Pull requests come from `gh`. MarkView runs `gh` only when the GitHub integration is turned
/// on (`GitHubSettings.enabled`, off by default). With it off nothing is fetched and the answer
/// is told that no PR data was available, as it is when `gh` is missing or offline (DEC-001:
/// degrade gracefully). `fetch` is the only place `gh` is started, so a caller that passes
/// `enabled: false` cannot start it.
enum PullRequestHistory {
    struct Section: Equatable {
        /// Appended to the history context; starts with a blank line.
        var text: String
        /// GitHub URLs of the pull requests listed in `text`. The answer may cite only these.
        var urls: Set<String>
    }

    /// What `fetch` returns: the exit status and standard output of `gh pr list --json ...`.
    typealias Fetched = (status: Int32, stdout: String)

    static let integrationOffNote = "PR data unavailable: the GitHub integration is turned off in MarkView settings, so pull requests were not read. Do not invent PRs."
    static let unavailableNote = "PR data unavailable (gh missing, unauthenticated, offline, or no GitHub repository). Do not invent PRs."

    /// At most this many pull requests, each body cut to `bodyLimit` characters, so the list
    /// stays bounded without truncating the JSON halfway through a record.
    static let recordLimit = 50
    static let bodyLimit = 1600

    static func section(enabled: Bool, fetch: () async -> Fetched) async -> Section {
        guard enabled else { return Section(text: "\n\n" + integrationOffNote, urls: []) }
        let output = await fetch()
        guard output.status == 0,
              let values = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [[String: Any]] else {
            return Section(text: "\n\n" + unavailableNote, urls: [])
        }
        var urls = Set<String>()
        let records = values.prefix(recordLimit).map { value -> [String: Any] in
            var value = value
            value["body"] = String((value["body"] as? String ?? "").prefix(bodyLimit))
            if let url = value["url"] as? String { urls.insert(url) }
            return value
        }
        let data = (try? JSONSerialization.data(withJSONObject: records)) ?? Data()
        var text = "\n\nRead-only pull requests:\n" + String(decoding: data, as: UTF8.self)
        if records.isEmpty { text += "\nNo pull requests found." }
        return Section(text: text, urls: urls)
    }
}
