import Foundation

/// The feature workspaces of the open folder (`docs/features/<slug>/`): read from their Markdown
/// files, written back as the user and the AI act on them. Files changed outside the app
/// (editor, git, the AI terminal) are picked up by a light polling of their dates.
@MainActor
final class FeatureStore: ObservableObject {
    /// Features live with the documentation: docs/features/<slug>/.
    static let folderName = "docs/features"

    @Published private(set) var features: [Feature] = [] {
        didSet { observeLifecycle() }
    }
    /// Bug reports in docs/bugs/.
    @Published private(set) var bugs: [BugReport] = []
    /// The project has docs/features/ (the Feature tab is shown only then).
    @Published private(set) var hasFeaturesFolder = false
    /// The project has docs/features/ or docs/bugs/ (the Issues list is shown only then).
    @Published private(set) var hasIssues = false
    @Published var activeSlug: String? {
        didSet {
            guard let root, let activeSlug else { return }
            UserDefaults.standard.set(activeSlug, forKey: Self.activeKey(root))
        }
    }
    @Published var lastError: String?

    private(set) var root: URL?
    private var pollTask: Task<Void, Never>?
    private var fingerprint = ""
    /// Bumped by every write and reset: a background reload that started earlier is dropped.
    private var generation = 0
    private var gitUserName: String?
    /// Status and open questions of each feature as last seen; nil until the first load, which
    /// only records the baseline (no backfill, DEC-013).
    private var lifecycleBaseline: [String: LifecycleSnapshot]?
    /// Features whose next change is the app's own reset, not a lifecycle transition.
    private var lifecycleQuiet: Set<String> = []
    /// The AI side of the workspaces (explore, review, actions…).
    private(set) lazy var assistant = FeatureAssistant(store: self)

    var featuresFolder: URL? { root?.appendingPathComponent(Self.folderName, isDirectory: true) }
    var bugsFolder: URL? { root?.appendingPathComponent("docs/bugs", isDirectory: true) }

    var active: Feature? {
        features.first { $0.slug == activeSlug } ?? features.first
    }

    func feature(_ slug: String) -> Feature? { features.first { $0.slug == slug } }

    private static func activeKey(_ root: URL) -> String {
        "features.active." + String(ContentHash.of(root.standardizedFileURL.path).prefix(12))
    }

    // MARK: Setup and loading

    func setup(root: URL) {
        guard self.root != root else { return }
        reset()
        self.root = root
        activeSlug = UserDefaults.standard.string(forKey: Self.activeKey(root))
        reload()
        loadGitUser()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.reloadIfChanged()
            }
        }
    }

    func reset() {
        generation += 1
        if let project = lifecycleProject { LifecycleLog.shared.release(project, by: self) }
        lifecycleBaseline = nil
        lifecycleQuiet = []
        pollTask?.cancel()
        pollTask = nil
        root = nil
        features = []
        bugs = []
        hasFeaturesFolder = false
        hasIssues = false
        fingerprint = ""
        lastError = nil
    }

    /// Read every feature again (off the main thread).
    func reload() {
        guard let folder = featuresFolder, let bugsFolder else { return }
        let started = generation
        Task {
            let (loaded, bugList, print) = await Task.detached { () -> ([Feature], [BugReport], String) in
                (Self.loadAll(folder), Self.loadBugs(bugsFolder), Self.fingerprint(folder) + "#" + Self.fingerprint(bugsFolder))
            }.value
            // The app wrote something meanwhile: this read may miss it.
            guard folder == featuresFolder, started == generation else { return }
            features = loaded
            bugs = bugList
            updateFolderFlags()
            fingerprint = print
            if let activeSlug, !loaded.contains(where: { $0.slug == activeSlug }) { self.activeSlug = loaded.first?.slug }
        }
    }

    private func reloadIfChanged() {
        guard let folder = featuresFolder, let bugsFolder else { return }
        let started = generation
        Task {
            let print = await Task.detached { Self.fingerprint(folder) + "#" + Self.fingerprint(bugsFolder) }.value
            if started == generation, print != fingerprint { reload() }
        }
    }

    private func updateFolderFlags() {
        let fm = FileManager.default
        hasFeaturesFolder = featuresFolder.map { fm.fileExists(atPath: $0.path) } ?? false
        hasIssues = hasFeaturesFolder || (bugsFolder.map { fm.fileExists(atPath: $0.path) } ?? false)
    }

    nonisolated private static func loadBugs(_ folder: URL) -> [BugReport] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" && $0.lastPathComponent.lowercased() != "readme.md" }
            .compactMap(BugReport.load)
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedDescending }
    }

    nonisolated private static func loadAll(_ folder: URL) -> [Feature] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap(Feature.load(folder:))
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Paths and modification dates of every file under `features/`.
    nonisolated private static func fingerprint(_ folder: URL) -> String {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                              options: [.skipsHiddenFiles]) else { return "" }
        var parts: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            parts.append(url.path + "@" + String(date))
        }
        return parts.sorted().joined(separator: "|")
    }

    /// Is `url` a file of one of the features? Returns the feature and, for an object, the object.
    func locate(_ url: URL) -> (feature: Feature, object: FeatureObject?)? {
        let path = url.standardizedFileURL.path
        for feature in features where path.hasPrefix(feature.folder.standardizedFileURL.path + "/") {
            let object = feature.allObjects.first { $0.url.standardizedFileURL.path == path }
            return (feature, object)
        }
        return nil
    }

    // MARK: People

    /// Default owner of new questions and decisions (git user.name).
    var defaultOwner: String { gitUserName ?? "" }

    /// Who lifecycle events are recorded for: git user.name of the project, else the macOS
    /// user (DEC-011).
    var lifecycleActor: String {
        if let gitUserName, !gitUserName.isEmpty { return gitUserName }
        return NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    }

    private func loadGitUser() {
        guard let root else { return }
        Task {
            let output = await GitHubClient.execute(["config", "user.name"], in: root, git: true)
            gitUserName = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: Writing

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    static var today: String { dateFormatter.string(from: Date()) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Create a feature: its folder and overview. Returns its slug.
    @discardableResult
    func createFeature(title: String, idea: String) -> String? {
        guard let folder = featuresFolder else { return nil }
        var slug = featureSlug(title)
        if slug.isEmpty { slug = "feature" }
        var candidate = slug
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(slug)-\(n)"; n += 1
        }
        var front = FrontMatter()
        front.set("type", "feature")
        front.set("id", candidate)
        front.set("title", title)
        front.set("status", idea.isEmpty ? "idea" : "exploring")
        front.set("owner", defaultOwner)
        front.set("created", Self.today)
        front.set("provenance", "Created manually")
        front["understanding"] = .map(FeatureVocabulary.understanding.map { ($0, YAMLValue.string("unknown")) })
        let body = "# \(title)\n\n## Idea\n\n\(idea.isEmpty ? "_Describe the idea._" : idea)\n\n## Problem\n\n## Scope\n"
        do {
            try write(front.join(body: body), to: folder.appendingPathComponent(candidate).appendingPathComponent("overview.md"))
        } catch {
            lastError = "Could not create the feature: \(error.localizedDescription)"
            return nil
        }
        activeSlug = candidate
        recordLifecycle(.ideaCreated, feature: candidate)
        reloadSync()
        return candidate
    }

    /// Reload now (after the app's own writes, so the UI shows them at once). Only the feature
    /// written is read again; older background reloads are dropped.
    func reloadSync(_ slug: String? = nil) {
        guard let folder = featuresFolder else { return }
        generation += 1
        if let slug, let index = features.firstIndex(where: { $0.slug == slug }),
           let feature = Feature.load(folder: folder.appendingPathComponent(slug)) {
            features[index] = feature
        } else {
            features = Self.loadAll(folder)
        }
        if let bugsFolder { bugs = Self.loadBugs(bugsFolder) }
        updateFolderFlags()
        fingerprint = ""  // the poll re-reads the dates and settles
    }

    /// Create an object file; returns it.
    @discardableResult
    func create(_ kind: FeatureObjectKind, in slug: String, title: String, fields: [(String, YAMLValue)] = [],
                body: String, provenance: String) -> FeatureObject? {
        guard let feature = feature(slug) else { return nil }
        var id = feature.nextID(kind)
        let dir = feature.folder.appendingPathComponent(kind.folder)
        // Never over an existing file (another window, git, a copy made meanwhile).
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(id + ".md").path) {
            let number = (Int(id.split(separator: "-").last ?? "") ?? 0) + 1
            id = String(format: "%@-%03d", kind.prefix, number)
        }
        var front = FrontMatter()
        front.set("type", kind.rawValue)
        front.set("id", id)
        front.set("feature", slug)
        front.set("title", title)
        for (key, value) in fields { front[key] = value }
        if front["status"] == nil {
            let initial: [FeatureObjectKind: String] = [.requirement: "draft", .question: "open", .decision: "proposed", .finding: "open"]
            if let status = initial[kind] { front.set("status", status) }
        }
        if [.question, .decision].contains(kind), front["owner"] == nil { front.set("owner", defaultOwner) }
        front.set("created", Self.today)
        front.set("provenance", provenance)
        let url = dir.appendingPathComponent(id + ".md")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // withoutOverwriting: fails instead of replacing a file that appeared meanwhile.
            try Data(front.join(body: body).utf8).write(to: url, options: .withoutOverwriting)
        } catch {
            lastError = "Could not write \(id): \(error.localizedDescription)"
            return nil
        }
        reloadSync(slug)
        return self.feature(slug)?.object(id)
    }

    /// Change an object: read from disk now (the user may just have edited it), change,
    /// write. Front matter the app cannot rewrite without losing something is left alone.
    func update(_ id: String, in slug: String, _ change: (inout FrontMatter, inout String) -> Void) {
        guard let cached = feature(slug)?.object(id),
              var object = FeatureObject.load(kind: cached.kind, url: cached.url) else { return }
        guard object.front.isLossless else {
            lastError = "\(id) has YAML the app cannot rewrite safely (comments or unusual structure) — change it in the editor."
            return
        }
        change(&object.front, &object.body)
        object.front.set("updated", Self.today)
        do { try write(object.text(), to: object.url) } catch {
            lastError = "Could not save \(id): \(error.localizedDescription)"
        }
        reloadSync(slug)
    }

    /// Move feature objects to the Trash. Links to them elsewhere (requirements, decisions,
    /// questions, findings, the plan) move to what replaced them (superseded_by, followed through
    /// chains) or are removed. Returns how many files went.
    @discardableResult
    func cleanUp(_ slug: String, ids: Set<String>) -> Int {
        guard let feature = feature(slug) else { return 0 }
        let doomed = feature.allObjects.filter { ids.contains($0.id) }
        guard !doomed.isEmpty else { return 0 }
        let doomedIDs = Set(doomed.map(\.id))
        // old id → replacement, nil = removed
        var replacement: [String: String?] = [:]
        for object in doomed {
            var target = object.front.string("superseded_by")
            var seen: Set<String> = [object.id]
            while let next = feature.object(target), doomedIDs.contains(next.id), !seen.contains(next.id) {
                seen.insert(next.id)
                target = next.front.string("superseded_by")
            }
            replacement[object.id] = feature.object(target) != nil && !doomedIDs.contains(target) ? target : nil
        }
        // `owner`: the object holding the links; a merged requirement's sources would otherwise
        // point at itself.
        func rewrite(_ ids: [String], owner: String? = nil) -> [String] {
            var out: [String] = []
            for id in ids {
                let mapped: String?
                if let entry = replacement[id] { mapped = entry } else { mapped = id }
                if let mapped, mapped != owner, !out.contains(mapped) { out.append(mapped) }
            }
            return out
        }
        let listKeys = ["depends_on", "decisions", "sources", "blocking", "produces", "requirements", "questions",
                        "refs", "related", "supersedes"]
        let scalarKeys = ["resolved_by", "superseded_by"]
        let survivors = feature.allObjects.filter { !doomedIDs.contains($0.id) }
        let touched = survivors.filter { object in
            listKeys.contains { !Set(object.front.strings($0)).isDisjoint(with: doomedIDs) }
                || scalarKeys.contains { doomedIDs.contains(object.front.string($0)) }
        }
        updateMany(touched.map(\.id), in: slug) { id, front, _ in
            for key in listKeys where front[key] != nil {
                let old = front.strings(key)
                let new = rewrite(old, owner: id)
                if new != old { front.set(key, list: new) }
            }
            for key in scalarKeys where doomedIDs.contains(front.string(key)) {
                let mapped = replacement[front.string(key)] ?? nil
                front.set(key, mapped == id ? nil : mapped)
            }
        }
        // The plan's issues (savePlan regenerates the plan body, so only when a link changed).
        if let current = self.feature(slug),
           current.planIssues.contains(where: { !Set($0.requirements + $0.decisions).isDisjoint(with: doomedIDs) }) {
            let issues = current.planIssues.map { issue -> PlannedIssue in
                var issue = issue
                issue.requirements = rewrite(issue.requirements)
                issue.decisions = rewrite(issue.decisions)
                return issue
            }
            let title = current.planFront.string("title").isEmpty ? current.title : current.planFront.string("title")
            savePlan(slug, title: title, issues: issues, epic: current.epic)
        }
        var removed = 0
        for object in doomed {
            if (try? FileManager.default.trashItem(at: object.url, resultingItemURL: nil)) != nil { removed += 1 }
        }
        reloadSync(slug)
        return removed
    }

    /// Move a feature's whole folder to the Trash (not offered once implementation started).
    @discardableResult
    func deleteFeature(_ slug: String) -> Bool {
        guard let feature = feature(slug), !feature.isImplemented else { return false }
        do {
            try FileManager.default.trashItem(at: feature.folder, resultingItemURL: nil)
        } catch {
            lastError = "Could not delete the feature: \(error.localizedDescription)"
            return false
        }
        if activeSlug == slug { activeSlug = features.first { $0.slug != slug }?.slug }
        reloadSync()
        return true
    }

    /// Start a feature over from its idea: everything produced from it (requirements, questions,
    /// decisions, findings, research, the plan, the discussion) goes to the Trash; the overview (the
    /// idea) and the attached sources stay; status back to idea, understanding unknown.
    @discardableResult
    func restartFeature(_ slug: String) -> Bool {
        guard let feature = feature(slug), feature.isStructured, !feature.isImplemented else { return false }
        let fm = FileManager.default
        let produced = FeatureObjectKind.allCases.filter { $0 != .source }.map { feature.folder.appendingPathComponent($0.folder) }
            + [feature.planURL.deletingLastPathComponent(), feature.discussionURL]
        // Its questions go to the Trash: not "questions resolved".
        lifecycleQuiet.insert(slug)
        defer { lifecycleQuiet.remove(slug) }
        for url in produced where fm.fileExists(atPath: url.path) {
            do { try fm.trashItem(at: url, resultingItemURL: nil) } catch {
                lastError = "Could not restart the feature: \(error.localizedDescription)"
                reloadSync(slug)
                return false
            }
        }
        updateFeature(slug) { front, _ in
            front.set("status", "idea")
            for key in ["understanding", "understanding_notes", "questions_left"] { front[key] = nil }
            front.set("restarted", Self.today)
        }
        reloadSync(slug)
        return true
    }

    /// Change many objects with one reload at the end (consolidation touches hundreds).
    func updateMany(_ ids: [String], in slug: String, _ change: (String, inout FrontMatter, inout String) -> Void) {
        guard let feature = feature(slug) else { return }
        for id in ids {
            guard let cached = feature.object(id), var object = FeatureObject.load(kind: cached.kind, url: cached.url),
                  object.front.isLossless else { continue }
            change(id, &object.front, &object.body)
            object.front.set("updated", Self.today)
            try? write(object.text(), to: object.url)
        }
        reloadSync(slug)
    }

    func setStatus(_ id: String, in slug: String, to status: String) {
        update(id, in: slug) { front, _ in front.set("status", status) }
    }

    /// Change the overview (status, understanding…).
    func updateFeature(_ slug: String, _ change: (inout FrontMatter, inout String) -> Void) {
        guard let feature = feature(slug) else { return }
        // A hand-written feature gets its overview.md the first time the app records something;
        // its own documents are left as they are.
        let text = (try? String(contentsOf: feature.overviewURL, encoding: .utf8)) ?? adoptedOverview(feature)
        var (front, body) = FrontMatter.split(text)
        guard front.isLossless else {
            lastError = "The overview of \(feature.title) has YAML the app cannot rewrite safely — change it in the editor."
            return
        }
        change(&front, &body)
        do { try write(front.join(body: body), to: feature.overviewURL) } catch {
            lastError = "Could not save the overview: \(error.localizedDescription)"
        }
        reloadSync(slug)
    }

    private func adoptedOverview(_ feature: Feature) -> String {
        var front = FrontMatter()
        front.set("type", "feature")
        front.set("id", feature.slug)
        front.set("title", feature.title)
        front.set("status", "draft")
        front.set("owner", defaultOwner)
        front.set("created", Self.today)
        front.set("provenance", "Adopted existing feature documents")
        front["understanding"] = .map(FeatureVocabulary.understanding.map { ($0, YAMLValue.string("unknown")) })
        let list = feature.documents.map { "- [\($0.lastPathComponent)](\($0.lastPathComponent))" }.joined(separator: "\n")
        return front.join(body: "# \(feature.title)\n\n## Documents\n\n\(list)\n")
    }

    func setUnderstanding(_ slug: String, _ states: [String: String]) {
        updateFeature(slug) { front, _ in
            var current = front["understanding"]?.entries ?? []
            for (dimension, state) in states where FeatureVocabulary.understandingStates.contains(state) {
                if let i = current.firstIndex(where: { $0.key == dimension }) { current[i].value = .string(state) }
                else if FeatureVocabulary.understanding.contains(dimension) { current.append((dimension, .string(state))) }
            }
            front["understanding"] = .map(current)
        }
    }

    /// Replace the implementation plan (issues and the epic's GitHub number).
    func savePlan(_ slug: String, title: String, issues: [PlannedIssue], epic: Int?) {
        guard let feature = feature(slug) else { return }
        var front = feature.planFront
        front.set("type", "plan")
        front.set("feature", slug)
        front.set("title", title)
        front.set("epic", epic.map(String.init))
        front["issues"] = .list(issues.map(\.yaml))
        front.set("updated", Self.today)
        var body = "# Implementation plan — \(feature.title)\n\n"
        for issue in issues {
            body += "## \(issue.id): \(issue.title)\(issue.github.map { " (#\($0))" } ?? "")\n\n\(issue.summary)\n\n"
            body += "Requirements: \(issue.requirements.joined(separator: ", "))\n"
            if !issue.decisions.isEmpty { body += "Decisions: \(issue.decisions.joined(separator: ", "))\n" }
            body += "\n"
        }
        do { try write(front.join(body: body), to: feature.planURL) } catch {
            lastError = "Could not save the plan: \(error.localizedDescription)"
        }
        reloadSync(slug)
    }

    /// Add a turn to the feature's discussion log (discussion.md).
    func appendDiscussion(_ slug: String, speaker: String, text: String) {
        guard let feature = feature(slug) else { return }
        let url = feature.discussionURL
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Discussion — \(feature.title)\n"
        existing += "\n### \(speaker) · \(Self.today)\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        try? write(existing, to: url)
    }

    /// Last turns of the discussion (for the AI's context).
    func discussion(_ slug: String, limit: Int = 12_000) -> String {
        guard let feature = feature(slug), let text = try? String(contentsOf: feature.discussionURL, encoding: .utf8) else { return "" }
        return String(text.suffix(limit))
    }

    // MARK: Lifecycle events (docs/features/lifecycle-event-log-cycle-time-analytics)

    /// Events are keyed by the project root's absolute path (DEC-012).
    var lifecycleProject: String? { root?.standardizedFileURL.path }

    func lifecycleEvents(_ slug: String) -> [LifecycleEvent] {
        guard let project = lifecycleProject else { return [] }
        return LifecycleLog.shared.events(project: project, feature: slug)
    }

    @discardableResult
    func recordLifecycle(_ stage: LifecycleStage, feature slug: String, source: LifecycleSource = .automatic,
                         model: String? = nil, note: String? = nil) -> LifecycleEvent? {
        guard let project = lifecycleProject else { return nil }
        return LifecycleLog.shared.record(stage, project: project, feature: slug, actor: lifecycleActor,
                                          source: source, model: model, note: note)
    }

    /// Compare every freshly read list with the last one: status into 'ready' records "spec
    /// ready", open questions from ≥ 1 to 0 records "questions resolved" (DEC-008). Changes made
    /// by the app and in files (editor, git, the AI terminal) alike.
    private func observeLifecycle() {
        guard let project = lifecycleProject else { return }
        let current = Dictionary(features.map { ($0.slug, LifecycleSnapshot($0)) }, uniquingKeysWith: { a, _ in a })
        defer { lifecycleBaseline = current }
        guard let previous = lifecycleBaseline, LifecycleLog.shared.claim(project, by: self) else { return }
        for (slug, now) in current where !lifecycleQuiet.contains(slug) {
            guard let before = previous[slug] else { continue }  // new or renamed: no transition seen
            if before.openQuestions > 0 && now.openQuestions == 0 { recordLifecycle(.questionsResolved, feature: slug) }
            if before.status != "ready" && now.status == "ready" { recordLifecycle(.specReady, feature: slug) }
        }
    }

    // MARK: History (spec §30)

    /// Recent commits touching a path: "abc1234 · 2 days ago · Boris · message".
    func history(of url: URL, limit: Int = 15) async -> [String] {
        guard let root else { return [] }
        let output = await GitHubClient.execute(["log", "-n", String(limit), "--format=%h · %ar · %an · %s", "--", url.path],
                                                in: root, git: true)
        return output.stdout.split(separator: "\n").map(String.init)
    }

    /// Project-relative path for display and for the AI.
    func relativePath(_ url: URL) -> String {
        guard let root else { return url.path }
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

/// What lifecycle capture watches in a feature.
struct LifecycleSnapshot: Equatable {
    let status: String
    let openQuestions: Int

    init(_ feature: Feature) {
        status = feature.status
        openQuestions = feature.list(.question).filter { !$0.isClosed }.count
    }
}
