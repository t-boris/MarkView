import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

// Start a Project from Scratch (docs/features/start-a-project-from-scratch): the rules that need
// no UI, no process and no main actor, so tools/tests/new-project-tests.sh compiles them alone.

/// A new project from its first idea until its folder exists (DEC-015). The clarification lives
/// in a draft workspace next to this record; bootstrap copies it into the project and removes
/// the draft only after every local stage succeeded (DEC-019).
struct ProjectDraft: Codable, Equatable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable {
        /// Adaptive questions; the brief is not confirmed yet.
        case clarifying
        /// The user confirmed the brief (DEC-003, DEC-016); the destination is chosen next.
        case confirmed
        /// Bootstrap started: a retry continues in `createdPath` (DEC-019).
        case creating
    }

    var id: UUID
    var created: Date
    var updated: Date
    /// What the user wrote first.
    var idea: String
    /// The project's title, from the clarified specification.
    var title: String
    /// The specification's folder in the draft workspace (docs/features/<slug>).
    var slug: String?
    var stage: Stage
    /// Chosen destination: parent folder and the new folder's name (DEC-009).
    var parentPath: String?
    var folderName: String?
    /// The folder bootstrap created, set right after creating it: only this path is written again on retry.
    var createdPath: String?
    var filesWritten: Bool
    var gitInitialized: Bool
    var lastError: String?

    init(idea: String, now: Date = Date()) {
        id = UUID()
        created = now
        updated = now
        self.idea = idea
        title = ""
        stage = .clarifying
        filesWritten = false
        gitInitialized = false
    }

    /// What the welcome screen shows for an unfinished draft.
    var displayTitle: String {
        if !title.isEmpty { return title }
        let line = idea.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Untitled project" }
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }

    /// Where the flow resumes.
    var resumeDescription: String {
        switch stage {
        case .clarifying: return "clarifying the idea"
        case .confirmed: return "brief confirmed — choose where to create it"
        case .creating: return lastError == nil ? "creating the project" : "creation stopped — retry"
        }
    }
}

/// When the brief may be confirmed (DEC-016): a stated goal and no open question marked
/// blocking. Non-blocking questions stay open and are carried into the project.
enum ProjectConfirmation {
    struct OpenQuestion: Equatable {
        var id: String
        var title: String
        var blocking: Bool
    }

    static func blockers(_ open: [OpenQuestion]) -> [OpenQuestion] { open.filter(\.blocking) }

    static func canConfirm(goal: String, open: [OpenQuestion]) -> Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && blockers(open).isEmpty
    }
}

/// The files bootstrap writes next to the specification (DEC-023).
enum ProjectFoundation {
    /// MarkView's local metadata never goes into the project's history.
    static let gitignore = ProjectPaths.localFolderName + "/\n.DS_Store\n"

    /// A "## Name" section of a Markdown body (the overview's Idea, Problem, Scope).
    static func section(_ name: String, of body: String) -> String {
        var inSection = false
        var lines: [String] = []
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if inSection { break }
                inSection = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased()
                continue
            }
            if inSection { lines.append(line) }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readme(title: String, idea: String, problem: String, scope: String, specificationPath: String,
                       requirements: [(id: String, title: String)], openQuestions: [(id: String, title: String)]) -> String {
        var text = "# \(title)\n\n\(idea.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        let problem = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        if !problem.isEmpty { text += "\n## Problem\n\n\(problem)\n" }
        let scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scope.isEmpty { text += "\n## Scope\n\n\(scope)\n" }
        text += "\n## Specification\n\nThe confirmed brief, decisions and requirements are in "
        text += "[`\(specificationPath)/`](\(specificationPath)/overview.md). Open this folder in MarkView to continue them.\n"
        if !requirements.isEmpty {
            text += "\n### Requirements\n\n" + requirements.map { "- \($0.id) \($0.title)" }.joined(separator: "\n") + "\n"
        }
        if !openQuestions.isEmpty {
            text += "\n### Open questions\n\n" + openQuestions.map { "- \($0.id) \($0.title)" }.joined(separator: "\n") + "\n"
        }
        return text
    }
}

