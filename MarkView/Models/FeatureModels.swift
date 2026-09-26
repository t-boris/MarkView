import Foundation

// Feature workspaces: a feature is a folder `docs/features/<slug>/` of Markdown files — an
// overview plus one file per requirement, question, decision, finding, research note and
// source. Front matter holds the structure (ids, statuses, links); the body stays prose.
// Everything the app shows is read back from these files.

/// The kinds of objects a feature holds, each in its own folder with its own id prefix.
enum FeatureObjectKind: String, CaseIterable, Codable, Sendable {
    case requirement, question, decision, finding, research, source

    var prefix: String {
        switch self {
        case .requirement: return "REQ"
        case .question: return "Q"
        case .decision: return "DEC"
        case .finding: return "F"
        case .research: return "R"
        case .source: return "SRC"
        }
    }

    var folder: String {
        switch self {
        case .requirement: return "requirements"
        case .question: return "questions"
        case .decision: return "decisions"
        case .finding: return "findings"
        case .research: return "research"
        case .source: return "references"
        }
    }

    var title: String {
        switch self {
        case .requirement: return "Requirements"
        case .question: return "Questions"
        case .decision: return "Decisions"
        case .finding: return "Findings"
        case .research: return "Research"
        case .source: return "References"
        }
    }

    var icon: String {
        switch self {
        case .requirement: return "checklist"
        case .question: return "questionmark.bubble"
        case .decision: return "signpost.right"
        case .finding: return "exclamationmark.triangle"
        case .research: return "books.vertical"
        case .source: return "paperclip"
        }
    }

    /// Kind of an id like "REQ-014".
    static func of(id: String) -> FeatureObjectKind? {
        let prefix = id.split(separator: "-").first.map(String.init) ?? ""
        return allCases.first { $0.prefix == prefix }
    }
}

/// Statuses and vocabularies (spec §14–§28), stored lower-case in front matter.
enum FeatureVocabulary {
    static let featureStatuses = ["idea", "exploring", "draft", "review", "resolving", "ready",
                                  "implementing", "implemented", "verified", "archived"]
    static let requirementStatuses = ["draft", "review", "approved", "rejected", "superseded"]
    static let requirementTypes = ["functional", "non-functional", "ux", "security", "performance",
                                   "reliability", "privacy", "analytics", "operational", "compliance"]
    static let questionStatuses = ["open", "answered", "deferred"]
    static let questionTypes = ["product", "technical", "architecture", "ux", "security", "business",
                                "research", "clarification"]
    static let decisionStatuses = ["proposed", "accepted", "rejected", "superseded"]
    static let findingStatuses = ["open", "discussing", "resolved", "accepted-risk", "dismissed"]
    static let severities = ["blocker", "high", "medium", "low"]
    static let findingCategories = ["completeness", "ambiguity", "contradiction", "edge-case", "architecture",
                                    "security", "ux", "operations", "open-question", "related-docs",
                                    "external-research"]
    static let perspectives = ["Product", "UX", "Architecture", "Backend", "Frontend", "Security", "QA",
                               "Reliability", "Operations", "Data", "Privacy", "Business"]
    static let claimKinds = ["project-fact", "external-fact", "ai-inference", "user-decision", "open-assumption"]
    static let sourceRoles = ["ui-reference", "external-research", "previous-implementation", "related-specification",
                              "stakeholder-input", "architecture-reference", "api-documentation", "code",
                              "meeting-notes", "requirements"]
    /// What guided discovery tracks (spec §7).
    static let understanding = ["Problem", "Target Users", "Primary Workflow", "Permissions", "Failure Scenarios",
                                "Data Model", "Notifications", "Security", "Analytics", "Dependencies",
                                "Acceptance Criteria"]
    /// known | partial | unknown | n/a
    static let understandingStates = ["known", "partial", "unknown", "n/a"]

    static func label(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

/// One object file (REQ, Q, DEC, F, R, SRC).
struct FeatureObject: Identifiable, Hashable {
    let kind: FeatureObjectKind
    let id: String
    var url: URL
    var front: FrontMatter
    var body: String

    static func == (a: FeatureObject, b: FeatureObject) -> Bool { a.url == b.url && a.front == b.front && a.body == b.body }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }

    var title: String {
        let t = front.string("title")
        if !t.isEmpty { return t }
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            return trimmed.hasPrefix("#") ? trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) : String(trimmed.prefix(120))
        }
        return id
    }

    var status: String { front.string("status") }

    /// Ids this object links to, with the relation (front matter keys).
    var links: [(relation: String, target: String)] {
        let keys = ["depends_on", "decisions", "sources", "blocking", "resolved_by", "produces", "requirements",
                    "questions", "related", "supersedes", "refs"]
        var out: [(String, String)] = []
        for key in keys { for target in front.strings(key) { out.append((key, target)) } }
        return out
    }

    /// `- [ ]` / `- [x]` lines under "## Acceptance Criteria".
    var acceptanceCriteria: [(text: String, done: Bool)] {
        var inSection = false
        var items: [(String, Bool)] = []
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                inSection = trimmed.lowercased().contains("acceptance criteria")
                continue
            }
            guard inSection, trimmed.hasPrefix("- ") else { continue }
            let rest = trimmed.dropFirst(2)
            if rest.hasPrefix("[x]") || rest.hasPrefix("[X]") { items.append((rest.dropFirst(3).trimmingCharacters(in: .whitespaces), true)) }
            else if rest.hasPrefix("[ ]") { items.append((rest.dropFirst(3).trimmingCharacters(in: .whitespaces), false)) }
            else { items.append((String(rest), false)) }
        }
        return items
    }

    /// A body section's text ("## Decision" → its paragraphs).
    func section(_ name: String) -> String {
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

    /// Is this question blocking something (a requirement, or the feature itself)?
    var isBlocking: Bool {
        kind == .question && (!front.strings("blocking").isEmpty || front.string("priority") == "blocking")
    }

    var isClosed: Bool {
        switch kind {
        case .question: return status == "answered" || status == "deferred"
        case .finding: return ["resolved", "accepted-risk", "dismissed"].contains(status)
        case .decision: return status != "proposed"
        case .requirement: return ["approved", "rejected", "superseded"].contains(status)
        default: return false
        }
    }

    func text() -> String { front.join(body: body) }

    static func load(kind: FeatureObjectKind, url: URL) -> FeatureObject? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (front, body) = FrontMatter.split(text)
        let id = front.string("id").isEmpty ? url.deletingPathExtension().lastPathComponent : front.string("id")
        return FeatureObject(kind: kind, id: id, url: url, front: front, body: body)
    }
}

/// One proposed implementation issue (implementation/plan.md).
struct PlannedIssue: Identifiable, Hashable {
    var id: String            // I-1, I-2…
    var title: String
    var summary: String
    var requirements: [String]
    var decisions: [String]
    /// GitHub issue number once created.
    var github: Int?

    var yaml: YAMLValue {
        var entries: [(key: String, value: YAMLValue)] = [("id", .string(id)), ("title", .string(title)),
                                                          ("summary", .string(summary)),
                                                          ("requirements", .list(requirements.map { .string($0) })),
                                                          ("decisions", .list(decisions.map { .string($0) }))]
        if let github { entries.append(("github", .string(String(github)))) }
        return .map(entries)
    }

    init(id: String, title: String, summary: String, requirements: [String], decisions: [String], github: Int? = nil) {
        self.id = id; self.title = title; self.summary = summary
        self.requirements = requirements; self.decisions = decisions; self.github = github
    }

    init(_ value: YAMLValue) {
        id = value["id"]?.string ?? UUID().uuidString.prefix(4).description
        title = value["title"]?.string ?? ""
        summary = value["summary"]?.string ?? ""
        requirements = value["requirements"]?.strings ?? []
        decisions = value["decisions"]?.strings ?? []
        github = value["github"]?.string.flatMap(Int.init)
    }
}

/// A feature: its folder, overview and objects.
struct Feature: Identifiable {
    var id: String { slug }
    let slug: String
    let folder: URL
    var front: FrontMatter
    var overviewBody: String
    var objects: [FeatureObjectKind: [FeatureObject]] = [:]
    var planFront = FrontMatter()
    var planBody = ""
    /// The feature has an overview.md (made by the app). Features written by hand before — a
    /// folder of requirements.md, design.md, … — are listed and read as they are.
    var isStructured = true
    /// Markdown documents in the feature folder itself (besides overview, plan and discussion).
    var documents: [URL] = []
    /// Title found in the documents (first heading) when the overview has none.
    var documentTitle: String?
    /// GitHub issues the feature refers to (front matter `issue`, links and "issue #n" in its documents).
    var issueNumbers: [Int] = []

    var overviewURL: URL { folder.appendingPathComponent("overview.md") }
    var planURL: URL { folder.appendingPathComponent("implementation/plan.md") }
    var discussionURL: URL { folder.appendingPathComponent("discussion.md") }

    var title: String {
        if !front.string("title").isEmpty { return front.string("title") }
        if let documentTitle { return documentTitle }
        return slug.replacingOccurrences(of: "-", with: " ").capitalized
    }
    var status: String { front.string("status").isEmpty ? (isStructured ? "idea" : "draft") : front.string("status") }

    func list(_ kind: FeatureObjectKind) -> [FeatureObject] { objects[kind] ?? [] }

    var allObjects: [FeatureObject] { FeatureObjectKind.allCases.flatMap { list($0) } }

    func object(_ id: String) -> FeatureObject? { allObjects.first { $0.id == id } }

    /// Understanding dimension → known | partial | unknown | n/a.
    var understanding: [(dimension: String, state: String)] {
        let stored = front["understanding"]?.entries ?? []
        return FeatureVocabulary.understanding.map { dimension in
            (dimension, stored.first { $0.key == dimension }?.value.string ?? "unknown")
        }
    }

    /// What is known, or still missing, about a dimension (the AI's note).
    func understandingNote(_ dimension: String) -> String {
        front["understanding_notes"]?[dimension]?.string ?? ""
    }

    /// The AI's estimate of questions still needed before a first ready specification.
    var questionsLeft: Int? { Int(front.string("questions_left")) }

    /// Requirements that count: not rejected, not merged into another (superseded).
    var activeRequirements: [FeatureObject] {
        list(.requirement).filter { $0.status != "rejected" && $0.status != "superseded" }
    }

    /// Discovery questions already answered or skipped.
    var discoveryAnswered: Int {
        list(.question).filter { $0.front.string("origin") == "explore" && ($0.status == "answered" || $0.status == "deferred") }.count
    }

    /// Dimensions still to clarify (unknown or partial). Discovery asks only about these.
    var openDimensions: [String] {
        understanding.filter { $0.state == "unknown" || $0.state == "partial" }.map(\.dimension)
    }

    /// The feature is understood: every dimension known or not applicable — discovery ends.
    var isUnderstood: Bool { openDimensions.isEmpty }

    var epic: Int? { planFront.string("epic").isEmpty ? nil : Int(planFront.string("epic")) }
    var planIssues: [PlannedIssue] { (planFront["issues"]?.list ?? []).map(PlannedIssue.init) }

    /// Next free id for a kind: REQ-001, REQ-002… — above every id in front matter and every
    /// file name in the folder (a copied file keeps its old id inside).
    func nextID(_ kind: FeatureObjectKind) -> String {
        var numbers = list(kind).compactMap { Int($0.id.split(separator: "-").last ?? "") }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(kind.folder).path)) ?? []
        numbers += names.compactMap { name in
            guard name.hasPrefix(kind.prefix + "-") else { return nil }
            return Int(name.dropFirst(kind.prefix.count + 1).prefix { $0.isNumber })
        }
        return String(format: "%@-%03d", kind.prefix, (numbers.max() ?? 0) + 1)
    }

    // MARK: Graph (spec §21–22)

    /// Objects that link to `id`, with the relation.
    func incoming(_ id: String) -> [(from: FeatureObject, relation: String)] {
        allObjects.flatMap { object in
            object.links.filter { $0.target == id }.map { (object, $0.relation) }
        }
    }

    /// What `id` links to (existing objects only), with the relation.
    func outgoing(_ id: String) -> [(to: FeatureObject, relation: String)] {
        guard let object = object(id) else { return [] }
        return object.links.compactMap { link in self.object(link.target).map { ($0, link.relation) } }
    }

    /// Planned issues that include a requirement.
    func issues(for requirement: String) -> [PlannedIssue] {
        planIssues.filter { $0.requirements.contains(requirement) }
    }

    /// Everything a change to `id` may affect (spec §27): requirements that cite it or were
    /// produced by it, then requirements depending on those, and their issues.
    func impact(of id: String) -> (requirements: [FeatureObject], issues: [PlannedIssue]) {
        var affected: [String] = []
        var queue = [id]
        while let current = queue.first {
            queue.removeFirst()
            var next: [String] = []
            for object in list(.requirement) where !affected.contains(object.id) && object.id != id {
                if object.links.contains(where: { $0.target == current }) { next.append(object.id) }
            }
            // A decision's own "produces" list.
            if let source = self.object(current) {
                next += source.front.strings("produces").filter { !affected.contains($0) && $0 != id }
            }
            let fresh = next.filter { !affected.contains($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            affected += fresh
            queue += fresh
        }
        let requirements = affected.compactMap { object($0) }.filter { $0.kind == .requirement }
        let issues = planIssues.filter { issue in issue.requirements.contains(where: affected.contains) || issue.decisions.contains(id) }
        return (requirements, issues)
    }

    // MARK: Readiness (spec §18) — explicit, measurable conditions only

    struct ReadinessCondition: Identifiable {
        var id: String { name }
        let name: String
        let done: Int
        let total: Int
        var ratio: Double { total == 0 ? 1 : Double(done) / Double(total) }
        var met: Bool { done == total }
    }

    var readinessConditions: [ReadinessCondition] {
        let requirements = activeRequirements
        let approved = requirements.filter { $0.status == "approved" }
        let blocking = list(.question).filter(\.isBlocking)
        let seriousFindings = list(.finding).filter { ["blocker", "high"].contains($0.front.string("severity")) }
        let contradictions = list(.finding).filter { $0.front.string("category") == "contradiction" }
        let decisions = list(.decision).filter { $0.status != "rejected" && $0.status != "superseded" }
        let known = understanding.filter { $0.state == "known" || $0.state == "n/a" }
        let covered = Set(planIssues.flatMap(\.requirements))
        var conditions = [
            ReadinessCondition(name: "Feature understood", done: known.count, total: understanding.count),
            ReadinessCondition(name: "Requirements approved", done: approved.count, total: max(requirements.count, 1)),
            ReadinessCondition(name: "Acceptance criteria defined",
                               done: requirements.filter { !$0.acceptanceCriteria.isEmpty }.count, total: max(requirements.count, 1)),
            ReadinessCondition(name: "Blocking questions resolved", done: blocking.filter(\.isClosed).count, total: blocking.count),
            ReadinessCondition(name: "Blocker/high findings closed", done: seriousFindings.filter(\.isClosed).count, total: seriousFindings.count),
            ReadinessCondition(name: "Contradictions resolved", done: contradictions.filter(\.isClosed).count, total: contradictions.count),
            ReadinessCondition(name: "Decisions accepted", done: decisions.filter { $0.status == "accepted" }.count, total: decisions.count),
        ]
        if !planIssues.isEmpty {
            conditions.append(ReadinessCondition(name: "Implementation coverage",
                                                 done: approved.filter { covered.contains($0.id) }.count, total: approved.count))
        }
        return conditions
    }

    /// Average of the ratios of the conditions that have something to measure, 0…100. A
    /// condition with nothing to check yet (no findings, no blocking questions) is shown but not
    /// counted, so an empty feature is not "ready"; requirements always count.
    var readiness: Int {
        let conditions = readinessConditions.filter { $0.total > 0 }
        guard !conditions.isEmpty else { return 0 }
        return Int((conditions.map(\.ratio).reduce(0, +) / Double(conditions.count) * 100).rounded())
    }

    // MARK: Loading

    static func load(folder: URL) -> Feature? {
        let fm = FileManager.default
        let overview = folder.appendingPathComponent("overview.md")
        let text = try? String(contentsOf: overview, encoding: .utf8)
        let (front, body) = text.map(FrontMatter.split) ?? (FrontMatter(), "")
        var feature = Feature(slug: folder.lastPathComponent, folder: folder, front: front, overviewBody: body)
        feature.isStructured = text != nil
        let own: Set<String> = ["overview.md", "discussion.md"]
        feature.documents = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" && !own.contains($0.lastPathComponent) }
            .sorted { Self.documentOrder($0.lastPathComponent) < Self.documentOrder($1.lastPathComponent) }
        // A folder with nothing to read (assets, images) is not a feature.
        guard feature.isStructured || !feature.documents.isEmpty else { return nil }
        var texts = [body]
        for document in feature.documents.prefix(12) {
            guard let content = try? String(contentsOf: document, encoding: .utf8) else { continue }
            texts.append(String(content.prefix(200_000)))
            if feature.documentTitle == nil, let heading = content.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("# ") })?.dropFirst(2).trimmingCharacters(in: .whitespaces), !heading.isEmpty {
                // "Requirements: Dock Panel Collapse" → "Dock Panel Collapse"
                let parts = heading.split(separator: ":", maxSplits: 1)
                feature.documentTitle = parts.count == 2 && parts[0].count < 30
                    ? parts[1].trimmingCharacters(in: .whitespaces) : heading
            }
        }
        feature.issueNumbers = Self.issueReferences(in: texts, front: front)
        for kind in FeatureObjectKind.allCases {
            let dir = folder.appendingPathComponent(kind.folder)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            feature.objects[kind] = files
                .filter { $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix(kind.prefix + "-") }
                .compactMap { FeatureObject.load(kind: kind, url: $0) }
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }
        if let plan = try? String(contentsOf: feature.planURL, encoding: .utf8) {
            (feature.planFront, feature.planBody) = FrontMatter.split(plan)
        }
        return feature
    }
}

extension Feature {
    /// README first, then requirements, design, decisions, plans, tests, the rest by name.
    static func documentOrder(_ name: String) -> String {
        let order = ["readme", "requirements", "design", "decisions", "implementation", "test"]
        let lower = name.lowercased()
        let rank = order.firstIndex { lower.hasPrefix($0) } ?? order.count
        return "\(rank)-\(lower)"
    }

    /// GitHub issue numbers mentioned: front matter `issue`/`issues`, issue links and "issue #n".
    static func issueReferences(in texts: [String], front: FrontMatter) -> [Int] {
        var numbers = Set<Int>()
        for value in front.strings("issue") + front.strings("issues") {
            if let n = Int(value.filter(\.isNumber)) { numbers.insert(n) }
        }
        // Issue links, and "issue #n", "epic #n", "PR #n" (GitHub opens a PR at its issue number too).
        let patterns = [#"github\.com/[^/\s]+/[^/\s]+/(?:issues|pull)/(\d+)"#,
                        #"(?i)\b(?:issue|issues|gh|epic|pr|pull request)\s*:?\s*#(\d+)"#]
        for text in texts {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: range) {
                    if let r = Range(match.range(at: 1), in: text), let n = Int(text[r]) { numbers.insert(n) }
                }
            }
        }
        return numbers.sorted()
    }
}

/// A bug report in docs/bugs/ (made by "New Bug", or written by hand).
struct BugReport: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    var key: String
    var title: String
    var status: String
    var severity: String
    var issueNumbers: [Int]

    static func load(_ url: URL) -> BugReport? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (front, body) = FrontMatter.split(text)
        let heading = body.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
        let name = url.deletingPathExtension().lastPathComponent
        return BugReport(url: url, key: front.string("id").isEmpty ? String(name.prefix(7)) : front.string("id"),
                         title: front.string("title").isEmpty ? (heading ?? name) : front.string("title"),
                         status: front.string("status").isEmpty ? "open" : front.string("status"),
                         severity: front.string("severity"),
                         issueNumbers: Feature.issueReferences(in: [body], front: front))
    }
}

/// "WhatsApp Communication Mirroring" → "whatsapp-communication-mirroring"
func featureSlug(_ title: String) -> String {
    let base = title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
    return String(base).split(separator: "-").prefix(8).joined(separator: "-")
}
