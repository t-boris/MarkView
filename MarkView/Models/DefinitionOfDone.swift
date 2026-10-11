import Foundation

// What "done" means when an assistant implements a feature: a checklist the person tunes per project
// (`.dde/definition-of-done.json`) and can adjust again just before a run. Each item is required, skipped
// or "ask me first"; the checklist becomes part of the goal the assistant gets, so it knows when it may
// stop and has to show evidence. Foundation only, so tools/tests/definition-of-done-tests.sh compiles it alone.

enum DoneMode: String, Codable, CaseIterable, Identifiable {
    case require, ask, skip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .require: return "Require"
        case .ask: return "Ask me"
        case .skip: return "Skip"
        }
    }
}

struct DoneItem: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    /// What the assistant is told to do, in a sentence or two.
    var instruction: String
    var mode: DoneMode
    /// Built-in items keep their wording up to date with the app; custom ones are the person's.
    var custom: Bool = false
}

struct DefinitionOfDone: Codable, Equatable {
    var items: [DoneItem]

    static let fileName = "definition-of-done.json"

    /// The built-in checklist: a branch of its own from the latest `origin/main`, the feature's records and
    /// GitHub issues kept current, everything committed, a pull request with green CI, tests run. Merging,
    /// version bump, deployment and a browser check are there to switch on.
    static let builtIn: [DoneItem] = [
        DoneItem(id: "branch", title: "Fresh branch from origin/main",
                 instruction: "Fetch, bring main level with origin/main and create a new branch from origin/main for this work; do all the work on that branch and never commit to main.", mode: .require),
        DoneItem(id: "records", title: "Keep the feature's records current",
                 instruction: "Update the feature's specification and statuses (requirements, tasks, decisions, findings) as you work, not only at the end, so they always match the code.", mode: .require),
        DoneItem(id: "issues", title: "Keep GitHub issues in step",
                 instruction: "Update the status of the related GitHub issues as work moves, comment with what was done, and close an issue only when its work is merged.", mode: .require),
        DoneItem(id: "tests", title: "Run the automated tests",
                 instruction: "Run the project's automated tests and the build, fix what fails, and show the result.", mode: .require),
        DoneItem(id: "commit", title: "Everything committed",
                 instruction: "Commit all changes in sensible commits so the working tree is clean at the end, including leftovers of earlier work that belong to this change; ask me about files that do not.", mode: .require),
        DoneItem(id: "pr", title: "Pull request",
                 instruction: "Push the branch and open a pull request that describes the change and has a test plan.", mode: .require),
        DoneItem(id: "ci", title: "CI is green",
                 instruction: "Wait for the pull request's CI checks, fix any failure, and do not finish with a red or pending check.", mode: .require),
        DoneItem(id: "merge", title: "Merge the pull request",
                 instruction: "Merge the pull request once the checks pass, and make sure main contains the work.", mode: .ask),
        DoneItem(id: "version", title: "Bump the version",
                 instruction: "Bump the version according to the project's versioning rules before the final commit.", mode: .skip),
        DoneItem(id: "deploy", title: "Build and deploy",
                 instruction: "Build the release and deploy it the way this project does, then confirm that the deployed version is the new one.", mode: .skip),
        DoneItem(id: "browser", title: "Check it in a MarkView browser tab",
                 instruction: "Open the running app in a MarkView browser tab, walk through the changed flow like a user, and report what you saw.", mode: .skip),
        DoneItem(id: "manual", title: "Manual test checklist for me",
                 instruction: "Give me a short checklist of what to try by hand and wait for my answer before closing the goal.", mode: .skip),
    ]

    static var standard: DefinitionOfDone { DefinitionOfDone(items: builtIn) }

    // MARK: - Storage

    static func url(root: URL) -> URL {
        root.appendingPathComponent(".dde", isDirectory: true).appendingPathComponent(fileName)
    }

    /// The project's checklist, or the standard one when there is none or it cannot be read. Built-in items
    /// a newer app added appear at their place with their default mode; the person's own order and
    /// wording of custom items are kept.
    static func load(root: URL?) -> DefinitionOfDone {
        guard let root, let data = try? Data(contentsOf: url(root: root)),
              let saved = try? JSONDecoder().decode(DefinitionOfDone.self, from: data) else { return .standard }
        return merged(saved)
    }

    static func merged(_ saved: DefinitionOfDone) -> DefinitionOfDone {
        var items: [DoneItem] = []
        let savedByID = Dictionary(saved.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in builtIn {
            if let kept = savedByID[item.id] {
                // Wording follows the app; the choice is the person's.
                items.append(DoneItem(id: item.id, title: item.title, instruction: item.instruction, mode: kept.mode))
            } else {
                items.append(item)
            }
        }
        let builtInIDs = Set(builtIn.map(\.id))
        items += saved.items.filter { $0.custom && !builtInIDs.contains($0.id) }
        return DefinitionOfDone(items: items)
    }

    func save(root: URL) throws {
        let folder = Self.url(root: root).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(root: root), options: .atomic)
    }

    // MARK: - The goal text

    var required: [DoneItem] { items.filter { $0.mode == .require && usable($0) } }
    var askFirst: [DoneItem] { items.filter { $0.mode == .ask && usable($0) } }
    var skipped: [DoneItem] { items.filter { $0.mode == .skip && !$0.custom } }

    private func usable(_ item: DoneItem) -> Bool {
        !item.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One paragraph on one line (it is pasted into a terminal): what must be true before the goal may be
    /// called finished, what to ask me about, and what is not part of this goal. Empty when nothing is set.
    func goalText() -> String {
        var parts: [String] = []
        let needed = required
        if !needed.isEmpty {
            let list = needed.enumerated().map { "(\($0.offset + 1)) \(Self.sentence($0.element.instruction))" }.joined(separator: " ")
            parts.append("Definition of done: the goal is finished only when every one of these is true and you have shown evidence for each (command output, a link or a file): \(list)")
        }
        let asking = askFirst
        if !asking.isEmpty {
            let list = asking.map { Self.sentence($0.instruction) }.joined(separator: " ")
            parts.append("Ask me before you do any of these, and do it only if I say yes: \(list)")
        }
        let not = skipped
        if !not.isEmpty {
            parts.append("Not part of this goal, so do not do them: " + not.map(\.title).joined(separator: "; ") + ".")
        }
        if !needed.isEmpty {
            parts.append("When you stop, print the required items as a checklist with ✓ or ✗ and the evidence; if something blocks an item, say so instead of closing the goal.")
        }
        return parts.joined(separator: " ")
    }

    private static func sentence(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = clean.last else { return clean }
        return ".!?".contains(last) ? clean : clean + "."
    }
}
