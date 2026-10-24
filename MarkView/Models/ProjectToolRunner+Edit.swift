import Foundation

/// The tools of the project server that correct what exists: they go through the same `FeatureStore` writes as
/// the app's own editing, so ids, links and front matter stay valid. Settling something (approving, accepting,
/// answering) needs the person's word, passed as `by_user`.
extension ProjectToolRunner {
    private typealias Invalid = ProjectAgentTools.Invalid

    /// Runs a store write and reports the store's own error when it did not go through.
    private static func written(_ store: FeatureStore, _ work: () -> Void) throws {
        store.lastError = nil
        work()
        if let error = store.lastError { throw Invalid(message: error) }
    }

    private static func requirePerson(_ args: [String: Any], _ what: String) throws {
        guard args["by_user"] as? Bool == true else {
            throw Invalid(message: "\(what) records the person's own words. Ask them, and call again with by_user: true only when they said it in the conversation.")
        }
    }

    /// A map argument whose values are text.
    private static func texts(_ args: [String: Any], _ key: String) throws -> [String: String] {
        guard let raw = args[key] else { return [:] }
        guard let map = raw as? [String: Any] else { throw Invalid(message: "`\(key)` must be an object.") }
        var out: [String: String] = [:]
        for (name, value) in map {
            guard let text = value as? String else { throw Invalid(message: "`\(key).\(name)` must be text.") }
            out[name] = text
        }
        return out
    }

    static func updateFeature(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let feature = try featureNamed(store, args)
        let title = try ProjectAgentTools.text(args, "title"), idea = try ProjectAgentTools.text(args, "idea")
        guard title.count <= 200 else { throw Invalid(message: "`title` is too long (200 characters at most).") }
        var states: [String: String] = [:]
        for (dimension, value) in args["understanding"] as? [String: Any] ?? [:] {
            guard FeatureVocabulary.understanding.contains(dimension), let state = (value as? String)?.lowercased(),
                  FeatureVocabulary.understandingStates.contains(state) else {
                throw Invalid(message: "`understanding`: dimension (\(FeatureVocabulary.understanding.joined(separator: ", "))) → \(FeatureVocabulary.understandingStates.joined(separator: ", ")).")
            }
            states[dimension] = state
        }
        guard !title.isEmpty || !idea.isEmpty || !states.isEmpty else { throw Invalid(message: "Nothing to change: give `title`, `idea` or `understanding`.") }
        try written(store) {
            if !title.isEmpty || !idea.isEmpty {
                store.updateFeature(feature.slug) { front, body in
                    if !title.isEmpty {
                        front.set("title", title)
                        var lines = body.components(separatedBy: "\n")
                        if let heading = lines.firstIndex(where: { $0.hasPrefix("# ") }) { lines[heading] = "# " + title; body = lines.joined(separator: "\n") }
                    }
                    if !idea.isEmpty { body = FeatureObject.replacingSection("Idea", in: body, with: idea) }
                    front.set("updated", FeatureStore.today)
                }
            }
            if !states.isEmpty { store.setUnderstanding(feature.slug, states) }
        }
        return .init(text: "Updated \(feature.slug).")
    }

    static func updateObject(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let feature = try featureNamed(store, args)
        let id = try ProjectAgentTools.text(args, "id", required: true)
        guard let object = feature.object(id), [.requirement, .decision, .question, .finding].contains(object.kind) else {
            throw Invalid(message: "\(feature.slug) has no requirement, decision, question or finding \(id).")
        }
        let title = try ProjectAgentTools.text(args, "title")
        let sections = try texts(args, "sections")
        var links: [String: [String]] = [:]
        for (key, value) in args["links"] as? [String: Any] ?? [:] {
            guard ProjectAgentTools.linkKeys.contains(key) else { throw Invalid(message: "Unknown link `\(key)`. Links: \(ProjectAgentTools.linkKeys.joined(separator: ", ")).") }
            guard let ids = value as? [String] else { throw Invalid(message: "`links.\(key)` must be a list of ids.") }
            for target in ids where feature.object(target) == nil { throw Invalid(message: "`links.\(key)`: \(feature.slug) has no \(target).") }
            links[key] = ids
        }
        let type = try ProjectAgentTools.text(args, "req_type").lowercased()
        let severity = try ProjectAgentTools.text(args, "severity").lowercased()
        let dismissed = try ProjectAgentTools.text(args, "dismissed_reason")
        if !type.isEmpty { guard object.kind == .requirement, FeatureVocabulary.requirementTypes.contains(type) else { throw Invalid(message: "`req_type` is for a requirement: \(FeatureVocabulary.requirementTypes.joined(separator: ", ")).") } }
        if !severity.isEmpty || !dismissed.isEmpty {
            guard object.kind == .finding, severity.isEmpty || FeatureVocabulary.severities.contains(severity) else { throw Invalid(message: "`severity` and `dismissed_reason` are for a finding; severities: \(FeatureVocabulary.severities.joined(separator: ", ")).") }
        }
        var done: Set<Int>?
        if let given = args["criteria_done"] as? [Any] {
            guard object.kind == .requirement else { throw Invalid(message: "`criteria_done` is for a requirement.") }
            let numbers = given.compactMap { ($0 as? Int) ?? ($0 as? Double).map(Int.init) }
            guard numbers.count == given.count, numbers.allSatisfy({ (1...max(object.acceptanceCriteria.count, 1)).contains($0) }) else {
                throw Invalid(message: "`criteria_done`: numbers from 1 to \(object.acceptanceCriteria.count).")
            }
            done = Set(numbers)
        }
        guard !title.isEmpty || !sections.isEmpty || !links.isEmpty || !type.isEmpty || !severity.isEmpty || !dismissed.isEmpty || done != nil else {
            throw Invalid(message: "Nothing to change: give `title`, `sections`, `links`, `criteria_done` or a field.")
        }
        try written(store) {
            store.update(id, in: feature.slug) { front, body in
                if !title.isEmpty { front.set("title", title) }
                for (name, text) in sections { body = FeatureObject.replacingSection(name, in: body, with: text) }
                for (key, ids) in links { front.set(key, list: ids) }
                if !type.isEmpty { front.set("req_type", type) }
                if !severity.isEmpty { front.set("severity", severity) }
                if !dismissed.isEmpty { front.set("dismissed_reason", dismissed) }
                if let done {
                    let lines = FeatureObject.acceptanceCriteria(in: body).enumerated().map { "- [\(done.contains($0.offset + 1) ? "x" : " ")] \($0.element.text)" }
                    body = FeatureObject.replacingSection("Acceptance Criteria", in: body, with: lines.joined(separator: "\n"))
                }
            }
        }
        return .init(text: "Updated \(id) of \(feature.slug).")
    }

    static func answerQuestion(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let feature = try featureNamed(store, args)
        let id = try ProjectAgentTools.text(args, "id", required: true)
        let answer = try ProjectAgentTools.text(args, "answer", required: true)
        guard let question = feature.object(id), question.kind == .question else { throw Invalid(message: "\(feature.slug) has no question \(id).") }
        guard question.status == "open" else { throw Invalid(message: "\(id) is already \(question.status).") }
        try requirePerson(args, "An answer")
        try written(store) {
            store.update(id, in: feature.slug) { front, body in
                front.set("status", "answered")
                front.set("answer", answer)
                front.set("answered_by", "user")
                body += "\n## Answer\n\n\(answer)\n"
            }
            store.appendDiscussion(feature.slug, speaker: "Answer to \(id)", text: "\(question.title)\n\n\(answer)")
        }
        return .init(text: "\(id) is answered. Explore in MarkView turns answers into decisions and requirement changes.")
    }

    static func addSource(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let feature = try featureNamed(store, args)
        let title = try ProjectAgentTools.text(args, "title", required: true)
        let origin = try ProjectAgentTools.text(args, "origin", required: true)
        let content = try ProjectAgentTools.text(args, "content")
        let role = try ProjectAgentTools.choice(args, "role", in: FeatureVocabulary.sourceRoles, default: "")
        var body = "## Origin\n\n\(origin)\n"
        if !content.isEmpty { body += "\n## Content\n\n\(content)\n" }
        guard let source = store.create(.source, in: feature.slug, title: title,
                                        fields: [("origin", .string(origin)), ("file", .string("")), ("role", .string(role)), ("facts", .list([]))],
                                        body: body, provenance: provenance("")) else {
            return .error(store.lastError ?? "The source could not be written.")
        }
        return .init(text: "Added \(source.id) \"\(title)\" to \(feature.slug).")
    }

    static func addDiscussionNote(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let feature = try featureNamed(store, args)
        let text = try ProjectAgentTools.text(args, "text", required: true)
        let speaker = try ProjectAgentTools.text(args, "speaker")
        store.appendDiscussion(feature.slug, speaker: speaker.isEmpty ? "Agent" : speaker, text: text)
        return .init(text: "Added to the discussion of \(feature.slug).")
    }

    private static func bugNamed(_ store: FeatureStore, _ args: [String: Any], key: String = "id") throws -> BugReport {
        let id = try ProjectAgentTools.text(args, key, required: true).uppercased()
        guard let bug = store.bugs.first(where: { $0.key.uppercased() == id }) else { throw Invalid(message: "No bug report \(id).") }
        return bug
    }

    static func updateBug(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let bug = try bugNamed(store, args)
        let title = try ProjectAgentTools.text(args, "title")
        let severity = try ProjectAgentTools.choice(args, "severity", in: ["critical", "high", "medium", "low"], default: "")
        let sections = try texts(args, "sections")
        let feature = args["feature"] as? String
        if let feature, !feature.isEmpty, !ProjectAgentTools.isPlainName(feature) || store.feature(feature) == nil {
            throw Invalid(message: "No feature \"\(feature)\" in this project.")
        }
        let ready = args["ready_to_fix"] as? Bool
        guard !title.isEmpty || !severity.isEmpty || !sections.isEmpty || feature != nil || ready != nil else {
            throw Invalid(message: "Nothing to change: give `title`, `severity`, `feature`, `ready_to_fix` or `sections`.")
        }
        guard store.updateBug(bug.url, { front, body in
            if !title.isEmpty {
                front.set("title", title)
                var lines = body.components(separatedBy: "\n")
                if let heading = lines.firstIndex(where: { $0.hasPrefix("# ") }) { lines[heading] = "# " + title; body = lines.joined(separator: "\n") }
            }
            if !severity.isEmpty { front.set("severity", severity) }
            if let feature { front.set("feature", feature.isEmpty ? nil : feature) }
            if let ready { front.set("ready_to_fix", ready ? "true" : "false") }
            for (name, text) in sections { body = FeatureObject.replacingSection(name, in: body, with: text) }
            front.set("updated", FeatureStore.today)
        }) else { return .error(store.lastError ?? "The bug report could not be updated.") }
        return .init(text: "Updated \(bug.key).")
    }

    static func answerBugQuestion(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let bug = try bugNamed(store, args)
        let questionID = try ProjectAgentTools.text(args, "question", required: true)
        guard bug.questions.contains(where: { $0.id == questionID }) else {
            throw Invalid(message: "\(bug.key) has no question \(questionID). Questions: \(bug.questions.map(\.id).joined(separator: ", ")).")
        }
        let skip = args["skip"] as? Bool == true
        let answer = try ProjectAgentTools.text(args, "answer")
        guard skip || !answer.isEmpty else { throw Invalid(message: "Give `answer`, or `skip: true` when the person does not know.") }
        try requirePerson(args, "An answer")
        guard store.updateBug(bug.url, { front, _ in
            var questions = (front["questions"]?.list ?? []).compactMap(BugQuestion.init)
            guard let index = questions.firstIndex(where: { $0.id == questionID }) else { return }
            questions[index].status = skip ? "skipped" : "answered"
            questions[index].answer = skip ? "" : answer
            front["questions"] = .list(questions.map(\.yaml))
            front.set("updated", FeatureStore.today)
        }) else { return .error(store.lastError ?? "The bug report could not be updated.") }
        return .init(text: "\(questionID) of \(bug.key) is \(skip ? "skipped" : "answered").")
    }

    static func linkIssue(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let target = try ProjectAgentTools.text(args, "target", required: true)
        let numbers = (args["issues"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? ($0 as? Double).map(Int.init) }.filter { $0 > 0 }
        guard !numbers.isEmpty else { throw Invalid(message: "`issues` needs at least one issue number.") }
        let remove = args["remove"] as? Bool == true
        func merged(_ front: FrontMatter) -> [String] {
            var current = Set(front.strings("issues").compactMap { Int($0.filter(\.isNumber)) })
            if remove { current.subtract(numbers) } else { current.formUnion(numbers) }
            return current.sorted().map(String.init)
        }
        if target.uppercased().hasPrefix("BUG-") {
            let bug = try bugNamed(store, ["id": target])
            guard store.updateBug(bug.url, { front, _ in front.set("issues", list: merged(front)) }) else {
                return .error(store.lastError ?? "The bug report could not be updated.")
            }
            return .init(text: "\(bug.key) \(remove ? "unlinked from" : "linked to") " + numbers.map { "#\($0)" }.joined(separator: " ") + ".")
        }
        let feature = try featureNamed(store, ["feature": target])
        try written(store) { store.updateFeature(feature.slug) { front, _ in front.set("issues", list: merged(front)) } }
        return .init(text: "\(feature.slug) \(remove ? "unlinked from" : "linked to") " + numbers.map { "#\($0)" }.joined(separator: " ") + ".")
    }

    static func openQuestions(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let slug = try ProjectAgentTools.text(args, "feature")
        let features = slug.isEmpty ? store.features : [try featureNamed(store, args)]
        var lines: [String] = []
        for feature in features {
            for question in feature.list(.question) where question.status == "open" {
                var line = "\(feature.slug) \(question.id)\(question.isBlocking ? " [blocking]" : ""): " + (question.section("Question").isEmpty ? question.title : question.section("Question"))
                let options = (question.front["options"]?.list ?? []).map { "\($0["label"]?.string ?? ""): \($0["text"]?.string ?? "")" }
                if !options.isEmpty { line += "\n    options: " + options.joined(separator: " | ") }
                if !question.front.string("recommended").isEmpty { line += "\n    recommended: \(question.front.string("recommended"))" }
                lines.append(line)
            }
        }
        return .init(text: lines.isEmpty ? "No open questions." : clip(lines.joined(separator: "\n")))
    }

    static func readinessReport(_ feature: Feature) -> String {
        var out = "Readiness \(feature.readiness)%:\n" + feature.readinessConditions.map { "- \($0.name): \($0.done)/\($0.total)\($0.met ? "" : " ✗")" }.joined(separator: "\n")
        let outdated = feature.outdatedRequirements.map(\.id), pending = feature.settlementsToApply.map(\.id)
        if !outdated.isEmpty { out += "\nOutdated requirements: " + outdated.joined(separator: ", ") }
        if !pending.isEmpty { out += "\nSettled but not yet applied to the requirements: " + pending.joined(separator: ", ") }
        if !feature.openDimensions.isEmpty { out += "\nStill unknown: " + feature.openDimensions.joined(separator: ", ") }
        return out
    }
}
