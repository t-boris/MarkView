import Foundation

/// Agents learn what a MarkView project is — features, requirements, decisions, questions, bugs,
/// prototypes — and add to it through the running app (`ProjectToolRunner`), never by writing the files
/// themselves. Two front doors lead to the same tools: the MCP server `MarkView --mcp-project`, and the
/// command `MarkView --project-call <tool> '<json>'` that a Skill (`SKILL.md`) points agents to when their
/// organisation does not allow MCP servers.
///
/// Both need the app: with no MarkView running there are no tools and no files are touched. Writes go
/// to the project of the window the agent works in, nowhere else.
enum ProjectAgentTools {
    static let serverName = "markview"

    static let instructions = """
    MarkView project tools: MarkView is the documentation environment of this project. These tools read \
    and extend its features, bugs and prototypes in the project of the window you work in. Call \
    markview_guide first (topic "overview") to learn what features, requirements, decisions, questions, \
    bugs and prototypes are and how they are written. Always add features and bugs with the markview_add_* \
    and markview_create_* tools: the app writes the Markdown files in the exact format it reads, with \
    correct ids and links. Do not create or edit files under docs/features or docs/bugs by hand. To turn a \
    prototype into features: markview_get_prototype, then markview_create_feature, then one \
    markview_add_requirement per behaviour (with acceptance criteria). markview_deployments* tools show where the \
    project runs and how each place is doing, and run commands there (read-only ones at once, anything else only after \
    the person approves it in the app); read markview_guide topic "deployments" before using them.
    """

    static let unavailableNote = "MarkView project tools: MarkView is not running for this project, so nothing is available."

    // MARK: - Tools

    private static let feature: [String: Any] = ["type": "string", "description": "Feature slug, as markview_list_features shows it"]

    private static func strings(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": description]
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:],
                             required: [String] = []) -> BrowserAgentTools.Tool {
        BrowserAgentTools.Tool(name: name, description: description, properties: properties, required: required)
    }

    static let tools: [BrowserAgentTools.Tool] = [
        tool("markview_guide", "What MarkView features, requirements, decisions, questions, bugs and prototypes are, their fields, statuses and the workflow. Read the overview first.",
             ["topic": ["type": "string", "enum": guideTopics, "description": "Default: overview"]]),
        tool("markview_project", "The project of this window: folder, number of features, bugs and prototypes."),
        tool("markview_list_features", "The features of the project: slug, title, status, readiness, counts.",
             ["status": ["type": "string", "description": "Only features with this status"]]),
        tool("markview_get_feature", "One feature: overview and every requirement, decision, question and finding with id, title, status and links. With `id`, the full text of that object.",
             ["feature": feature, "id": ["type": "string", "description": "An object id such as REQ-003 or DEC-002"]], required: ["feature"]),
        tool("markview_list_bugs", "The bug reports of the project: id, title, status, severity.",
             ["status": ["type": "string"]]),
        tool("markview_get_bug", "One bug report in full.", ["id": ["type": "string", "description": "BUG-007"]], required: ["id"]),
        tool("markview_list_prototypes", "The prototypes made in Prototype Studio: slug, title, version, screens, whether approved."),
        tool("markview_get_prototype", "A prototype: title, version, screens, assumptions, review history, its file list and SPEC.md when it was exported. With `file`, the text of one prototype file.",
             ["prototype": ["type": "string", "description": "Prototype slug"], "file": ["type": "string", "description": "A path under the prototype's site, e.g. screens/tickets.js"]],
             required: ["prototype"]),
        tool("markview_create_feature", "Create a feature (docs/features/<slug>/overview.md). Returns its slug; then add requirements, decisions and questions to it.",
             ["title": ["type": "string"], "idea": ["type": "string", "description": "The idea in a few sentences: problem, who needs it, scope"],
              "status": ["type": "string", "enum": ["idea", "exploring", "draft", "review", "ready"], "description": "Default: exploring (idea when there is no idea text)"],
              "understanding": ["type": "object", "description": "Dimension → known|partial|unknown|n/a, for what the sources already settle. Dimensions: \(FeatureVocabulary.understanding.joined(separator: ", "))"],
              "source": ["type": "string", "description": "Where it comes from, e.g. \"prototype event-workspace v16\""]],
             required: ["title"]),
        tool("markview_add_requirement", "Add a requirement to a feature: one testable behaviour with acceptance criteria.",
             ["feature": feature, "title": ["type": "string"], "statement": ["type": "string", "description": "\"The system shall …\""],
              "acceptance_criteria": strings("Testable criteria, one per item"),
              "req_type": ["type": "string", "enum": FeatureVocabulary.requirementTypes],
              "status": ["type": "string", "enum": ["draft", "approved"], "description": "Default: draft"],
              "depends_on": strings("Requirement ids of this feature, e.g. REQ-001"), "decisions": strings("Decision ids that shape it"),
              "source": ["type": "string"]],
             required: ["feature", "title", "statement", "acceptance_criteria"]),
        tool("markview_add_decision", "Record a decision of a feature: context, alternatives, the choice and why.",
             ["feature": feature, "title": ["type": "string"], "context": ["type": "string"], "decision": ["type": "string"],
              "reason": ["type": "string"], "alternatives": strings("Other options considered"), "consequences": ["type": "string"],
              "status": ["type": "string", "enum": ["proposed", "accepted"], "description": "Default: proposed"]],
             required: ["feature", "title", "decision", "reason"]),
        tool("markview_add_question", "Ask an open question of a feature, with options and a recommended answer when you have them.",
             ["feature": feature, "question": ["type": "string"], "why": ["type": "string", "description": "Why the answer matters"],
              "q_type": ["type": "string", "enum": FeatureVocabulary.questionTypes], "blocking": ["type": "boolean"],
              "options": ["type": "array", "items": ["type": "object", "properties": ["label": ["type": "string"], "text": ["type": "string"]]]],
              "recommended": ["type": "string"]],
             required: ["feature", "question"]),
        tool("markview_create_bug", "Write a bug report (docs/bugs/BUG-nnn-….md).",
             ["title": ["type": "string"], "summary": ["type": "string"], "severity": ["type": "string", "enum": ["critical", "high", "medium", "low"]],
              "steps": strings("Steps to reproduce"), "expected": ["type": "string"], "actual": ["type": "string"], "environment": ["type": "string"]],
             required: ["title", "summary"]),
        tool("markview_set_status", "Change the status of a feature, or of one of its objects when `id` is given. Statuses are checked against the object's kind.",
             ["feature": feature, "id": ["type": "string"], "status": ["type": "string"]], required: ["feature", "status"]),
    ] + DeploymentAgentTools.tools

    static let toolNames: Set<String> = Set(tools.map(\.name))

    static let profile = BrowserAgentTools.MCPProfile(serverName: serverName, instructions: instructions, unavailableNote: unavailableNote,
                                    tools: tools, probeTool: "markview_project", rechecksApp: true)

    // MARK: - Guide

    static let guideTopics = ["overview", "feature", "requirement", "decision", "question", "bug", "prototype", "workflow", "process", "deployments"]

    static func guide(_ topic: String?) -> String {
        switch topic ?? "overview" {
        case "feature": return featureGuide
        case "requirement": return requirementGuide
        case "decision": return decisionGuide
        case "question": return questionGuide
        case "bug": return bugGuide
        case "prototype": return prototypeGuide
        case "workflow": return workflowGuide
        case "process": return processGuide
        case "deployments": return deploymentsGuide
        default: return overviewGuide
        }
    }

    static let deploymentsGuide = """
    Deployments is the part of MarkView that shows where a project runs and how each place is doing: servers over SSH, \
    this Mac, cloud services (through their CLIs). The person sees CPU, memory, disks, containers, services, checks and logs \
    as gauges; you can see the same and act on it.

    1. Learn what exists: markview_deployments. If nothing is set up, find out where the project runs: read the CI (.github/workflows), \
    the platform files (vercel.json, fly.toml, Procfile, docker-compose, k8s/, terraform), the docs and scripts, ~/.ssh/config, and with \
    `gh` the repository's environments and recent deployments. Do not read or print secret values (only their names), and never ask \
    for a password in chat: MarkView connects with the person's SSH agent or key file.
    2. Propose what you found with markview_deployments_propose (evidence = file and line; `notes` = what you could not find out). \
    Ask the person what is missing (the host, the user, which key). They add the environment in the app.
    3. Look: markview_deployments_status. Then read logs with markview_deployments_logs, or run read-only commands with \
    markview_deployments_run (uptime, df, docker ps, journalctl -u app -n 200 --no-pager, systemctl status, kubectl get, vercel ls…).
    4. Changes (restart a service, edit a file, deploy): call markview_deployments_run with a `purpose`. The app shows the person the \
    exact command and the host and asks; if they refuse you get that answer. Do not try another route to the same effect. Commands that \
    shut a machine down, wipe a disk or pipe a download into a shell never run. After a change, look again with markview_deployments_status \
    and tell the person what the platform shows now.
    """

    static let overviewGuide = """
    MarkView keeps a project's product knowledge as plain Markdown with YAML front matter in the repository.

    - Feature: a folder docs/features/<slug>/ with overview.md and requirements/REQ-nnn.md, decisions/DEC-nnn.md, \
    questions/Q-nnn.md, findings/F-nnn.md, research and references, implementation/plan.md. It starts as an idea \
    and moves idea → exploring → draft → review → resolving → ready → implementing → implemented → verified.
    - Requirement (REQ): one testable behaviour: a statement ("The system shall …") and acceptance criteria.
    - Decision (DEC): a choice with context, alternatives, the decision, the reason and consequences.
    - Question (Q): something unknown that blocks or shapes the feature; answered in the app, then it settles decisions.
    - Finding (F): a problem a review found in the specification (the app's reviewer writes these).
    - Bug: docs/bugs/BUG-nnn-<slug>.md with summary, steps, expected, actual, severity.
    - Prototype: a clickable HTML prototype made in Prototype Studio, in .dde/prototypes/<slug>/ (site/, prototype.json, SPEC.md after approval).

    Rules: never write these files by hand; use the markview_add_* / markview_create_* tools, which write the exact format, \
    unique ids and valid links. Read before you add (markview_list_features, markview_get_feature) so you do not duplicate \
    what exists. Everything you write is for the project of the window you work in. Other topics: \
    \(guideTopics.filter { $0 != "overview" }.joined(separator: ", ")).
    """

    static let featureGuide = """
    A feature is one product capability that can be specified and implemented on its own (a screen flow, a rule set, an \
    integration), small enough for one pull request series. Create it with markview_create_feature: a short title and the \
    idea (problem, who needs it, scope). Set `understanding` for the dimensions your sources already settle \
    (\(FeatureVocabulary.understanding.joined(separator: ", "))): known, partial, unknown or n/a; the rest stays unknown and the \
    app's Explore asks about it. Then add requirements, decisions and questions. Status: leave "exploring" unless the \
    requirements are complete, then "draft"; the app's Review moves it on. Never mark a feature implementing or later.
    """

    static let requirementGuide = """
    markview_add_requirement: title (short noun phrase), statement ("The system shall …", one behaviour, no implementation \
    detail an implementer should decide), acceptance_criteria (each testable, observable, with concrete values), req_type \
    (\(FeatureVocabulary.requirementTypes.joined(separator: ", "))). depends_on lists requirement ids of the same feature; \
    decisions lists the decision ids that shape it. Status draft until the team approves it; use approved only when the \
    source (an approved prototype and its SPEC.md) already settles it. One behaviour per requirement: a screen with five \
    rules is five requirements.
    """

    static let decisionGuide = """
    markview_add_decision: a choice that was made or is proposed: context (why it came up), alternatives (the other options), \
    decision (what was chosen), reason, consequences. Status proposed unless the source states it as settled (accepted). \
    Do not record implementation trivia; record what would be expensive to reverse or that the team might argue about.
    """

    static let questionGuide = """
    markview_add_question: a question only a person can answer, not something the documents or prototype already show. Give \
    `why` it matters, `options` (label A, B… and text) and a `recommended` label when you have a view. blocking: true only \
    when the feature cannot be built correctly without the answer. The user answers in MarkView's Explore.
    """

    static let bugGuide = """
    markview_create_bug: title, summary, severity (critical = data loss, security or outage; high = main flow broken; medium; \
    low), steps (numbered, reproducible), expected, actual, environment. Read markview_list_bugs first to avoid duplicates. \
    The app writes docs/bugs/BUG-nnn-<slug>.md and numbers it.
    """

    static let prototypeGuide = """
    Prototypes are made and reviewed by people in Prototype Studio (AI Tools → Prototype). You can read them: \
    markview_list_prototypes, then markview_get_prototype (screens, assumptions, review history, files, SPEC.md). \
    To turn a prototype into features: read it and its SPEC.md, group the screens and flows into features (one per \
    capability, not one per screen), create each with markview_create_feature (source: "prototype <slug> v<n>"), then \
    add a requirement per rule or behaviour the prototype shows (markview_add_requirement), with acceptance criteria taken from its states, validations \
    and permissions. Record the choices the review history shows as decisions (accepted), and anything the prototype leaves \
    open as questions. Name the screen or file in the requirement text so the trace back to the prototype stays visible.
    """

    static let workflowGuide = """
    Explore (the app asks questions until the feature is understood) → Review (the app reviews the specification from many \
    perspectives and the findings are resolved into the requirements) → Build (a plan of issues, then implementation by an \
    agent, with status, commits and pull requests tracked). Your part is usually to create or extend the specification and \
    to implement a ready feature; the app does Explore and Review. When you implement, treat approved requirements and \
    accepted decisions as binding, and answered questions as settled.
    """

    /// How work on a MarkView project is done, as MarkView tracks it. The project's own rules (CLAUDE.md, AGENTS.md,
    /// CONTRIBUTING.md) come first and may differ; this is the default.
    static let processGuide = """
    The project's own instructions (CLAUDE.md, AGENTS.md, CONTRIBUTING.md) come first; where they are silent, work like this.

    1. Read first: the feature (markview_get_feature) with its approved requirements, accepted decisions and answered questions \
    are binding. Open questions are not yours to settle; ask the user, or add the question with markview_add_question.
    2. Branch: one branch per feature or bug, from an up-to-date main: feat/<feature-slug>, fix/<BUG-id>-<slug>, docs/<slug>. \
    Never commit to main directly.
    3. Work in the branch in small commits; keep the change within the feature's requirements. A decision you must make that the \
    specification does not cover: record it with markview_add_decision (status proposed) instead of burying it in code.
    4. Verify: build and run the project's checks and tests, then check each acceptance criterion of the requirements you implemented.
    5. Pull request: one per feature or bug, into main; describe the change, link the feature (slug and REQ ids), the version if the \
    project has one, and the test plan. Merge it after the checks pass if the project's rules say so.
    6. Statuses: MarkView records implementing, implemented, review, CI, merged and verified from git and GitHub, so do not set them \
    yourself (markview_set_status stops at ready on purpose). Mark requirements approved only when the user did.
    7. Report: say what you did, the pull request link, whether it is merged, and anything left open.
    """

    // MARK: - Writing the files

    /// The body of a requirement file.
    static func requirementBody(statement: String, criteria: [String]) -> String {
        "## Statement\n\n\(statement)\n\n## Acceptance Criteria\n\n" + criteria.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n"
    }

    static func decisionBody(context: String, alternatives: [String], decision: String, reason: String, consequences: String) -> String {
        """
        ## Context

        \(context)

        ## Alternatives

        \(alternatives.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        ## Decision

        \(decision)

        ## Reason

        \(reason)

        ## Consequences

        \(consequences)
        """
    }

    static func questionBody(question: String, why: String, options: [(label: String, text: String)], recommended: String) -> String {
        var body = "## Question\n\n\(question)\n\n## Why it matters\n\n\(why)\n"
        if !options.isEmpty {
            body += "\n## Options\n\n" + options.map { "- **\($0.label)**: \($0.text)" }.joined(separator: "\n") + "\n"
        }
        if !recommended.isEmpty { body += "\n## Recommended\n\n\(recommended)\n" }
        return body
    }

    static func bugBody(title: String, summary: String, steps: [String], expected: String, actual: String, environment: String) -> String {
        var sections: [(String, String)] = [
            ("Summary", summary),
            ("Steps to reproduce", steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")),
            ("Expected", expected), ("Actual", actual),
            ("Environment", environment.isEmpty ? "Unknown" : environment),
        ]
        sections.removeAll { $0.1.isEmpty }
        return "# \(title)\n\n" + sections.map { "## \($0.0)\n\n\($0.1)" }.joined(separator: "\n\n")
    }

    // MARK: - Arguments

    /// Why an argument is wrong, in words for the agent; nil when it is fine.
    struct Invalid: Error { let message: String }

    static let maxText = 20_000

    static func text(_ args: [String: Any], _ key: String, required: Bool = false) throws -> String {
        let value = (args[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if required && value.isEmpty { throw Invalid(message: "`\(key)` is required.") }
        if value.count > maxText { throw Invalid(message: "`\(key)` is too long (\(value.count) characters; the limit is \(maxText)).") }
        return value
    }

    static func list(_ args: [String: Any], _ key: String, limit: Int = 40) throws -> [String] {
        guard let raw = args[key] else { return [] }
        guard let items = raw as? [String] else { throw Invalid(message: "`\(key)` must be an array of strings.") }
        let cleaned = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if cleaned.count > limit { throw Invalid(message: "`\(key)` has \(cleaned.count) items; the limit is \(limit).") }
        if let long = cleaned.first(where: { $0.count > 2_000 }) { throw Invalid(message: "An item of `\(key)` is too long: \(long.prefix(60))…") }
        return cleaned
    }

    static func choice(_ args: [String: Any], _ key: String, in allowed: [String], default fallback: String) throws -> String {
        guard let value = (args[key] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return fallback }
        guard allowed.contains(value) else { throw Invalid(message: "`\(key)` must be one of: \(allowed.joined(separator: ", ")).") }
        return value
    }

    /// A feature slug exactly as listed: no path parts.
    static func isPlainName(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.contains("\\") && !value.hasPrefix(".") && !value.contains("..")
    }

    /// Valid statuses for the object an id names ("REQ-003" → requirement statuses); nil for an unknown id.
    static func statuses(forObjectID id: String) -> [String]? {
        switch id.split(separator: "-").first.map(String.init) {
        case "REQ": return FeatureVocabulary.requirementStatuses
        case "Q": return FeatureVocabulary.questionStatuses
        case "DEC": return FeatureVocabulary.decisionStatuses
        case "F": return FeatureVocabulary.findingStatuses
        default: return nil
        }
    }

    /// Statuses an agent may set on a feature: never the implementation stages, which the app records.
    static let agentFeatureStatuses = ["idea", "exploring", "draft", "review", "ready"]

    // MARK: - Command line

    /// `MarkView --project-call <tool> ['<json>']`: one tool call from a shell, for agents that cannot use MCP
    /// servers. Prints the reply; exit status 1 when the call failed.
    static func runCall(arguments: [String]) -> Never {
        guard let flag = arguments.firstIndex(of: "--project-call"), flag + 1 < arguments.count else {
            print("usage: MarkView --project-call <tool> ['<json arguments>']   (tools: \(tools.map(\.name).joined(separator: ", ")))")
            exit(2)
        }
        let name = arguments[flag + 1]
        var args: [String: Any] = [:]
        if flag + 2 < arguments.count, !arguments[flag + 2].hasPrefix("--") {
            guard let data = arguments[flag + 2].data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                print("The arguments are not a JSON object.")
                exit(2)
            }
            args = object
        }
        guard toolNames.contains(name) else {
            print("Unknown tool. Tools: \(tools.map(\.name).joined(separator: ", "))")
            exit(2)
        }
        let reply = BrowserAgentTools.callApp(profile: profile, arguments: arguments, tool: name, args: args)
        print(reply.text)
        exit(reply.isError ? 1 : 0)
    }

    // MARK: - Skill

    /// The text of the Skill (`SKILL.md`) that teaches agents the same, for those without MCP.
    static func skillText(executable: String) -> String {
        """
        ---
        name: markview
        description: Read and extend the MarkView project you are working in: features, requirements, decisions, questions, bugs and prototypes. Use it to turn a prototype or an idea into MarkView features, to add requirements or bugs, or to see what the project's specification says.
        ---

        # MarkView project tools

        MarkView is the documentation environment of this project. Its features, bugs and prototypes are Markdown files in the \
        repository, and MarkView must write them so that they keep its exact format. You do that by running the command below; \
        never create or edit files under docs/features or docs/bugs by hand.

        The command works only while MarkView is running with this project open; otherwise it prints that nothing is available \
        and touches nothing. It writes only to the project of the window you work in.

        ```
        "\(executable)" --project-call <tool> '<json arguments>'
        ```

        Start with `--project-call markview_guide '{"topic":"overview"}'`, then read before you add.

        Tools: \(tools.map { "`\($0.name)`" }.joined(separator: ", ")).

        Each tool's arguments:
        \(tools.map { "- `\($0.name)`: " + $0.description + " Arguments: " + argumentSummary($0) }.joined(separator: "\n"))

        ## Turning a prototype into features

        1. `markview_list_prototypes`, then `markview_get_prototype` with `{"prototype":"<slug>"}` (read SPEC.md and screens).
        2. `markview_list_features` to see what already exists.
        3. For each capability (not each screen): `markview_create_feature`, then one `markview_add_requirement` per behaviour, with \
        testable acceptance criteria; `markview_add_decision` for choices; `markview_add_question` for what the prototype leaves open.
        4. Report the slugs you created.

        ## Deployments

        `deployments` in the guide (`--project-call markview_guide '{"topic":"deployments"}'`): where the project runs and how each place \
        is doing. `markview_deployments` shows it, `markview_deployments_propose` suggests a place you found, `markview_deployments_status` \
        looks now, `markview_deployments_logs` and `markview_deployments_run` read logs and run commands. Read-only commands run at once; \
        anything else waits for the person's yes in the app. Never put a password, token or key into a call.

        ## How work is done

        The project's own instructions (CLAUDE.md, AGENTS.md, CONTRIBUTING.md) come first. Where they are silent: read the feature \
        and treat approved requirements, accepted decisions and answered questions as binding; work on one branch per feature or bug \
        (feat/<slug>, fix/<BUG-id>-<slug>), never on main; verify against the acceptance criteria; open one pull request per feature or \
        bug; leave status changes after "ready" to MarkView, which records them from git and GitHub. The full text: \
        `--project-call markview_guide '{"topic":"process"}'`.
        """
    }

    private static func argumentSummary(_ tool: BrowserAgentTools.Tool) -> String {
        if tool.properties.isEmpty { return "none." }
        return tool.properties.keys.sorted().map { $0 + (tool.required.contains($0) ? " (required)" : "") }.joined(separator: ", ") + "."
    }
}
