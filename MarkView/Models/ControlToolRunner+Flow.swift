import Foundation

/// The flow tools of `ControlToolRunner`: take a feature through New Feature → Explore → Review → Plan → Implementation
/// by calling what the Feature panel calls. The AI steps take from seconds to minutes, so a step runs as a `Job` that
/// outlives the request which started it; the request waits for it for `wait_s` and the next call (or
/// `markview_flow_status`) picks the result up.
///
/// What is the person's to decide (an answer, leaving Explore, approving requirements, filing issues, handing work to an
/// agent) needs `by_user: true` — the agent says it asked. `delegate` is the app's own "let the AI decide": the
/// decisions it makes stay proposed until the person accepts them in MarkView.
@MainActor
extension ControlToolRunner {
    /// One AI step started from here.
    final class Job {
        let key: String
        let started = Date()
        var finished: Date?
        /// What it came to, in a sentence; set when it finishes.
        var note = ""
        /// The feature the step made or worked on, when it says so.
        var slug: String?
        var task: Task<Void, Never>?
        init(key: String) { self.key = key }
    }

    /// Per window: the jobs by the assistant's key ("explore:<slug>"), and what the last ones came to.
    private static var jobs: [UUID: [String: Job]] = [:]
    private static var outcomes: [UUID: [String]] = [:]

    // MARK: - Jobs

    /// Start `work` under `key` unless that step is already running. It returns once the assistant shows the step as
    /// running, or it ended.
    private static func start(_ target: Target, key: String, _ work: @escaping @MainActor (Job) async -> String) async throws -> Job {
        let assistant = target.workspace.features.assistant
        if assistant.isRunning(key) || jobs[target.id]?[key]?.finished == nil && jobs[target.id]?[key] != nil {
            throw Invalid(message: "\(key) is already running. markview_flow_status { wait_s: 60 } waits for it.")
        }
        let job = Job(key: key)
        jobs[target.id, default: [:]][key] = job
        let id = target.id
        job.task = Task { @MainActor in
            let before = assistant.error
            var note = await work(job)
            if assistant.actions[key]?.phase == .failed || (assistant.error != nil && assistant.error != before) {
                note = "\(key) failed: \(assistant.error ?? assistant.actions[key]?.stage ?? "see MarkView")."
            }
            job.note = note
            job.finished = Date()
            outcomes[id, default: []].append(note)
            if outcomes[id, default: []].count > 6 { outcomes[id]?.removeFirst() }
        }
        _ = await waitUntil(3) { assistant.isRunning(key) || job.finished != nil }
        return job
    }

    /// Wait for `job` for `seconds`, then say how it stands.
    private static func settle(_ target: Target, _ job: Job, seconds: Int, slug: String?) async -> Reply {
        let finished = await waitUntil(Double(seconds)) { job.finished != nil }
        var out: String
        if finished {
            out = job.note
        } else {
            let assistant = target.workspace.features.assistant
            let stage = assistant.actions[job.key]?.stage ?? "working"
            out = "\(job.key) is still running (\(stage), \(Int(Date().timeIntervalSince(job.started))) s). "
                + "markview_flow_status { wait_s: 60 } waits for it; the result is in MarkView meanwhile."
        }
        return .init(text: out + (slug.map { "\n\n" + describe(target, $0) } ?? ""))
    }

    /// The keys of the AI steps running for `slug` (or all in the window).
    private static func runningKeys(_ assistant: FeatureAssistant, slug: String?) -> [String] {
        assistant.running.union(assistant.preparing).filter { key in
            guard let slug else { return true }
            return key.hasSuffix(":" + slug)
        }.sorted()
    }

    // MARK: - Choosing a feature

    private static func featureLine(_ feature: Feature) -> String {
        "\(feature.slug) — \(feature.title) (\(feature.status))"
    }

    static func feature(_ args: [String: Any], in target: Target) throws -> Feature {
        let store = target.workspace.features
        guard store.root != nil else { throw Invalid(message: "Window \(target.shortID) has no project open.") }
        let query = try ProjectAgentTools.text(args, "feature").lowercased()
        let all = store.features
        if query.isEmpty {
            if let slug = store.activeSlug, let feature = store.feature(slug) { return feature }
            if all.count == 1 { return all[0] }
            throw Invalid(message: "Name the feature (`feature`: its slug or a part of its title)." + (all.isEmpty ? " There is none yet: markview_flow_new." : "\n" + all.map(featureLine).joined(separator: "\n")))
        }
        let groups = [all.filter { $0.slug.lowercased() == query },
                      all.filter { $0.slug.lowercased().hasPrefix(query) },
                      all.filter { $0.slug.lowercased().contains(query) || $0.title.lowercased().contains(query) }]
        for group in groups where !group.isEmpty {
            if group.count == 1 { return group[0] }
            throw Invalid(message: "“\(query)” matches several features:\n" + group.map(featureLine).joined(separator: "\n"))
        }
        throw Invalid(message: "No feature matches “\(query)”." + (all.isEmpty ? "" : "\n" + all.map(featureLine).joined(separator: "\n")))
    }

    private static func requirePerson(_ args: [String: Any], _ what: String, answer: Bool = false) throws {
        guard args["by_user"] as? Bool == true else {
            throw Invalid(message: "\(what) is the person's decision. Ask them, then call again with by_user: true."
                          + (answer ? " (`delegate` lets the AI decide instead, kept as a proposed decision.)" : ""))
        }
    }

    // MARK: - What a feature looks like

    private static func openFindings(_ feature: Feature) -> [FeatureObject] {
        feature.list(.finding).filter { !$0.isClosed }
    }

    private static func snapshot(_ target: Target, _ feature: Feature) -> ControlAgentTools.FlowSnapshot {
        let assistant = target.workspace.features.assistant
        let requirements = feature.activeRequirements
        let issues = feature.planIssues
        return .init(slug: feature.slug, status: feature.status,
                     running: runningKeys(assistant, slug: feature.slug),
                     openQuestions: feature.openQuestions.count, understood: feature.discoveryDone, pastExplore: feature.isPastExplore,
                     requirements: requirements.count, draftRequirements: requirements.filter { $0.status == "draft" }.count,
                     openFindings: openFindings(feature).count, planIssues: issues.count,
                     issuesFiled: issues.filter { $0.github != nil }.count, gitHubReady: assistant.gitHubClient() != nil)
    }

    private static func questionLines(_ question: FeatureObject) -> String {
        var out = "\(question.id)" + (question.isBlocking ? " [blocking]" : "") + " — \(question.title)\n"
        let text = question.section("Question")
        if !text.isEmpty, text != question.title { out += "    \(text.prefix(400).replacingOccurrences(of: "\n", with: " "))\n" }
        for option in question.front["options"]?.list ?? [] {
            out += "    \(option["label"]?.string ?? "?"). \(option["text"]?.string ?? "")\n"
        }
        let recommended = question.front.string("recommended")
        if !recommended.isEmpty { out += "    recommended: \(recommended)\n" }
        return out
    }

    /// The feature as the agent needs to see it: where it stands, what is open, what to do next.
    static func describe(_ target: Target, _ slug: String) -> String {
        guard let feature = target.workspace.features.feature(slug) else { return "Feature \(slug) is gone." }
        let snap = snapshot(target, feature)
        var out = "\(feature.slug) — \(feature.title)\nStatus: \(feature.status) · readiness \(feature.readiness)% · requirements \(snap.requirements) (\(snap.draftRequirements) draft)"
            + " · findings open \(snap.openFindings) · plan \(snap.planIssues) issue(s), \(snap.issuesFiled) filed\n"
        if !snap.running.isEmpty {
            let assistant = target.workspace.features.assistant
            out += "Running: " + snap.running.map { key in
                assistant.actions[key].map { "\(key) (\($0.stage), \(Int(Date().timeIntervalSince($0.started))) s)" } ?? key
            }.joined(separator: ", ") + "\n"
        }
        let open = feature.openQuestions
        if !open.isEmpty { out += "\nOpen questions:\n" + open.map(questionLines).joined() }
        let findings = openFindings(feature)
        if !findings.isEmpty {
            out += "\nOpen findings:\n" + findings.prefix(8).map { "  \($0.id) [\($0.front.string("severity"))] \($0.title)" }.joined(separator: "\n") + "\n"
            if findings.count > 8 { out += "  …and \(findings.count - 8) more\n" }
        }
        return out + "\nNext: " + ControlAgentTools.advice(snap)
    }

    // MARK: - Tools

    static func flowStatus(_ target: Target, _ args: [String: Any]) async throws -> Reply {
        let workspace = target.workspace
        let store = workspace.features
        guard store.root != nil else { throw Invalid(message: "Window \(target.shortID) has no project open. markview_open_project first.") }
        let slug = try ProjectAgentTools.text(args, "feature").isEmpty ? nil : feature(args, in: target).slug
        let waitSeconds = ControlAgentTools.seconds(args["wait_s"], default: 0)
        if waitSeconds > 0 {
            _ = await waitUntil(Double(waitSeconds)) { runningKeys(store.assistant, slug: slug).isEmpty }
        }
        var out = ""
        let notes = outcomes[target.id] ?? []
        if !notes.isEmpty { out += "Recent results:\n" + notes.map { "  \($0)" }.joined(separator: "\n") + "\n\n" }
        if let slug {
            return .init(text: out + describe(target, slug))
        }
        let features = store.features
        out += "Window \(target.shortID) — \(workspace.projectFolder?.path ?? "")\nFeatures: \(features.count), bugs: \(store.bugs.count)\n"
        for feature in features { out += "  \(featureLine(feature)) · readiness \(feature.readiness)%\n" }
        let running = runningSteps(store.assistant)
        if !running.isEmpty { out += "Running: " + running.joined(separator: ", ") + "\n" }
        return .init(text: out + (features.isEmpty ? "\nNext: markview_flow_new { idea } starts a feature." : "\nNext: markview_flow_status { feature } for one of them, or markview_flow_new."))
    }

    static func flowNew(_ target: Target, _ args: [String: Any]) async throws -> Reply {
        let workspace = target.workspace
        guard workspace.features.root != nil else { throw Invalid(message: "Window \(target.shortID) has no project open. markview_open_project first.") }
        let idea = try ProjectAgentTools.text(args, "idea", required: true)
        let quick = args["quick"] as? Bool == true
        let assistant = workspace.features.assistant
        let kind: IntakeKind = quick ? .quickFeature : .feature
        let job = try await start(target, key: quick ? "intake:quick-feature" : "intake:feature") { job in
            let outcome = quick ? await assistant.newQuickFeature(from: idea, attachments: [])
                                : await assistant.newFeature(from: idea, attachments: [])
            guard let outcome else { return "The assistant did not write the feature: " + (assistant.error ?? "no answer.") }
            workspace.intakeFinished(kind, outcome: outcome)
            job.slug = outcome.feature
            return "Created feature \(outcome.feature ?? "?")."
        }
        let reply = await settle(target, job, seconds: ControlAgentTools.seconds(args["wait_s"]), slug: nil)
        // A finished intake made a feature: show where it stands.
        if job.finished != nil, let slug = job.slug, workspace.features.feature(slug) != nil {
            return .init(text: reply.text + "\n\n" + describe(target, slug))
        }
        return reply
    }

    static func flowAnswer(_ target: Target, _ args: [String: Any]) async throws -> Reply {
        let feature = try feature(args, in: target)
        let slug = feature.slug
        let open = feature.openQuestions
        guard !open.isEmpty else { throw Invalid(message: "\(slug) has no open question.\n\n" + describe(target, slug)) }
        let byUser = args["by_user"] as? Bool == true
        let personal = "Answering with an option, your own words or the recommended answer"
        var given: [String: FeatureAssistant.QuestionAnswer] = [:]
        for item in args["answers"] as? [[String: Any]] ?? [] {
            let id = (item["question"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let question = open.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw Invalid(message: "“\(id)” is not an open question of \(slug). Open: \(open.map(\.id).joined(separator: ", ")).")
            }
            let option = (item["option"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let modes = [!option.isEmpty, !text.isEmpty, item["recommended"] as? Bool == true, item["delegate"] as? Bool == true].filter { $0 }.count
            guard modes == 1 else { throw Invalid(message: "\(question.id): give exactly one of option, text, recommended, delegate.") }
            if item["delegate"] as? Bool == true {
                given[question.id] = .init(id: question.id, answer: FeatureAssistant.recommendedAnswer(question), delegated: true)
                continue
            }
            if !byUser { try requirePerson(args, personal, answer: true) }
            if !option.isEmpty {
                let options = question.front["options"]?.list ?? []
                guard let match = options.first(where: { ($0["label"]?.string ?? "").caseInsensitiveCompare(option) == .orderedSame }) else {
                    throw Invalid(message: "\(question.id) has no option “\(option)”. Options: \(options.compactMap { $0["label"]?.string }.joined(separator: ", ")).")
                }
                given[question.id] = .init(id: question.id, answer: "\(match["label"]?.string ?? option). \(match["text"]?.string ?? "")")
            } else if !text.isEmpty {
                given[question.id] = .init(id: question.id, answer: text)
            } else {
                let recommended = FeatureAssistant.recommendedAnswer(question)
                guard !recommended.isEmpty else { throw Invalid(message: "\(question.id) has no recommended answer; answer it or delegate it.") }
                given[question.id] = .init(id: question.id, answer: recommended)
            }
        }
        if let all = args["all"] as? String, !all.isEmpty {
            guard ["recommended", "delegate"].contains(all) else { throw Invalid(message: "`all` must be recommended or delegate.") }
            for question in open where given[question.id] == nil {
                let recommended = FeatureAssistant.recommendedAnswer(question)
                if all == "delegate" {
                    given[question.id] = .init(id: question.id, answer: recommended, delegated: true)
                } else {
                    try requirePerson(args, personal, answer: true)
                    guard !recommended.isEmpty else { throw Invalid(message: "\(question.id) has no recommended answer; answer it or use all: delegate.") }
                    given[question.id] = .init(id: question.id, answer: recommended)
                }
            }
        }
        guard !given.isEmpty else { throw Invalid(message: "Give `answers` or `all`.\n\n" + describe(target, slug)) }
        let answers = open.compactMap { given[$0.id] }
        let assistant = target.workspace.features.assistant
        let next = args["next"] as? Bool ?? true
        let job = try await start(target, key: "answer:" + slug) { _ in
            await assistant.answerBatch(slug, answers: answers, next: next)
            return "Recorded \(answers.count) answer(s) for \(slug)" + (answers.contains { $0.delegated } ? " (delegated ones are proposed decisions)." : ".")
        }
        return await settle(target, job, seconds: ControlAgentTools.seconds(args["wait_s"]), slug: slug)
    }

    static func flowRun(_ target: Target, _ args: [String: Any]) async throws -> Reply {
        let name = try ProjectAgentTools.text(args, "step", required: true)
        guard let step = ControlAgentTools.FlowStep(rawValue: name) else {
            throw Invalid(message: "`step` must be one of: \(ControlAgentTools.FlowStep.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let feature = try feature(args, in: target)
        let slug = feature.slug
        let store = target.workspace.features
        let assistant = store.assistant
        let wait = ControlAgentTools.seconds(args["wait_s"])
        if step.needsPerson { try requirePerson(args, "“\(step.rawValue)”") }

        func job(_ key: String, _ work: @escaping @MainActor (Job) async -> String) async throws -> Reply {
            let started = try await start(target, key: key, work)
            return await settle(target, started, seconds: wait, slug: slug)
        }
        switch step {
        case .explore:
            guard !feature.isPastExplore else { throw Invalid(message: "\(slug) is past Explore (\(feature.status)).") }
            return try await job("explore:" + slug) { _ in
                await assistant.exploreNext(slug) ? "Asked the next round of questions." : "Nothing was asked: a question is still open, or discovery is done."
            }
        case .decideRest:
            guard !feature.isPastExplore else { throw Invalid(message: "\(slug) is past Explore (\(feature.status)).") }
            return try await job("decide:" + slug) { _ in
                await assistant.decideRest(slug)
                return "The AI made the remaining decisions (proposed) and ended discovery."
            }
        case .finishExplore:
            guard feature.discoveryDone else {
                throw Invalid(message: "Discovery is not done: \(feature.openQuestions.count) question(s) are open. Answer them (markview_flow_answer) or step decide_rest.")
            }
            store.finishExplore(slug)
            return .init(text: "Left Explore: the requirements are approved and \(slug) is in review.\n\n" + describe(target, slug))
        case .review:
            // Reviewing after discovery approves the draft requirements: that is leaving Explore.
            if feature.discoveryDone, !feature.isPastExplore { try requirePerson(args, "Reviewing now (it approves the requirements and leaves Explore)") }
            return try await job("review:" + slug) { _ in
                await assistant.review(slug)
                return "Reviewed \(slug)."
            }
        case .resolve:
            guard !openFindings(feature).isEmpty else { throw Invalid(message: "\(slug) has no open finding.") }
            return try await job("decideall:" + slug) { _ in
                await assistant.decideAllFindings(slug)
                return "The AI resolved the open findings of \(slug) (proposed decisions)."
            }
        case .ready:
            guard feature.isPastExplore, feature.openQuestions.isEmpty, openFindings(feature).isEmpty, !feature.activeRequirements.isEmpty else {
                throw Invalid(message: "\(slug) is not ready: it needs Explore finished, no open question or finding, and requirements.\n\n" + describe(target, slug))
            }
            store.updateFeature(slug) { front, _ in front.set("status", "ready") }
            return .init(text: "\(slug) is marked ready.\n\n" + describe(target, slug))
        case .plan:
            guard feature.isPastExplore else { throw Invalid(message: "Finish Explore first (\(feature.status)).") }
            let filed = feature.planIssues.filter { $0.github != nil }.count
            if filed > 0 { throw Invalid(message: "\(slug) has \(filed) issue(s) filed on GitHub; planning again would drop their numbers and file duplicates. Change the plan in MarkView.") }
            if !feature.planIssues.isEmpty, args["replan"] as? Bool != true {
                throw Invalid(message: "\(slug) already has a plan of \(feature.planIssues.count) issue(s). Pass replan: true to plan again.")
            }
            return try await job("decompose:" + slug) { _ in
                await assistant.decompose(slug)
                return "Planned \(slug): \(store.feature(slug)?.planIssues.count ?? 0) issue(s)."
            }
        case .issues:
            let issues = feature.planIssues
            guard !issues.isEmpty else { throw Invalid(message: "\(slug) has no plan: step plan first.") }
            guard assistant.gitHubClient() != nil else {
                throw Invalid(message: "GitHub is not on for this project (Settings → GitHub, a folder with a GitHub remote).")
            }
            let covered = Set(issues.flatMap(\.requirements))
            let missing = feature.activeRequirements.filter { $0.status == "approved" && !covered.contains($0.id) }.map(\.id)
            guard missing.isEmpty else { throw Invalid(message: "The plan covers no issue for \(missing.joined(separator: ", ")): plan again (replan: true) or add them in MarkView.") }
            return try await job("issues:" + slug) { _ in
                await assistant.createIssues(slug)
                return "Filed the issues of \(slug) on GitHub: \(store.feature(slug)?.planIssues.filter { $0.github != nil }.count ?? 0) of \(issues.count)."
            }
        }
    }

    // MARK: - Handing work to an agent

    /// The terminal that gets the work: the one named (idle), else a new one with `tool`.
    private static func workTerminal(_ target: Target, _ args: [String: Any], caller: Caller) async throws -> TerminalSession {
        if !(try ProjectAgentTools.text(args, "terminal")).isEmpty {
            let session = try terminal(target, args, caller: caller, forInput: true)
            if session.exitCode != nil { throw Invalid(message: "The agent in “\(session.title)” has exited.") }
            if isWorking(session, in: target.workspace) {
                throw Invalid(message: "“\(session.title)” is working (\(state(of: session, in: target.workspace))). Name another terminal, or leave `terminal` out for a new one.")
            }
            return session
        }
        return try await startTerminal(target, tool: chosenTool(args, in: target.workspace), resume: false)
    }

    static func flowImplement(_ target: Target, _ args: [String: Any], caller: Caller) async throws -> Reply {
        try requirePerson(args, "Starting an implementation")
        let feature = try feature(args, in: target)
        guard feature.isPastExplore else {
            throw Invalid(message: "\(feature.slug) is still in Explore (\(feature.status)). Finish discovery and review it first.\n\n" + describe(target, feature.slug))
        }
        let workspace = target.workspace
        let session = try await workTerminal(target, args, caller: caller)
        let done = DefinitionOfDone.load(root: workspace.projectFolder)
        workspace.startImplementation(feature.folder, done: done, in: session)
        lastSent[session.id] = Date()
        let id = ControlAgentTools.shortID(session.id.uuidString)
        return .init(text: "Gave \(feature.slug) to \(session.profile.title) in terminal \(id) as a goal with the project's definition of done; it is pasted once the agent is ready.\n"
                     + "Follow it: markview_agent_wait { terminal: \"\(id)\" } and markview_agent_read. A first run may ask to trust the folder (markview_agent_key enter). "
                     + "MarkView records implemented and verified from git and GitHub.")
    }

    static func flowFixBug(_ target: Target, _ args: [String: Any], caller: Caller) async throws -> Reply {
        try requirePerson(args, "Fixing a bug with an agent")
        let key = try ProjectAgentTools.text(args, "bug", required: true)
        let store = target.workspace.features
        guard let bug = store.bugs.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else {
            throw Invalid(message: "No bug report “\(key)”." + (store.bugs.isEmpty ? "" : " Bugs: \(store.bugs.prefix(20).map(\.key).joined(separator: ", "))."))
        }
        let session = try await workTerminal(target, args, caller: caller)
        target.workspace.fixBugWithAI(bug.url, in: session)
        lastSent[session.id] = Date()
        let id = ControlAgentTools.shortID(session.id.uuidString)
        return .init(text: "Gave \(bug.key) (\(bug.title)) to \(session.profile.title) in terminal \(id); the report is marked fixing. Follow it with markview_agent_wait { terminal: \"\(id)\" }.")
    }

    static func flowStop(_ target: Target, _ args: [String: Any]) throws -> Reply {
        let assistant = target.workspace.features.assistant
        let slug = try ProjectAgentTools.text(args, "feature").isEmpty ? nil : feature(args, in: target).slug
        let keys = runningKeys(assistant, slug: slug)
        guard !keys.isEmpty else { return .init(text: "Nothing is running" + (slug.map { " for \($0)" } ?? "") + ".") }
        for key in keys { assistant.stopAction(key) }
        return .init(text: "Asked to stop: \(keys.joined(separator: ", ")).")
    }
}
