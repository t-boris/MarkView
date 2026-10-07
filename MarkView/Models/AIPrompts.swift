import Foundation

/// A ready-made request for the assistant in the AI terminal (the buttons above it).
struct TerminalPrompt: Identifiable {
    enum Input {
        /// Works on the project as it is.
        case none
        /// Works on the file open in the editor.
        case activeFile
        /// Asks for a pull request first.
        case pullRequest
    }

    let id: String
    let title: String
    let icon: String
    let help: String
    let input: Input
    /// The prompt; `{file}` is the active file's project-relative path, `{pr}` the chosen
    /// pull request ("#123", or "the pull request of the current branch").
    let template: String

    func text(file: String?, pullRequest: String?) -> String {
        var text = template
            .replacingOccurrences(of: "{file}", with: file ?? "")
            .replacingOccurrences(of: "{pr}", with: pullRequest ?? "the pull request of the current branch")
        if ActionOutputLanguage.current != ActionOutputLanguage.documentLanguage {
            text += " Reply in \(ActionOutputLanguage.current)."
        }
        return text
    }

    static let all: [TerminalPrompt] = [
        TerminalPrompt(
            id: "review-pr", title: "Review PR…", icon: "arrow.triangle.pull",
            help: "Review a pull request: choose it, then the assistant reads it with gh", input: .pullRequest,
            template: "Review {pr} of this repository (read it with `gh pr view` and `gh pr diff`). Summarize what it changes and why, then list bugs, risks, architecture concerns and missing tests, most severe first, each with file:line and a concrete fix. Do not modify any files."),
        TerminalPrompt(
            id: "review-changes", title: "Review changes", icon: "plusminus",
            help: "Review uncommitted changes (git diff and new files)", input: .none,
            template: "Review my uncommitted changes (`git status`, `git diff HEAD` and the untracked files). List bugs, edge cases, leftovers and missing tests, most severe first, each with file:line and a concrete fix. Do not modify any files."),
        TerminalPrompt(
            id: "docs-sync", title: "Docs ↔ code", icon: "doc.text.magnifyingglass",
            help: "Check that the documentation matches the code", input: .none,
            template: "Check whether the documentation of this project (README files, docs folders, other markdown files and doc comments of public APIs) is in sync with the code. List every statement that is outdated, wrong or missing, with the doc's file:line, what the code actually does (file:line), and the corrected text. Do not modify files; ask me before applying fixes."),
        TerminalPrompt(
            id: "explain-file", title: "Explain file", icon: "text.magnifyingglass",
            help: "Explain the file open in the editor", input: .activeFile,
            template: "Explain {file}: its purpose, its main parts, how the rest of the project uses it, and anything surprising or risky in it."),
        TerminalPrompt(
            id: "find-bugs", title: "Find bugs", icon: "ladybug",
            help: "Look for bugs in the file open in the editor", input: .activeFile,
            template: "Look for bugs in {file}: logic errors, unhandled edge cases, error handling, concurrency and resource leaks. For each, give the line, a scenario that triggers it and a fix. Do not modify files yet."),
        TerminalPrompt(
            id: "write-tests", title: "Write tests", icon: "checkmark.seal",
            help: "Write tests for the file open in the editor", input: .activeFile,
            template: "Write tests for {file} using the test framework and conventions this project already uses (ask if it has none). Cover the main behaviour and the edge cases, run them and fix the tests until they pass."),
        TerminalPrompt(
            id: "run-tests", title: "Run tests", icon: "play.circle",
            help: "Run the project's tests and diagnose failures", input: .none,
            template: "Find how this project runs its tests and run them. For every failure, find the root cause and propose a fix; ask me before changing code."),
        TerminalPrompt(
            id: "security", title: "Security review", icon: "lock.shield",
            help: "Security review of the project", input: .none,
            template: "Do a security review of this project: injection, path traversal, secrets in code or logs, unsafe deserialization, authentication and authorization gaps, risky dependencies. Report each finding with file:line, impact and fix, most severe first. Do not modify files."),
        TerminalPrompt(
            id: "update-docs", title: "Update docs", icon: "square.and.pencil",
            help: "Update the documentation for the changes on this branch", input: .none,
            template: "Update the project documentation (README, docs, doc comments) for the changes on the current branch compared to the default branch, plus uncommitted changes. Keep the existing style; show me a summary of what you changed."),
        TerminalPrompt(
            id: "commit-message", title: "Commit message", icon: "text.bubble",
            help: "Propose a commit message for the current changes", input: .none,
            template: "Propose a commit message for the staged changes (all uncommitted changes if nothing is staged): a conventional-commit subject line under 72 characters and a short body explaining why. Do not commit."),
    ]
}

