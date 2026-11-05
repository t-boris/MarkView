import Foundation

/// The agent tools that change or explain the status of a feature or a bug (issue-lifecycle-management, REQ-001, REQ-003).
/// They wait for delivery evidence (git and GitHub are read off the main thread), so they are async and are routed here by the
/// control server instead of through the synchronous `ProjectToolRunner.run`. An agent is the `ai` actor: `by_user` never
/// grants an override of the lifecycle rules, and an AI cannot force a status (DEC-011).
@MainActor
enum LifecycleToolRunner {
    static func handles(_ tool: String, _ args: [String: Any]) -> Bool {
        switch tool {
        case "markview_set_bug_status", "markview_issue_context", "markview_attach_issue": return true
        case "markview_set_status": return ((args["id"] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        default: return false
        }
    }

    static func run(_ tool: String, _ args: [String: Any], store: FeatureStore) async -> BrowserAgentTools.Reply {
        guard store.root != nil else { return .error("This window has no project folder open.") }
        // The files may have changed since the app last looked (an agent, git, the user's editor).
        store.reloadSync()
        do {
            switch tool {
            case "markview_set_status": return try await setFeatureStatus(store, args)
            case "markview_set_bug_status": return try await setBugStatus(store, args)
            case "markview_issue_context": return try await context(store, args)
            case "markview_attach_issue": return try attach(store, args)
            default: return .error("Unknown tool \(tool).")
            }
        } catch let invalid as ProjectAgentTools.Invalid {
            return .error(invalid.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - The caller

    /// The agent behind a call: its tool name and session label, when it gave them.
    private static func actor(_ args: [String: Any]) -> LifecycleActor {
        let tool = ((args["tool"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let session = ((args["session"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .ai(tool.isEmpty ? "AI agent" : tool, session: session.isEmpty ? nil : session)
    }

    /// A call from a session is noted, so the context can say whether an attached session was ever seen using the tools.
    private static func note(_ store: FeatureStore, issue: String, _ args: [String: Any]) {
        let session = ((args["session"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { return }
        store.lifecycle.sessions?.noteCall(issue: issue, session: session)
    }

    private static func reply(_ result: ApplyResult, issue: String) -> BrowserAgentTools.Reply {
        switch result {
        case .applied, .unchanged, .duplicate:
            return .init(text: result.explanation)
        case .rejected, .stale, .failed, .unrecorded:
            return .error(result.explanation + " Read markview_issue_context(issue: \"\(issue)\") for what the lifecycle still needs.")
        }
    }

    // MARK: - Status

    private static func setFeatureStatus(_ store: FeatureStore, _ args: [String: Any]) async throws -> BrowserAgentTools.Reply {
        let feature = try ProjectToolRunner.featureNamed(store, args)
        let status = try ProjectAgentTools.text(args, "status", required: true).lowercased()
        let reason = try ProjectAgentTools.text(args, "reason")
        let evidence = try ProjectAgentTools.text(args, "evidence")
        note(store, issue: feature.slug, args)
        let result = await store.lifecycle.request(.feature, feature.slug, to: status, actor: actor(args), reason: reason.isEmpty ? nil : reason,
                                                   acceptance: evidence.isEmpty ? nil : evidence, surface: false)
        return reply(result, issue: feature.slug)
    }

    private static func setBugStatus(_ store: FeatureStore, _ args: [String: Any]) async throws -> BrowserAgentTools.Reply {
        let id = try ProjectAgentTools.text(args, "id", required: true).uppercased()
        guard let bug = store.bugs.first(where: { $0.key.uppercased() == id }) else {
            throw ProjectAgentTools.Invalid(message: "No bug report \(id).")
        }
        let original = try ProjectAgentTools.text(args, "duplicate_of").uppercased()
        if !original.isEmpty {
            guard original != id else { throw ProjectAgentTools.Invalid(message: "A bug cannot be a duplicate of itself.") }
            guard store.bugs.contains(where: { $0.key.uppercased() == original }) else {
                throw ProjectAgentTools.Invalid(message: "No bug report \(original) to name as the original.")
            }
        }
        let status = original.isEmpty ? try ProjectAgentTools.choice(args, "status", in: FeatureVocabulary.bugStatuses, default: "") : "closed"
        guard !status.isEmpty else { throw ProjectAgentTools.Invalid(message: "`status` is required: \(FeatureVocabulary.bugStatuses.joined(separator: ", ")).") }
        let reason = try ProjectAgentTools.text(args, "reason")
        let evidence = try ProjectAgentTools.text(args, "evidence")
        var cancellation: CancellationEvidence?
        if !original.isEmpty {
            cancellation = .duplicate(of: original)
        } else if status == "closed", !evidence.isEmpty, ["open", "fixing"].contains(LifecycleVocabulary.normalize(bug.status)) {
            cancellation = .invalid(evidence)
        }
        note(store, issue: bug.key, args)
        let result = await store.lifecycle.request(.bug, bug.key, to: status, actor: actor(args), reason: reason.isEmpty ? nil : reason,
                                                   acceptance: evidence.isEmpty ? nil : evidence, cancellation: cancellation, surface: false)
        if result.isApplied, !original.isEmpty {
            store.updateBug(bug.url) { front, _ in front.set("duplicate_of", original) }
        }
        return reply(result, issue: bug.key)
    }

    // MARK: - Context and sessions

    /// Feature slug or bug key → what it is; nil when the project has neither.
    private static func resolve(_ store: FeatureStore, _ name: String) -> (kind: IssueKind, issue: String)? {
        if ProjectAgentTools.isPlainName(name), store.feature(name) != nil { return (.feature, name) }
        if let bug = store.bugs.first(where: { $0.key.uppercased() == name.uppercased() }) { return (.bug, bug.key) }
        return nil
    }

    private static func context(_ store: FeatureStore, _ args: [String: Any]) async throws -> BrowserAgentTools.Reply {
        let name = try ProjectAgentTools.text(args, "issue")
        if name.isEmpty {
            return .init(text: ProjectToolRunner.clip(store.lifecycle.listText()))
        }
        guard let target = resolve(store, name) else {
            throw ProjectAgentTools.Invalid(message: "No feature or bug \"\(name)\" in this project.")
        }
        note(store, issue: target.issue, args)
        guard let text = await store.lifecycle.contextText(target.kind, target.issue, actor: .ai) else {
            return .error("The lifecycle of \(target.issue) could not be read.")
        }
        return .init(text: ProjectToolRunner.clip(text))
    }

    private static func attach(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let name = try ProjectAgentTools.text(args, "issue", required: true)
        guard let target = resolve(store, name) else {
            throw ProjectAgentTools.Invalid(message: "No feature or bug \"\(name)\" in this project.")
        }
        guard let sessions = store.lifecycle.sessions else { return .error("This window has no project folder open.") }
        var session = try ProjectAgentTools.text(args, "session")
        let generated = session.isEmpty
        if generated { session = "agent-" + UUID().uuidString.prefix(8).lowercased() }
        let tool = try ProjectAgentTools.text(args, "tool")
        do {
            _ = try sessions.attach(issue: target.issue, kind: target.kind, session: session, tool: tool, via: .attached)
        } catch {
            return .error("The session could not be attached: \(error.localizedDescription)")
        }
        sessions.noteCall(issue: target.issue, session: session)
        let status = store.lifecycle.storedStatus(target.kind, target.issue) ?? "unknown"
        let start = target.kind == .feature ? "markview_set_status(feature, \"implementing\")" : "markview_set_bug_status(id, \"fixing\")"
        return .init(text: "Attached session \(session) to \(target.issue) (status \(status))."
            + (generated ? " Pass session: \"\(session)\" in later calls so MarkView can see this session working on it." : "")
            + " This is the start evidence: work begins with \(start). Completion is recorded from merge, checks and release evidence; "
            + "markview_issue_context shows what is still missing.")
    }
}
