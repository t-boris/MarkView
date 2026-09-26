import Foundation

/// Long prompts for the AI Tools menu, sent to the assistant in the AI terminal.
enum AIPrompts {
    /// Full codebase audit prompt — generates comprehensive architecture documentation
    static let codebaseAuditPrompt = """
You are a principal software architect, senior staff engineer, codebase auditor, technical writer, systems analyst, and documentation generator.

Your task is to scan the CURRENT DIRECTORY recursively, analyze the entire codebase, reverse-engineer its architecture, and generate a complete, structured documentation set into a dedicated docs folder inside the project.

Your goal is not to produce a shallow summary. Your goal is to create a documentation system that allows a new senior engineer, architect, or AI agent to understand this project deeply and safely work on it.

PRIMARY OBJECTIVE: Analyze the full codebase and generate comprehensive project documentation including:
1. high-level architecture
2. module-by-module/component-by-component documentation
3. internal interfaces and responsibilities
4. external APIs and third-party integrations
5. data models and schema understanding
6. runtime flows and lifecycle behavior
7. configuration and environment model
8. build, deployment, and operational model
9. risks, issues, technical debt, and weak points
10. missing documentation / ambiguity / inferred areas
11. recommendations for improvement
12. machine-friendly structured index for future AI use

Generate documentation into: ./docs/generated-architecture/

OPERATING MODE: Work as an autonomous architecture and documentation agent.
- Recursively inspect the full directory
- Identify tech stack, project boundaries, subprojects
- Inspect source code, configs, manifests, scripts, infrastructure, tests, Docker, CI/CD, schemas, API specs, migrations
- Infer architecture from real code behavior
- Trace imports, dependencies, service boundaries, data flow
- Distinguish confirmed vs inferred vs unknown
- Generate documentation incrementally and coherently

RULES:
1. Do not invent functionality not supported by code
2. Distinguish: Confirmed from code / Confirmed from config / Confirmed from docs / Inferred from patterns / Unknown
3. Prefer evidence-based documentation
4. Work in phases for large repos
5. Document multiple services separately and as a system
6. Focus on source-of-truth code, deprioritize generated/vendor files
7. Treat tests as evidence of expected behavior
8. Treat CI/CD, Docker, IaC as part of architecture

PHASES:
Phase 1 — Repository Discovery: scan structure, languages, frameworks, package managers, mono/single repo, entry points, build scripts, infrastructure, configs, DB files, API schemas, env files, existing docs, test suites
Phase 2 — Architectural Reconstruction: system purpose, architectural style, components, module boundaries, dependency direction, communication patterns, request/response/async/event flows, persistence, caching, auth, integrations, observability
Phase 3 — Component-Level Analysis: for each component document purpose, responsibility, files, interfaces, classes/functions, inputs/outputs, dependencies, side effects, state, data contracts, lifecycle, error handling, extension points, issues
Phase 4 — External Interfaces: REST/GraphQL/gRPC APIs, webhooks, queues, DB connections, cache, third-party SaaS, payment/auth/cloud providers, analytics, email/SMS, feature flags, file storage
Phase 5 — Data Model and Configuration: entities, DTOs, DB schema, migrations, ORM models, validation, event payloads, config, env vars, feature flags, secrets, runtime modes
Phase 6 — Operational Model: local dev, build pipeline, test workflow, CI/CD, deployment targets, Docker/K8s, migrations, release, rollback, observability
Phase 7 — Risk Analysis: coupling, separation of concerns, implicit/circular dependencies, god modules, duplicated logic, brittle configs, hidden assumptions, missing validation, weak error handling, concurrency hazards, auth/security risks, missing idempotency/timeouts, test gaps, dead code, stale docs, scalability bottlenecks
Phase 8 — Documentation Output: generate full docs structure with index, executive summary, repo map, system overview, architecture, runtime flows, component docs, interfaces, data model, operations, risks, recommendations, appendix, and architecture-index.json

OUTPUT STRUCTURE:
docs/generated-architecture/
  00-index.md, 01-executive-summary.md, 02-repository-map.md, 03-system-overview.md, 04-high-level-architecture.md, 05-runtime-flows.md
  06-components/ (component-<name>.md per component)
  07-interfaces/ (external-apis.md, internal-interfaces.md, events-and-messaging.md)
  08-data/ (domain-model.md, configuration-model.md, persistence-model.md)
  09-operations/ (local-development.md, build-and-release.md, deployment-and-runtime.md, observability.md)
  10-risks/ (technical-debt.md, architecture-risks.md, security-and-reliability-risks.md)
  11-recommendations/ (improvement-roadmap.md, quick-wins.md)
  12-appendix/ (terminology.md, unresolved-questions.md, evidence-and-assumptions.md)
  architecture-index.json

Use Mermaid diagrams, tables, clear headings, evidence-based phrasing. Prefer: "Confirmed in…", "Appears to…", "Likely… based on…", "Could not be confirmed from code", "Needs manual verification".

Now begin by scanning the current directory and building the repository inventory. Then generate the full documentation set.
"""

}

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

