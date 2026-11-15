import Foundation

/// What a Cockpit step changed in the project, compared with what its controls allow. The tool gate cannot see the agent's own shell
/// and editor, so the project is compared before and after the step. Foundation only: tools/tests/cockpit-policy-tests.sh checks it.
///
/// This detects; it does not prevent. A step that broke a control fails with the reason, and nothing is rolled back.
enum CockpitStepAudit {
    /// The project at one moment. `files` holds the files git reports as changed or untracked with a hash of their content
    /// ("deleted" for a removed one); a file that is clean is absent.
    struct Snapshot: Equatable {
        var isGitRepository: Bool
        var head: String?
        var files: [String: String]
        var scenarios: Set<String>
    }

    /// Notes and project documentation that MarkView and the agent write while working are not source.
    static let documentFolders = ["docs/", "tasks/", ".dde/"]
    private static let listed = 10

    /// The paths whose content differs between the two snapshots, including files that became clean again, minus documentation.
    static func changedSources(before: Snapshot, after: Snapshot) -> [String] {
        Set(before.files.keys).union(after.files.keys)
            .filter { before.files[$0] ?? "clean" != after.files[$0] ?? "clean" }
            .filter { path in !documentFolders.contains { path.hasPrefix($0) } }
            .sorted()
    }

    /// What the step did that its controls forbid; empty when nothing was found. Source changes are looked for only when
    /// fixing is off and scenarios only when creating them is off.
    static func violations(before: Snapshot, after: Snapshot, controls: CockpitControls) -> [String] {
        var found: [String] = []
        if !controls.fixBugs, before.isGitRepository, after.isGitRepository {
            let paths = changedSources(before: before, after: after)
            if !paths.isEmpty {
                let shown = paths.prefix(listed).joined(separator: ", ")
                found.append("Fix bugs is off, but the step changed \(paths.count) source file(s): \(shown)"
                             + (paths.count > listed ? " and \(paths.count - listed) more" : "") + ".")
            }
            if let was = before.head, let now = after.head, was != now {
                found.append("Fix bugs is off, but a commit was made (\(was.prefix(7)) to \(now.prefix(7))).")
            }
        }
        if !controls.createScenarios {
            let created = after.scenarios.subtracting(before.scenarios).sorted()
            if !created.isEmpty {
                found.append("Create scenarios is off, but the step created scenario(s): \(created.joined(separator: ", ")).")
            }
        }
        return found
    }

    /// What this audit could not look at, so a clean result is not read as more than it is.
    static func limits(of snapshot: Snapshot, controls: CockpitControls) -> [String] {
        !controls.fixBugs && !snapshot.isGitRepository
            ? ["Source changes were not checked: the project is not a git repository."] : []
    }
}
