import Foundation

// Start a Project from Scratch (docs/features/start-a-project-from-scratch): the rules that need
// no UI, no process and no main actor, so tools/tests/new-project-tests.sh compiles them alone.

/// A new project from its first idea until its folder exists (DEC-015). The clarification lives
/// in a draft workspace next to this record; bootstrap copies it into the project and removes
/// the draft only after every local stage succeeded (DEC-019).
struct ProjectDraft: Codable, Equatable, Identifiable {
    enum Stage: String, Codable {
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

/// Names of the new folder and of its GitHub repository.
enum ProjectNaming {
    /// "Recipe Planner for Families" → "recipe-planner-for-families"; Cyrillic and accents are
    /// transliterated; "new-project" when nothing usable is left.
    static func suggestedFolderName(_ title: String) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? title
        let base = latin.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        var name = String(base).split(separator: "-").prefix(6).joined(separator: "-")
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        return name.isEmpty ? "new-project" : name
    }

    /// Why `name` cannot be the new folder's name, or nil when it can.
    static func folderNameProblem(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a folder name." }
        if name != name.trimmingCharacters(in: .whitespaces) { return "The name cannot start or end with a space." }
        if name == "." || name == ".." { return "Choose another name." }
        if name.hasPrefix(".") { return "A name starting with a dot would be hidden in Finder." }
        if name.contains("/") || name.contains(":") { return "The name cannot contain / or :." }
        if name.utf8.count > 255 { return "The name is too long." }
        return nil
    }

    /// Why `name` cannot be a GitHub repository name, or nil when it can.
    static func repoNameProblem(_ name: String) -> String? {
        if name.isEmpty { return "Enter a repository name." }
        if name.count > 100 { return "At most 100 characters." }
        if name == "." || name == ".." { return "Choose another name." }
        if name.lowercased().hasSuffix(".git") { return "The name cannot end with .git." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Use letters, digits, '.', '-' and '_' only."
        }
        return nil
    }

    /// The folder name as a valid repository name.
    static func suggestedRepoName(_ folderName: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var name = String(folderName.map { allowed.contains($0) ? $0 : "-" })
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if name.lowercased().hasSuffix(".git") { name = String(name.dropLast(4)) }
        return name.isEmpty ? "new-project" : String(name.prefix(100))
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
    static let gitignore = ".dde/\n.DS_Store\n"

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

    /// "owner/name" from git@github.com:owner/name.git or https://github.com/owner/name(.git).
    static func githubSlug(fromRemoteURL url: String) -> String? {
        guard let range = url.range(of: #"github\.com[:/]([^/\s]+)/([^/\s]+?)(\.git)?/?$"#, options: .regularExpression) else { return nil }
        var tail = String(url[range]).dropFirst("github.com".count + 1)
        if tail.hasSuffix("/") { tail = tail.dropLast() }
        if tail.hasSuffix(".git") { tail = tail.dropLast(4) }
        return String(tail)
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

    static let relativePath = ".dde/github-connection.json"
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
