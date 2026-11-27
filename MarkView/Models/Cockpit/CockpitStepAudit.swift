import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

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
    static let documentFolders = ["docs/", "tasks/", ProjectPaths.localFolderName + "/"]
    private static let listed = 10

    /// The paths whose content differs between the two snapshots, including files that became clean again, minus documentation.
    static func changedSources(before: Snapshot, after: Snapshot) -> [String] {
        Set(before.files.keys).union(after.files.keys)
            .filter { before.files[$0] ?? "clean" != after.files[$0] ?? "clean" }
            .filter { path in !documentFolders.contains { path.hasPrefix($0) } }
            .sorted()
    }

    /// Who decides whether a step may change source and commit.
    enum ChangeRule: Equatable, Sendable {
        /// A step of a plan made outside Build: the Fix bugs control decides.
        case fixBugsControl
        /// A managed run's step that writes or delivers the change, or a repair attempt: it may, whatever Fix bugs says
        /// (agent-aware-implementation-runs DEC-036, DEC-037).
        case allowed
        /// A managed run's verification step: it may not, whatever Fix bugs says (BUG-132).
        case forbidden
        /// A step that runs at the same time as other steps: it may change nothing, source, commits or scenarios, whatever the controls
        /// say (cockpit-runs-independent-plan-steps-side-by-side REQ-005).
        case group

        /// Whether the step's source changes and commits are looked for.
        func checksSources(_ controls: CockpitControls) -> Bool {
            switch self {
            case .fixBugsControl: !controls.fixBugs
            case .allowed: false
            case .forbidden, .group: true
            }
        }

        var reason: String {
            switch self {
            case .forbidden: "This step only checks the change"
            case .group: "This step runs at the same time as other steps"
            case .fixBugsControl, .allowed: "Fix bugs is off"
            }
        }
    }

    /// What the step did that its controls forbid; empty when nothing was found. Source changes are looked for when `changes`
    /// says so, and scenarios only when creating them is off.
    static func violations(before: Snapshot, after: Snapshot, controls: CockpitControls, changes: ChangeRule = .fixBugsControl) -> [String] {
        var found: [String] = []
        if changes.checksSources(controls), before.isGitRepository, after.isGitRepository {
            let paths = changedSources(before: before, after: after)
            if !paths.isEmpty {
                let shown = paths.prefix(listed).joined(separator: ", ")
                found.append("\(changes.reason), but the step changed \(paths.count) source file(s): \(shown)"
                             + (paths.count > listed ? " and \(paths.count - listed) more" : "") + ".")
            }
            if let was = before.head, let now = after.head, was != now {
                found.append("\(changes.reason), but a commit was made (\(was.prefix(7)) to \(now.prefix(7))).")
            }
        }
        if !controls.createScenarios || changes == .group {
            let created = after.scenarios.subtracting(before.scenarios).sorted()
            if !created.isEmpty {
                found.append("\(changes == .group ? changes.reason : "Create scenarios is off"), but the step created scenario(s): \(created.joined(separator: ", ")).")
            }
        }
        return found
    }

    /// What this audit could not look at, so a clean result is not read as more than it is.
    static func limits(of snapshot: Snapshot, controls: CockpitControls, changes: ChangeRule = .fixBugsControl) -> [String] {
        changes.checksSources(controls) && !snapshot.isGitRepository
            ? ["Source changes were not checked: the project is not a git repository."] : []
    }
}
