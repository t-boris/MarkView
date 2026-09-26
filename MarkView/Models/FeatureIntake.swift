import Foundation

/// The standard ways into the project (user request): dump everything you know and the AI
/// turns it into a feature or a bug report (each with its GitHub issue), kept as Markdown;
/// "I need to understand …" is answered by the X-Ray's ⚡ search instead of a document.
enum IntakeKind: String, Identifiable, CaseIterable {
    case feature, bug, understand
    var id: String { rawValue }

    var title: String {
        switch self {
        case .feature: return "New Feature"
        case .bug: return "New Bug"
        case .understand: return "I Need to Understand"
        }
    }

    var prompt: String {
        switch self {
        case .feature: return "Describe the feature as you know it — what, why, for whom, ideas, constraints, links, anything. Drop files and screenshots too."
        case .bug: return "What goes wrong? Where, when, what you expected, what happened instead, error messages, logs, screenshots."
        case .understand: return "What do you need to understand about this project? The X-Ray searches the code, documents and deployment for it, marks what takes part and answers on the right."
        }
    }
}

/// A "New …" to start: its kind and, when it comes from somewhere, the material already filled in.
struct IntakeRequest: Identifiable {
    let id = UUID()
    var kind: IntakeKind
    var text = ""
    var linkedIssue: Int?
    var attachments: [URL] = []
}

extension FeatureAssistant {
    struct IntakeOutcome {
        /// The file to open (overview, bug report, research answer).
        var file: URL?
        var feature: String?
        var issue: String?
    }

    // MARK: New Feature

    /// Build a feature from everything the user wrote: overview, understanding, first
    /// requirements and questions, the material as a source; then its GitHub issue.
    /// `linkedIssue`: the feature starts from an existing GitHub issue (no new issue is filed).
    func newFeature(from dump: String, attachments: [URL], linkedIssue: Int? = nil) async -> IntakeOutcome? {
        guard store.root != nil else { return nil }
        let prompt = """
        ## Everything the user wrote about a new feature

        \(dump.prefix(40_000))

        Attachments: \(attachments.map(\.lastPathComponent).joined(separator: ", ").isEmpty ? "none" : attachments.map(\.lastPathComponent).joined(separator: ", "))

        Task: turn this into the start of a feature specification. Read the project's documentation and code \
        (read-only) where it helps you understand what exists. Give: a short feature title; the idea restated \
        clearly; the problem; the scope (in / out); how well each understanding dimension is known from this \
        material; the requirements it already states or clearly implies (0–6, each with acceptance criteria); \
        and the 1–3 most important open questions with options.
        """
        let questionSchema: [String: Any] = ["type": "object",
            "properties": ["text": ["type": "string"], "why": ["type": "string"],
                           "q_type": ["type": "string", "enum": FeatureVocabulary.questionTypes],
                           "blocking": ["type": "boolean"],
                           "options": ["type": "array", "items": ["type": "object",
                               "properties": ["label": ["type": "string"], "text": ["type": "string"],
                                              "pros": ["type": "array", "items": ["type": "string"]],
                                              "cons": ["type": "array", "items": ["type": "string"]]],
                               "required": ["label", "text", "pros", "cons"]]]],
            "required": ["text", "why", "q_type", "blocking", "options"]]
        let requirement: [String: Any] = ["type": "object",
            "properties": ["title": ["type": "string"], "statement": ["type": "string"],
                           "req_type": ["type": "string", "enum": FeatureVocabulary.requirementTypes],
                           "acceptance_criteria": ["type": "array", "items": ["type": "string"]]],
            "required": ["title", "statement", "req_type", "acceptance_criteria"]]
        let schema: [String: Any] = ["type": "object",
            "properties": ["title": ["type": "string"], "idea": ["type": "string"], "problem": ["type": "string"],
                           "scope": ["type": "string"],
                           "understanding": ["type": "array", "items": ["type": "object",
                               "properties": ["dimension": ["type": "string", "enum": FeatureVocabulary.understanding],
                                              "state": ["type": "string", "enum": FeatureVocabulary.understandingStates]],
                               "required": ["dimension", "state"]]],
                           "requirements": ["type": "array", "items": requirement],
                           "questions": ["type": "array", "items": questionSchema]],
            "required": ["title", "idea", "problem", "scope", "understanding", "requirements", "questions"]]
        guard let object = await structured("intake:feature", prompt: prompt, schema: schema),
              let slug = store.createFeature(title: object["title"] as? String ?? "New feature", idea: object["idea"] as? String ?? dump)
        else { return nil }
        let problem = object["problem"] as? String ?? ""
        let scope = object["scope"] as? String ?? ""
        store.updateFeature(slug) { front, body in
            front.set("provenance", "Created from the feature intake")
            body = body.replacingOccurrences(of: "## Problem\n\n## Scope\n", with: "## Problem\n\n\(problem)\n\n## Scope\n\n\(scope)\n")
        }
        let states = (object["understanding"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) {
            if let d = $1["dimension"] as? String, let s = $1["state"] as? String { $0[d] = s }
        }
        store.setUnderstanding(slug, states)
        // The raw material stays as the feature's first source.
        let intake = await ingest(.text(title: "Original request", text: dump, kind: "intake"), into: slug)
        for r in object["requirements"] as? [[String: Any]] ?? [] {
            let criteria = (r["acceptance_criteria"] as? [String] ?? []).map { "- [ ] \($0)" }.joined(separator: "\n")
            store.create(.requirement, in: slug, title: r["title"] as? String ?? "Requirement",
                         fields: [("req_type", .string(r["req_type"] as? String ?? "functional")), ("depends_on", .list([])),
                                  ("decisions", .list([])), ("sources", .list(intake.map { [.string($0)] } ?? [])), ("issues", .list([]))],
                         body: "## Statement\n\n\(r["statement"] as? String ?? "")\n\n## Acceptance Criteria\n\n\(criteria)\n",
                         provenance: "Extracted from the feature intake")
        }
        for q in object["questions"] as? [[String: Any]] ?? [] {
            let text = q["text"] as? String ?? ""
            let options = (q["options"] as? [[String: Any]] ?? []).map { o -> YAMLValue in
                .map([("label", .string(o["label"] as? String ?? "")), ("text", .string(o["text"] as? String ?? "")),
                      ("pros", .list((o["pros"] as? [String] ?? []).map { .string($0) })),
                      ("cons", .list((o["cons"] as? [String] ?? []).map { .string($0) }))])
            }
            store.create(.question, in: slug, title: String(text.prefix(140)),
                         fields: [("q_type", .string(q["q_type"] as? String ?? "clarification")),
                                  ("priority", .string(q["blocking"] as? Bool == true ? "blocking" : "normal")),
                                  ("origin", .string("explore")), ("blocking", .list([])), ("options", .list(options))],
                         body: "## Question\n\n\(text)\n\n## Why it matters\n\n\(q["why"] as? String ?? "")\n",
                         provenance: "Generated by AI (feature intake)")
        }
        for url in attachments { await ingest(.file(url), into: slug) }
        // Its GitHub issue: the one it came from, or a new one when the integration is on.
        var issueRef: String?
        if let linkedIssue {
            issueRef = "#\(linkedIssue)"
            store.updateFeature(slug) { front, _ in front.set("issue", "#\(linkedIssue)") }
        } else if let client = gitHubClient(), let feature = store.feature(slug) {
            var body = "\(object["idea"] as? String ?? "")\n\n### Problem\n\n\(problem)\n\n### Scope\n\n\(scope)\n"
            let requirements = feature.list(.requirement)
            if !requirements.isEmpty { body += "\n### Initial requirements\n\n" + requirements.map { "- \($0.id) \($0.title)" }.joined(separator: "\n") + "\n" }
            let questions = feature.list(.question)
            if !questions.isEmpty { body += "\n### Open questions\n\n" + questions.map { "- [ ] \($0.id) \($0.title)" }.joined(separator: "\n") + "\n" }
            body += "\n_Specification: `\(store.relativePath(feature.folder))/`_"
            if let url = await Self.createIssue(client, title: "Feature: \(feature.title)", body: body, label: "enhancement"),
               let number = url.split(separator: "/").last {
                issueRef = "#\(number)"
                store.updateFeature(slug) { front, _ in front.set("issue", "#\(number)") }
            }
        }
        return IntakeOutcome(file: store.feature(slug)?.overviewURL, feature: slug, issue: issueRef)
    }

    /// Create an issue with a label, or without it when the repository has no such label.
    private static func createIssue(_ client: GitHubClient, title: String, body: String, label: String) async -> String? {
        if let url = try? await client.createIssue(title: title, body: body, labels: [label]) { return url }
        return try? await client.createIssue(title: title, body: body)
    }

    // MARK: New Bug

    /// A bug report from the user's description: reproduction, expected and actual behaviour,
    /// severity and the code it likely lives in; written to docs/bugs/ and filed on GitHub.
    /// `linkedIssue`: the bug is already on GitHub — the report links it (and, with
    /// `commentOnIssue`, adds the analysis there as a comment) instead of filing a new issue.
    func newBug(from dump: String, attachments: [URL], linkedIssue: Int? = nil, commentOnIssue: Bool = false) async -> IntakeOutcome? {
        guard let root = store.root else { return nil }
        let folder = root.appendingPathComponent("docs/bugs", isDirectory: true)
        let id = Self.nextNumbered("BUG", in: folder)
        // Attachments next to the report, referenced from it.
        var assets: [String] = []
        for url in attachments {
            let target = folder.appendingPathComponent("assets/\(id)-\(url.lastPathComponent)")
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: url, to: target)) != nil { assets.append("assets/\(target.lastPathComponent)") }
        }
        var attachmentText = ""
        for url in attachments { attachmentText += "\n--- \(url.lastPathComponent) ---\n" + (await Self.readableText(of: url)).prefix(20_000) }
        let prompt = """
        ## Bug description from the user

        \(dump.prefix(30_000))
        \(attachmentText.isEmpty ? "" : "\n## Attachments\n\(attachmentText)")
        \(assets.isEmpty ? "" : "\nAttached files (look at images): " + assets.map { "docs/bugs/" + $0 }.joined(separator: ", "))

        Task: write a precise bug report. Search the project's code and documentation (read-only) for where \
        this behaviour most likely comes from and name the files with the reason. Give a short title, a summary, \
        steps to reproduce, expected and actual behaviour, severity (critical = data loss / security / outage; \
        high = main flow broken; medium; low), environment details if known, likely causes, and what information \
        is still missing to reproduce it.
        """
        let schema: [String: Any] = ["type": "object",
            "properties": ["title": ["type": "string"], "summary": ["type": "string"],
                           "steps": ["type": "array", "items": ["type": "string"]],
                           "expected": ["type": "string"], "actual": ["type": "string"],
                           "severity": ["type": "string", "enum": ["critical", "high", "medium", "low"]],
                           "environment": ["type": "string"],
                           "suspected": ["type": "array", "items": ["type": "object",
                               "properties": ["path": ["type": "string"], "reason": ["type": "string"]], "required": ["path", "reason"]]],
                           "causes": ["type": "array", "items": ["type": "string"]],
                           "missing": ["type": "array", "items": ["type": "string"]]],
            "required": ["title", "summary", "steps", "expected", "actual", "severity", "environment", "suspected", "causes", "missing"]]
        guard let object = await structured("intake:bug", prompt: prompt, schema: schema) else { return nil }
        let title = object["title"] as? String ?? "Bug"
        let suspected = (object["suspected"] as? [[String: Any]] ?? []).map { "- `\($0["path"] as? String ?? "")` — \($0["reason"] as? String ?? "")" }
        func list(_ key: String, numbered: Bool = false) -> String {
            (object[key] as? [String] ?? []).enumerated().map { numbered ? "\($0.offset + 1). \($0.element)" : "- \($0.element)" }.joined(separator: "\n")
        }
        var report = """
        ## Summary

        \(object["summary"] as? String ?? "")

        ## Steps to reproduce

        \(list("steps", numbered: true))

        ## Expected

        \(object["expected"] as? String ?? "")

        ## Actual

        \(object["actual"] as? String ?? "")

        ## Environment

        \((object["environment"] as? String ?? "").isEmpty ? "Unknown" : object["environment"] as? String ?? "")

        ## Suspected code

        \(suspected.isEmpty ? "Not located." : suspected.joined(separator: "\n"))

        ## Likely causes

        \(list("causes"))
        """
        let missing = list("missing")
        if !missing.isEmpty { report += "\n\n## Missing information\n\n\(missing)" }
        if !assets.isEmpty { report += "\n\n## Attachments\n\n" + assets.map { "![\($0)](\($0))" }.joined(separator: "\n") }
        report += "\n\n## Original description\n\n\(dump)"
        // The report is written first; GitHub comes after, so a failed write leaves no orphan issue.
        let fileName = "\(id)-\(featureSlug(title).prefix(50)).md"
        let file = folder.appendingPathComponent(fileName)
        var front = FrontMatter()
        front.set("type", "bug")
        front.set("id", id)
        front.set("title", title)
        front.set("status", "open")
        front.set("severity", object["severity"] as? String ?? "medium")
        front.set("issue", linkedIssue.map { "#\($0)" })
        front.set("reporter", store.defaultOwner)
        front.set("created", FeatureStore.today)
        front.set("provenance", linkedIssue.map { "Analyzed from GitHub issue #\($0)" } ?? "Created from the bug intake")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try front.join(body: "# \(title)\n\n" + report).write(to: file, atomically: true, encoding: .utf8)
        } catch {
            self.error = "Could not write the bug report: \(error.localizedDescription)"
            return nil
        }
        var issueRef = linkedIssue.map { "#\($0)" }
        if let client = gitHubClient() {
            let issueBody = report.replacingOccurrences(of: "](assets/", with: "](docs/bugs/assets/")
                + "\n\n_Report: `docs/bugs/\(fileName)`_"
            if let linkedIssue {
                if commentOnIssue {
                    do { try await client.commentIssue(linkedIssue, body: "### Analysis\n\n" + issueBody) }
                    catch { self.error = "The report is written, but commenting on #\(linkedIssue) failed: \(error.localizedDescription)" }
                }
            } else if let url = await Self.createIssue(client, title: title, body: issueBody, label: "bug"),
                      let number = url.split(separator: "/").last {
                issueRef = "#\(number)"
                front.set("issue", "#\(number)")
                try? front.join(body: "# \(title)\n\n" + report).write(to: file, atomically: true, encoding: .utf8)
            }
        }
        return IntakeOutcome(file: file, feature: nil, issue: issueRef)
    }

    /// Next "BUG-003" in a folder of such files.
    static func nextNumbered(_ prefix: String, in folder: URL) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let numbers = names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix + "-") else { return nil }
            return Int(name.dropFirst(prefix.count + 1).prefix { $0.isNumber })
        }
        return String(format: "%@-%03d", prefix, (numbers.max() ?? 0) + 1)
    }
}
