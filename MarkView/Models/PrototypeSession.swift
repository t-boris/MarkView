import AppKit
import Foundation
import SwiftUI

/// One open prototype in Prototype Studio: the files on disk, the review conversation, and the
/// run that is changing them. The preview (`PrototypeStudioView`) shows `siteIndex` and reloads when
/// `reloadToken` changes.
@MainActor
final class PrototypeSession: ObservableObject, Identifiable {
    struct Message: Identifiable {
        enum Role { case user, assistant, error }
        let id = UUID()
        var role: Role
        var text: String
        /// Images sent with the message, shown small under the text.
        var images: [NSImage] = []
        /// File names of those images in `attachments/`, so the conversation can be restored.
        var imageNames: [String] = []
        /// The request that failed, so the message can offer to run it again.
        var retry: Request?
    }

    /// One reviewer request: the text, the pointed-at element and the saved images that go with it.
    struct Request {
        var instruction: String
        var pick: PrototypeAI.Pick?
        var files: [(url: URL, note: String)]
        /// What the reviewer aimed the request at (REQ-008); kept by a retry and by an edit of the failed request.
        var target: PrototypeAI.Target?
    }

    /// One screen of a build in progress.
    struct ScreenProgress: Identifiable, Equatable {
        let id: String
        var name: String
        var state: PrototypeAI.ScreenState
    }

    struct ActivityLine: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
    }

    let id = UUID()
    let root: URL
    let folder: URL
    /// The prototype's folder name; the tab bar reads it off the main actor.
    nonisolated let slug: String
    @Published private(set) var manifest: PrototypeFiles.Manifest
    @Published private(set) var messages: [Message] = [] {
        didSet { saveConversation() }
    }
    /// A request text handed back to the input field after a failure; the studio view takes it.
    @Published var restoredDraft: String?
    /// What the running assistant is doing; nil when idle.
    @Published private(set) var stage: String?
    /// What the assistant did during the current run, oldest first.
    @Published private(set) var activity: [ActivityLine] = []
    @Published private(set) var runStarted: Date?
    /// The stage of a staged build ("Step 2 of 3 · …"); nil otherwise.
    @Published private(set) var phase: String?
    /// The screens of the build in progress, with what each is doing.
    @Published private(set) var screens: [ScreenProgress] = []
    @Published private(set) var reloadToken = 0
    @Published private(set) var runtimeErrors: [String] = []
    /// What the last check of the preview still found after the fix round (BUG-062): the header says so, and the reviewer can run the
    /// round again. Empty when the screens are fine, and while a new version has not been checked yet.
    @Published private(set) var unresolvedProblems: [String] = []
    /// Code mode: whether each unit of the prototype matches the code, computed locally from the baseline (REQ-014); nil until checked.
    @Published private(set) var syncStatus: PrototypeBaseline.Status?
    @Published private(set) var checkingSync = false
    /// The hand-off of prototype changes to an agent that changes the code (REQ-012); nil when no hand-off is being offered. Closing
    /// it stops the draft's pictures and descriptions and removes what they made.
    @Published var handoff: Handoff? {
        didSet {
            guard handoff == nil else { return }
            handoffRun?.close()
            handoffRun = nil
        }
    }
    /// The draft of the feature the hand-off creates, with its pictures and descriptions (REQ-016 to REQ-018); nil when there is nothing to hand off.
    @Published private(set) var handoffRun: PrototypeHandoffRun?
    @Published private(set) var preparingHandoff = false

    struct Handoff: Equatable {
        var changes: PrototypeHandoff.Changes
        /// Empty when there is nothing to hand off.
        var brief: String
    }

    /// What a sync would do, shown for confirmation before anything runs (REQ-011); nil when no sync is being offered.
    @Published var syncPreview: SyncPreview?
    @Published private(set) var preparingSync = false

    struct SyncPreview: Equatable {
        var plan: PrototypeBaseline.SyncPlan
        var status: PrototypeBaseline.Status
        var version: Int
    }
    /// Bumped to ask the preview to open every screen and report the blank, stuck and placeholder ones (BUG-053).
    @Published private(set) var auditToken = 0
    private var auditReport: PrototypeAudit.Report?
    private var auditActive = false
    private var auditAcknowledged = false
    /// Screens of the last build that could not be written: the build reply names them, the fix round skips them.
    private var failedScreens: Set<String> = []
    @Published private(set) var archive: URL?
    /// A screen or a source component the next request is about; nil means the whole prototype (or the pointed-at element, `pick`).
    @Published var target: PrototypeAI.Target? {
        didSet { if target != nil { pick = nil } }
    }

    /// The screens a request can be aimed at: the scripts in `screens/`, named from the manifest when a name matches the file.
    var screenTargets: [PrototypeAI.Target] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: siteFolder.appendingPathComponent("screens").path)) ?? []
        let ids = files.filter { $0.hasSuffix(".js") }.map { String($0.dropLast(3)) }
        let known = manifest.screens
        let ordered = ids.sorted { lhs, rhs in
            let l = known.firstIndex { PrototypeAI.Plan.slug($0) == lhs } ?? Int.max
            let r = known.firstIndex { PrototypeAI.Plan.slug($0) == rhs } ?? Int.max
            return l == r ? lhs < rhs : l < r
        }
        return ordered.map { id in .screen(id: id, name: known.first { PrototypeAI.Plan.slug($0) == id } ?? id) }
    }

    /// The source components a request can be aimed at; empty unless the prototype records components (REQ-008).
    var componentTargets: [PrototypeAI.Target] {
        manifest.components.map { .component(path: $0.path, label: $0.label, page: $0.page, screens: $0.screens) }
    }

    @Published var pick: PrototypeAI.Pick? {
        didSet {
            if pick != nil { target = nil }
            if pick == nil { pickShot = nil }
            // A pick selects its component in the Components list (REQ-007); a pick without one leaves the list alone.
            if let component = pick?.component, !component.isEmpty { selectedComponent = component }
        }
    }
    /// The component selected in the Components list, by source path: its instances are outlined in the preview.
    @Published var selectedComponent: String?
    /// How many elements of `selectedComponent` the loaded page holds; nil until the preview counted them.
    @Published var highlightedInstances: Int?
    /// The page the preview shows instead of `index.html`: a component's isolated view, relative to `site/`
    /// ("View alone"); nil shows the screens.
    @Published var shownPage: String?
    /// A screenshot of the pointed-at element, taken when it was clicked.
    @Published var pickShot: Data?
    /// The images waiting to be sent with the next request (REQ-005); the request box edits them through a binding.
    @Published var attachments = ImageAttachmentList()
    @Published var pickMode = false

    /// Adds a finished run to the workspace's usage counter.
    var record: PrototypeAI.Record = { _ in }
    /// Appended to prompts when the person chose an output language (empty: "Document language").
    var languageNote = ""
    /// What every build, sync, revision and fix round gets as its language part: `languageNote`, or for a prototype
    /// made from code the rule to keep the labels of the original (BUG-052).
    var promptLanguage: String { PrototypeAI.languageNote(explicit: languageNote, mode: manifest.mode) }
    /// Code mode: the detected web apps, as hints for the planner (the caller maps them from WebAppPreview).
    var codeScope = PrototypeAI.CodeScope()

    private var task: Task<Void, Never>?
    /// Runs of the assistant that fix reported errors by themselves, per request.
    private static let autoFixRounds = 1

    var isBusy: Bool { stage != nil }
    var siteIndex: URL { PrototypeFiles.site(of: folder).appendingPathComponent("index.html") }
    var siteFolder: URL { PrototypeFiles.site(of: folder) }
    var hasSite: Bool { FileManager.default.fileExists(atPath: siteIndex.path) }
    /// "Sync from code" applies to a code-mode prototype that has a saved version (REQ-006).
    var canSyncFromCode: Bool { manifest.mode == .code && manifest.version > 0 && hasSite }

    /// The component record of a source path, when the manifest lists it.
    func component(at path: String) -> PrototypeFiles.Component? {
        manifest.components.first { $0.path == path }
    }

    /// The source file of a component, when it exists in the project (an "Open source" target).
    func sourceURL(of path: String) -> URL? {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Shows a component's isolated page in the preview, or the screens again with nil.
    func show(page: String?) {
        guard page != shownPage else { return }
        shownPage = page
        reloadToken += 1
    }

    /// A prototype that does not exist yet; `generate()` builds it. In `.code` mode the sources are the
    /// existing web-interface code to reconstruct (Previews from Existing Code).
    init(root: URL, title: String, brief: String, sources: [String], mode: PrototypeFiles.Mode = .requirements) {
        self.root = root.standardizedFileURL
        let slug = PrototypeFiles.slug(for: title, existing: Set(PrototypeFiles.existingSlugs(root: root)))
        self.slug = slug
        folder = PrototypeFiles.folder(root: self.root, slug: slug)
        manifest = PrototypeFiles.Manifest(title: title, slug: slug, brief: brief, sources: sources, mode: mode)
        let scope = sources.isEmpty ? "the project" : sources.joined(separator: ", ")
        let opening = mode == .code ? "Reconstruct the web interface of \(scope)." : "Build a prototype of \(scope)."
        messages = [Message(role: .user, text: brief.isEmpty ? opening : brief)]
    }

    /// A prototype saved earlier; nil when its manifest is missing.
    init?(root: URL, slug: String) {
        let folder = PrototypeFiles.folder(root: root.standardizedFileURL, slug: slug)
        guard let manifest = PrototypeFiles.loadManifest(folder) else { return nil }
        self.root = root.standardizedFileURL
        self.folder = folder
        self.slug = slug
        self.manifest = manifest
        if let stored = PrototypeFiles.loadConversation(folder) {
            let attachments = folder.appendingPathComponent("attachments", isDirectory: true)
            messages = stored.map { item in
                let names = item.images.filter { !$0.contains("/") }
                return Message(role: item.role == "user" ? .user : item.role == "error" ? .error : .assistant, text: item.text,
                               images: names.compactMap { NSImage(contentsOf: attachments.appendingPathComponent($0)) }, imageNames: names)
            }
        } else {
            for entry in manifest.history {
                if !entry.instruction.isEmpty { messages.append(Message(role: .user, text: entry.instruction)) }
                messages.append(Message(role: .assistant, text: "v\(entry.version): \(entry.summary)"))
            }
        }
    }

    /// Saves the whole review conversation beside the manifest, so a reopened prototype shows all of it.
    private func saveConversation() {
        let stored = messages.map { message in
            PrototypeFiles.StoredMessage(role: message.role == .user ? "user" : message.role == .error ? "error" : "assistant",
                                         text: message.text, images: message.imageNames)
        }
        PrototypeFiles.saveConversation(stored, in: folder)
    }

    // MARK: - Runs

    /// Events of a run, applied on the main actor. A build's milestones become versions unless `milestones` is
    /// off: a sync records one version at its end, not the shell on its way (REQ-006).
    private func stageReporter(milestones: Bool = true) -> PrototypeAI.Stage {
        { [weak self] event in Task { @MainActor in self?.apply(event, milestones: milestones) } }
    }

    private func apply(_ event: PrototypeAI.Event, milestones: Bool) {
        guard stage != nil else { return }
        switch event {
        case .status(let text): stage = text
        case .log(let text): log(text)
        case .step(let text): stage = text; log(text)
        case .phase(let text): phase = text; log(text)
        case .plan(let title, let summary, let assumptions, let planned):
            if !title.isEmpty { manifest.title = title }
            manifest.screens = planned.map(\.name)
            manifest.assumptions = assumptions
            screens = planned.map { ScreenProgress(id: $0.id, name: $0.name, state: .queued) }
            var text = "Plan: \(planned.count) screens.\n" + planned.map { "• \($0.name): \($0.purpose)" }.joined(separator: "\n")
            if !summary.isEmpty { text = summary + "\n\n" + text }
            messages.append(Message(role: .assistant, text: text))
        case .screen(let id, let state):
            if let index = screens.firstIndex(where: { $0.id == id }) { screens[index].state = state }
            let done = screens.filter { $0.state == .done }.count
            stage = "Writing the screens (\(done) of \(screens.count) done)"
            switch state {
            case .writing: log("Started: \(screens.first { $0.id == id }?.name ?? id)")
            case .done: log("Done: \(screens.first { $0.id == id }?.name ?? id)")
            case .failed(let problem): log("Failed: \(screens.first { $0.id == id }?.name ?? id) — \(problem)")
            case .queued: break
            }
        case .component(let path, let state):
            // Isolated component views join the progress list after the screens, under their source path.
            let id = "component:" + path
            if let index = screens.firstIndex(where: { $0.id == id }) {
                screens[index].state = state
            } else {
                screens.append(ScreenProgress(id: id, name: "Component \(path)", state: state))
            }
            let components = screens.filter { $0.id.hasPrefix("component:") }
            stage = "Writing the isolated component views (\(components.filter { $0.state == .done }.count) of \(components.count) done)"
            switch state {
            case .writing: log("Started: component \(path)")
            case .done: log("Done: component \(path)")
            case .failed(let problem): log("Could not isolate component \(path) — \(problem)")
            case .queued: break
            }
        case .written: reloadPreview()
        case .milestone(let summary):
            guard milestones else { return }
            do { try accept(instruction: "", summary: summary) } catch { messages.append(Message(role: .error, text: error.localizedDescription)) }
        }
    }

    private func log(_ text: String) {
        guard activity.last?.text != text else { return }
        activity.append(ActivityLine(time: Date(), text: text))
        if activity.count > 300 { activity.removeFirst(activity.count - 300) }
    }

    private func beginRun(_ first: String) {
        activity = []
        runStarted = Date()
        stage = first
        log(first)
    }

    private func endRun() {
        phase = nil
        screens = []
        stage = nil
        runStarted = nil
        task = nil
    }

    /// Builds the prototype from the sources and the brief: plan, foundation, then the screens side by side.
    func generate() {
        guard !isBusy else { return }
        beginRun(manifest.mode == .code ? "Reading the code" : "Reading the requirements")
        task = Task { [self] in
            defer { endRun() }
            do {
                try FileManager.default.createDirectory(at: PrototypeFiles.site(of: folder), withIntermediateDirectories: true)
                let built = try await PrototypeAI.build(root: root, folder: folder, brief: manifest.brief, sources: manifest.sources,
                                                        language: promptLanguage, mode: manifest.mode, codeScope: codeScope,
                                                        record: record, stage: stageReporter())
                adopt(built)
                await refreshThemes(planned: built.themes, defaultID: built.defaultTheme, persist: false)
                if !built.screens.isEmpty {
                    try accept(instruction: "", summary: "All screens: \(built.screens.joined(separator: ", ")).")
                    await writeBaseline(built)
                }
                messages.append(Message(role: .assistant, text: reply(for: built, opening: "The prototype is ready.")))
                await settleFixAndCompare(language: promptLanguage)
            } catch is CancellationError {
                messages.append(Message(role: .error, text: manifest.version > 0
                    ? "Stopped. What was built so far is kept; ask for the missing screens to continue."
                    : "Stopped."))
            } catch {
                messages.append(Message(role: .error, text: error.localizedDescription))
            }
        }
    }

    /// Puts what a build found into the manifest: screens, assumptions, gaps and components. Gaps and components
    /// are fixed at generation (and at a sync); review edits never change them (DEC-004).
    private func adopt(_ built: PrototypeAI.Built) {
        if !built.title.isEmpty { manifest.title = built.title }
        manifest.screens = built.screens + built.failed
        failedScreens = Set(built.failed)
        manifest.assumptions = built.assumptions
        manifest.gaps = built.gaps
        manifest.components = built.components
    }

    /// The assistant's message after a build: summary, screens that failed, assumptions, gaps and components.
    private func reply(for built: PrototypeAI.Built, opening: String) -> String {
        var reply = built.summary.isEmpty ? opening : built.summary
        if !built.failed.isEmpty {
            reply += "\n\nThese screens could not be written: \(built.failed.joined(separator: ", ")). Ask me to build them and I will try again."
        }
        if !built.assumptions.isEmpty {
            reply += "\n\nAssumptions I made:\n" + built.assumptions.map { "• \($0)" }.joined(separator: "\n")
        }
        if !built.gaps.isEmpty {
            reply += "\n\nKnown gaps (what the original does that this prototype only simulates or lacks):\n"
                + built.gaps.map { "• \($0)" }.joined(separator: "\n")
        }
        if !built.components.isEmpty {
            let isolated = built.components.filter { $0.page != nil }.count
            reply += "\n\nSource components linked: \(built.components.count) (\(isolated) with an isolated view). "
                + "Use Components in the preview header to see them."
        }
        return reply
    }

    /// "Hand off to code" (REQ-012): compares the prototype with its baseline and builds the brief for an agent. Nothing is written to the
    /// project and nothing is sent; the person reads and edits the brief first.
    func prepareHandoff() {
        guard manifest.mode == .code, manifest.version > 0, !preparingHandoff else { return }
        preparingHandoff = true
        Task { [self] in
            defer { preparingHandoff = false }
            await refreshSyncStatus()
            let status = syncStatus ?? PrototypeBaseline.status(record: nil, scope: [:], site: [:])
            let site = siteFolder, history = manifest.history
            let changes = await Task.detached { () -> PrototypeHandoff.Changes in
                PrototypeHandoff.changes(status: status, history: history, markers: { path in
                    guard let text = try? String(contentsOf: site.appendingPathComponent(path), encoding: .utf8) else { return [] }
                    return PrototypeFiles.componentMarkers(in: text)
                })
            }.value
            let relative = site.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
            let brief = changes.isEmpty ? "" : PrototypeHandoff.brief(title: manifest.title, reference: PrototypeReference.string(slug: slug),
                                                                      version: manifest.version, siteRelative: relative, changes: changes)
            handoffRun?.close()
            handoffRun = nil
            if !changes.isEmpty {
                let theme = manifest.themes.flatMap { record in record.effective.map { PrototypeScreenshots.Theme(attribute: record.attribute, id: $0) } }
                let run = PrototypeHandoffRun(
                    context: .init(root: root, folder: folder, slug: slug, title: manifest.title, version: manifest.version,
                                   components: manifest.components, theme: theme, changes: changes,
                                   reference: PrototypeReference.string(slug: slug), siteRelative: relative),
                    record: record)
                handoffRun = run
                run.start()
            }
            handoff = Handoff(changes: changes, brief: brief)
        }
    }

    /// "Sync from code" (REQ-010, REQ-011): compares the code with the baseline and offers what a sync would do before anything runs.
    /// The offer is the changed units, or a full rebuild with the reason when the changes cannot be told apart; nothing runs until
    /// the person confirms.
    func previewSync() {
        guard !isBusy, canSyncFromCode, !preparingSync else { return }
        preparingSync = true
        Task { [self] in
            defer { preparingSync = false }
            await refreshSyncStatus()
            let folder = self.folder, version = manifest.version
            let baseline = await Task.detached { PrototypeBaseline.load(folder: folder, version: version) }.value
            let status = syncStatus ?? PrototypeBaseline.status(record: nil, scope: [:], site: [:])
            syncPreview = SyncPreview(plan: PrototypeBaseline.syncPlan(status: status, record: baseline), status: status, version: version)
        }
    }

    /// Incremental sync: writes again only the screens and components whose source files changed, with the stored plan, and records
    /// a new version (REQ-010, REQ-015). A unit that cannot be rebuilt keeps its earlier file and still shows as changed; Stop or a
    /// failure restores the previous version.
    func syncChangedUnits() {
        guard !isBusy, canSyncFromCode, let preview = syncPreview, preview.plan.mode == .incremental else { return }
        let plan = preview.plan
        syncPreview = nil
        beginRun("Reading the changed code")
        let before = manifest
        show(page: nil)
        task = Task { [self] in
            defer { endRun() }
            do {
                let root = self.root, folder = self.folder
                guard let baseline = await Task.detached(operation: { PrototypeBaseline.load(folder: folder, version: before.version) }).value else {
                    throw PrototypeFiles.Failure.edits(["The baseline of v\(before.version) is missing; use Rebuild everything."])
                }
                let synced = try await PrototypeAI.syncChanged(root: root, folder: folder, manifest: before, baseline: baseline, units: plan.units,
                                                               language: promptLanguage, record: record, stage: stageReporter(milestones: false))
                manifest.components = synced.components
                for gap in synced.gaps where !manifest.gaps.contains(gap) { manifest.gaps.append(gap) }
                if synced.restyled { await refreshThemes(planned: synced.themes, defaultID: synced.defaultTheme, persist: false) }
                let rebuilt = synced.screens.isEmpty ? "no screen" : synced.screens.joined(separator: ", ")
                try accept(instruction: "Synced changed code", summary: "Updated from the changed code; screens written again: \(rebuilt).")
                await writeAdvancedBaseline(baseline, rewritten: Set(synced.rewritten),
                                            refreshed: Set(synced.rewritten).union(synced.restyled ? ["shell"] : []))
                messages.append(Message(role: .assistant, text: incrementalReply(synced, plan: plan, previous: before.version)))
                await settleFixAndCompare(language: promptLanguage, only: Set(synced.rewritten))
            } catch is CancellationError {
                keepPrevious(before, note: "Stopped. The prototype is unchanged (v\(before.version)).")
            } catch {
                keepPrevious(before, note: "Sync from code failed; the prototype is unchanged (v\(before.version)). \(error.localizedDescription)")
            }
        }
    }

    private func incrementalReply(_ synced: PrototypeAI.Synced, plan: PrototypeBaseline.SyncPlan, previous: Int) -> String {
        var text = "Synced the changed code as v\(manifest.version) (from v\(previous)). "
        text += synced.screens.isEmpty ? "No screen was written again" : "Screens written again: \(synced.screens.joined(separator: ", "))"
        let pages = synced.rewritten.count - synced.screens.count
        if pages > 0 { text += "; \(pages) component page\(pages == 1 ? "" : "s") written again" }
        text += synced.restyled ? ". The original stylesheets were copied again." : "."
        text += " Changed source files: \(PrototypeBaseline.list(plan.changedSources, limit: 8))."
        let replaced = plan.overwrites.filter { synced.rewritten.contains($0.unit.id) }.map(\.unit.name)
        if !replaced.isEmpty {
            text += "\n\nStudio edits to these were replaced, because the code changed too: \(replaced.joined(separator: ", ")). v\(previous) still has them; the version menu goes back."
        }
        if !synced.failed.isEmpty {
            text += "\n\nCould not be rebuilt (they keep their earlier files and still show as changed): "
                + synced.failed.map { "\($0.name) (\($0.reason))" }.joined(separator: "; ") + "."
        }
        for note in plan.notes { text += "\n\n" + note }
        text += "\n\nThe plan, the shell, the sample data and the coverage line in the gaps are from the last full build; Rebuild everything refreshes them."
        return text
    }

    /// The baseline of the version an incremental sync just made (REQ-009): rewritten units get new prototype fingerprints, a source file moves
    /// only when every unit that lists it is current, the rest stays as it was.
    private func writeAdvancedBaseline(_ previous: PrototypeBaseline.Record, rewritten: Set<String>, refreshed: Set<String>) async {
        let root = self.root, site = siteFolder, folder = self.folder, version = manifest.version, sources = manifest.sources
        let record = await Task.detached { () -> PrototypeBaseline.Record in
            let inventory = PrototypeFiles.inventory(root: root, sources: sources)
            let paths = Array(Set(previous.scope.keys).union(inventory.entries.map(\.path)))
            return PrototypeBaseline.advanced(previous, version: version, rewritten: rewritten, refreshed: refreshed,
                                              scope: PrototypeBaseline.fingerprints(root: root, paths: paths),
                                              site: PrototypeBaseline.siteFingerprints(site: site))
        }.value
        try? PrototypeBaseline.save(record, folder: folder, version: version)
        await refreshSyncStatus()
    }

    /// Reconstructs a code-mode prototype again from the current sources and saves the result as a new version
    /// (REQ-006, DEC-005), reading and planning the whole project: the separate, confirmed "Rebuild everything"
    /// (REQ-010). The scope is found again from the project, as the creator sheet found it; the
    /// conversation stays and gets the summary; the earlier versions, with any edits, remain restorable. A
    /// failure or Stop restores the previous version and changes nothing.
    func rebuildEverything() {
        guard !isBusy, canSyncFromCode else { return }
        syncPreview = nil
        beginRun("Reading the code")
        let before = manifest
        show(page: nil)
        task = Task { [self] in
            defer { endRun() }
            do {
                let root = self.root, sources = manifest.sources
                codeScope = await Task.detached { PrototypeAI.CodeScope.detect(root: root, sources: sources) }.value
                let built = try await PrototypeAI.sync(root: root, folder: folder, manifest: before, codeScope: codeScope,
                                                       language: promptLanguage, record: record, stage: stageReporter(milestones: false))
                adopt(built)
                await refreshThemes(planned: built.themes, defaultID: built.defaultTheme, persist: false)
                let screens = built.screens.isEmpty ? "no screen could be written" : "screens: \(built.screens.joined(separator: ", "))"
                try accept(instruction: "Synced from code", summary: "Reconstructed again from the current code; \(screens).")
                await writeBaseline(built)
                messages.append(Message(role: .assistant, text: reply(for: built, opening: "Synced from the current code as v\(manifest.version).")))
                await settleFixAndCompare(language: promptLanguage)
            } catch is CancellationError {
                keepPrevious(before, note: "Stopped. The prototype is unchanged (v\(before.version)).")
            } catch {
                keepPrevious(before, note: "Sync from code failed; the prototype is unchanged (v\(before.version)). \(error.localizedDescription)")
            }
        }
    }

    /// A sync that did not end as a saved version leaves the previous one live: the build restores its files
    /// when it fails itself, but `accept` can fail after a successful build, with the new files in `site/` and
    /// no copy of them, so the files are restored here as well and the manifest is what it was.
    private func keepPrevious(_ before: PrototypeFiles.Manifest, note: String) {
        try? PrototypeFiles.restore(folder: folder, version: before.version)
        manifest = before
        reload()
        messages.append(Message(role: .error, text: note))
    }

    /// One reviewer request, with the element pointed at in the preview and the images sent with it. The screenshot of
    /// the element goes along only when `withScreenshot` is on.
    func send(_ text: String, withScreenshot: Bool = false) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let shot = pick != nil && withScreenshot ? pickShot : nil
        guard !isBusy, hasSite, !typed.isEmpty || !attachments.isEmpty else { return }
        let instruction = typed.isEmpty ? "Look at the attached image(s) and make the prototype match." : typed
        let pick = self.pick, target = self.target
        var files: [(url: URL, note: String)] = []
        var thumbnails: [NSImage] = []
        do {
            for (index, attachment) in attachments.items.enumerated() {
                files.append((try PrototypeImages.save(attachment.data, in: folder), "image \(index + 1) from the reviewer"))
                thumbnails.append(attachment.image)
            }
            if let shot, let pick {
                files.append((try PrototypeImages.save(shot, in: folder), "screenshot of the element the reviewer pointed at (\(pick.selector))"))
                if let image = NSImage(data: shot) { thumbnails.append(image) }
            }
        } catch {
            messages.append(Message(role: .error, text: "Could not save the images: \(error.localizedDescription)"))
            return
        }
        let aimed = pick.map { "[\($0.selector)] " } ?? target.map { "[\($0.kind): \($0.name)] " } ?? ""
        messages.append(Message(role: .user, text: aimed + instruction, images: thumbnails,
                                imageNames: files.map { $0.url.lastPathComponent }))
        self.pick = nil
        self.target = nil
        attachments.removeAll()
        pickMode = false
        run(Request(instruction: instruction, pick: pick, files: files, target: target))
    }

    /// Clears the review conversation and the images sent with it. The prototype, its versions and the review history in the
    /// manifest stay, so the specification and the handoff lose nothing; each request is sent without the conversation anyway.
    func clearConversation() {
        guard !isBusy else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("attachments", isDirectory: true))
        restoredDraft = nil
        let version = manifest.version
        messages = [Message(role: .assistant, text: version > 0
            ? "Conversation cleared. The prototype is at v\(version); every version is still under Versions."
            : "Conversation cleared.")]
    }

    /// Runs the request of a failed message again, without adding the question to the conversation twice.
    func retry(_ request: Request) {
        guard !isBusy else { return }
        run(request)
    }

    /// Puts the text of a failed request back into the input field.
    func edit(_ request: Request) {
        restoredDraft = request.instruction
        // The edited request is aimed at what the failed one was aimed at (REQ-008).
        if let pick = request.pick { self.pick = pick } else { target = request.target }
    }

    private func run(_ request: Request) {
        let instruction = request.instruction, pick = request.pick, files = request.files, target = request.target
        beginRun("Working on your request")
        task = Task { [self] in
            defer { endRun() }
            do {
                let outcome = try await PrototypeAI.revise(root: root, folder: folder, instruction: instruction, pick: pick,
                                                           attachments: files, runtimeErrors: runtimeErrors, language: promptLanguage,
                                                           mode: manifest.mode, sources: manifest.sources, target: target,
                                                           record: record, stage: stageReporter())
                // An answer that changed nothing is shown as it is: no new version, no preview round (BUG-051).
                guard !outcome.written.isEmpty else {
                    messages.append(Message(role: .assistant, text: outcome.summary))
                    return
                }
                if !outcome.screens.isEmpty { manifest.screens = outcome.screens }
                try accept(instruction: instruction, summary: outcome.summary)
                messages.append(Message(role: .assistant, text: outcome.summary))
                // Only a change that can break a screen is worth opening every screen again.
                let touchesScreens = outcome.written.contains { $0.hasPrefix("screens/") || $0 == "app.js" || $0 == "index.html" }
                await settleAndFix(language: promptLanguage, audit: touchesScreens)
            } catch is CancellationError {
                messages.append(Message(role: .error, text: "Stopped. The prototype is unchanged.", retry: request))
            } catch {
                messages.append(Message(role: .error, text: error.localizedDescription, retry: request))
            }
        }
    }

    /// Makes `version` the live prototype again, as a new version so the history stays complete. The preview
    /// shows the screens again, and in code mode the component links are scanned from the restored files, so
    /// the manifest matches what is on disk (REQ-007).
    func revert(to version: Int) {
        guard !isBusy else { return }
        do {
            try PrototypeFiles.restore(folder: folder, version: version)
            show(page: nil)
            if manifest.mode == .code {
                manifest.components = PrototypeFiles.rescanComponents(in: siteFolder, known: manifest.components)
                if let selected = selectedComponent, component(at: selected) == nil { selectedComponent = nil }
            }
            try accept(instruction: "Go back to v\(version)", summary: "Restored the prototype of v\(version).", baselineFrom: version)
            messages.append(Message(role: .assistant, text: "Went back to v\(version) (saved as v\(manifest.version))."))
        } catch {
            messages.append(Message(role: .error, text: error.localizedDescription))
        }
    }

    /// Approves the current version: writes the specification and packs prototype, spec and history into a zip.
    func approveAndExport() {
        guard !isBusy, hasSite else { return }
        beginRun("Writing the specification")
        task = Task { [self] in
            defer { endRun() }
            do {
                let spec = try await PrototypeAI.specification(root: root, folder: folder, manifest: manifest,
                                                               language: languageNote, record: record, stage: stageReporter())
                stage = "Packing the archive"; log("Packing the archive")
                let folder = self.folder, manifest = self.manifest
                let root = self.root
                let zip = try await Task.detached(priority: .userInitiated) {
                    try PrototypeAI.packageArchive(root: root, folder: folder, manifest: manifest, spec: spec)
                }.value
                try spec.write(to: folder.appendingPathComponent("SPEC.md"), atomically: true, encoding: .utf8)
                self.manifest.approved = true
                try PrototypeFiles.saveManifest(self.manifest, in: folder)
                archive = zip
                messages.append(Message(role: .assistant, text: "Approved v\(manifest.version). The package is ready: \(zip.lastPathComponent)"))
            } catch is CancellationError {
                messages.append(Message(role: .error, text: "Stopped."))
            } catch {
                messages.append(Message(role: .error, text: error.localizedDescription))
            }
        }
    }

    func cancel() { task?.cancel() }

    /// A prototype from code made before MarkView owned the page structure (BUG-060) has a page as tall as its content, so a widget that
    /// fills its box shows only its toolbar; one made from a Tailwind app before MarkView carried Tailwind (BUG-063) has utility classes
    /// without a rule, so it opens as raw HTML. Opening it adds what is missing and saves that as a version of its own. No assistant
    /// run, and nothing at all for a prototype that has them.
    func ensurePageStructure() async {
        guard manifest.mode == .code, manifest.version > 0, !isBusy, hasSite else { return }
        let site = siteFolder
        let (structure, tailwind) = await Task.detached {
            (PrototypeShellStructure.needsApplying(site: site), PrototypeTailwind.needsApplying(site: site))
        }.value
        guard (structure || tailwind), !isBusy else { return }
        var summary: [String] = [], found: [String] = []
        if structure {
            summary.append("MarkView linked the page structure (markview/structure.css): the page and #app have a definite height, so widgets that fill their box show their content.")
            found.append("The page had no fixed height, so a widget that fills its box showed only its toolbar.")
        }
        if tailwind {
            summary.append("MarkView added Tailwind (markview/tailwind.js): the source stylesheet is Tailwind v4, so the utility classes of the screens had no rules and the prototype showed raw HTML.")
            found.append("The prototype is made from a Tailwind app and its utility classes had no styles, so it showed plain HTML.")
        }
        do {
            try accept(instruction: "", summary: summary.joined(separator: " "))
            messages.append(Message(role: .assistant, text: "This prototype lacked what MarkView adds itself. " + found.joined(separator: " ")
                + " MarkView fixed it as v\(manifest.version); no assistant run. Every earlier version is still under Versions."))
        } catch {
            messages.append(Message(role: .error, text: error.localizedDescription))
        }
    }

    /// Called by the preview for each JavaScript error the page raises.
    func report(error text: String) {
        guard runtimeErrors.count < 5, !runtimeErrors.contains(text) else { return }
        runtimeErrors.append(text)
    }

    // MARK: - Private

    /// Records a new accepted version: history, snapshot, manifest, preview reload.
    private func accept(instruction: String, summary: String, baselineFrom: Int? = nil) throws {
        manifest.version += 1
        // The page structure is MarkView's: a version restored from before it, or a revision that dropped the link, gets it back (BUG-060).
        if manifest.mode == .code { try PrototypeShellStructure.ensure(site: siteFolder) }
        // So is Tailwind, for a site whose stylesheet imports it: the utility classes of the source need it to have any rule (BUG-063).
        if manifest.mode == .code { try PrototypeTailwind.ensure(site: siteFolder) }
        // A review edit leaves the sources as they were at the sync: the new version has the baseline of the one before it (REQ-009).
        if manifest.mode == .code { PrototypeBaseline.carryForward(folder: folder, from: baselineFrom ?? manifest.version - 1, to: manifest.version) }
        manifest.approved = false
        manifest.history.append(PrototypeFiles.Entry(version: manifest.version, instruction: instruction,
                                                     summary: summary, date: Date()))
        try PrototypeFiles.snapshot(folder: folder, version: manifest.version)
        try PrototypeFiles.saveManifest(manifest, in: folder)
        archive = nil
        if manifest.mode == .code { Task { await refreshSyncStatus() } }
        // An isolated page this version removed cannot stay on screen: the screens come back.
        if let page = shownPage, !FileManager.default.fileExists(atPath: siteFolder.appendingPathComponent(page).path) {
            shownPage = nil
        }
        reload()
    }

    private func reload() {
        runtimeErrors = []
        unresolvedProblems = []
        reloadToken += 1
    }

    /// A screen landed: show it, keeping the errors of the page for the fix round at the end.
    private func reloadPreview() { reloadToken += 1 }

    /// Lets the reloaded page run, opens every screen in the preview, and when the page reported JavaScript errors or a
    /// screen is blank, stuck or a placeholder, has the assistant fix them once. What is still wrong afterwards is named in the
    /// chat and in `unresolvedProblems`, whatever the way the round ended (BUG-062).
    ///
    /// The problems name the files they come from. Up to `PrototypeAudit.directFixLimit` files go to one run; more are not asked of
    /// one answer (the assistant would decline, and nothing would be fixed): each file gets a run of its own, side by side, and each
    /// run sees the whole list.
    private func settleAndFix(language: String, audit shouldAudit: Bool = true) async {
        for _ in 0..<Self.autoFixRounds {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            let found = shouldAudit ? await auditedProblems() : []
            guard !Task.isCancelled else { return }
            let lint = shouldAudit ? await loaderProblems(besides: found) : []
            let errors = Array((runtimeErrors + found + lint).prefix(Self.fixLimit))
            guard !errors.isEmpty else { unresolvedProblems = []; return }
            stage = "Fixing errors found in the preview"; log("Fixing errors found in the preview")
            messages.append(Message(role: .assistant, text: "The preview reported \(errors.count) problem\(errors.count == 1 ? "" : "s"); fixing:\n" + errors.map { "• \($0)" }.joined(separator: "\n")))
            do {
                let instruction = found.isEmpty && errors.count == runtimeErrors.count
                    ? "Fix the JavaScript errors reported by the preview. Change nothing else."
                    : "Fix the errors and the blank or unfinished screens reported by the preview. Change nothing else."
                let named = await fixFiles(for: errors)
                let split = named.count > PrototypeAudit.directFixLimit
                if split { log("The problems are in \(named.count) files: one run for each") }
                let outcome = try await PrototypeAI.revise(root: root, folder: folder, instruction: instruction,
                                                           pick: nil, runtimeErrors: errors, language: language,
                                                           mode: manifest.mode, sources: manifest.sources, sweep: true,
                                                           sweepFiles: split ? named : [], sweepEffort: "medium",
                                                           record: record, stage: stageReporter())
                guard !outcome.written.isEmpty else {
                    messages.append(Message(role: .assistant, text: outcome.summary))
                    unresolvedProblems = errors
                    return
                }
                try accept(instruction: "Fix preview errors", summary: outcome.summary)
                messages.append(Message(role: .assistant, text: outcome.summary))
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                let left = shouldAudit ? await auditedProblems() : []
                let leftLint = shouldAudit ? await loaderProblems(besides: left) : []
                unresolvedProblems = Array((runtimeErrors + left + leftLint).prefix(Self.fixLimit))
                if !unresolvedProblems.isEmpty {
                    messages.append(Message(role: .assistant, text: "Still not right after the fix:\n" + unresolvedProblems.map { "• \($0)" }.joined(separator: "\n")
                        + "\nUse Fix again in the header, or ask me to rebuild these screens."))
                }
            } catch {
                messages.append(Message(role: .error, text: error.localizedDescription))
                unresolvedProblems = errors
                return
            }
        }
    }

    /// Runs the fix round again on the reviewer's request, for the problems the header lists.
    func fixProblems() {
        guard !isBusy, hasSite else { return }
        beginRun("Fixing errors found in the preview")
        task = Task { [self] in
            defer { endRun() }
            await settleAndFix(language: promptLanguage)
        }
    }

    /// The editable files of the prototype that `problems` point to, read off the main actor.
    private func fixFiles(for problems: [String]) async -> [String] {
        let site = siteFolder
        return await Task.detached {
            PrototypeAudit.fixFiles(problems: problems, existing: Set(PrototypeFiles.read(site: site).map(\.path)))
        }.value
    }

    /// Screens whose script clears the element its loader sits in (`PrototypeAudit.loadProblem`), found by reading the files, not by the
    /// preview; the screens `reported` already names are left out. Covers a prototype built before the check existed.
    private func loaderProblems(besides reported: [String]) async -> [String] {
        let site = siteFolder
        let ids = await Task.detached { () -> [(id: String, problem: String)] in
            PrototypeFiles.read(site: site).compactMap { file in
                guard file.path.hasPrefix("screens/"), file.path.hasSuffix(".js") else { return nil }
                let id = String(file.path.dropFirst("screens/".count).dropLast(".js".count))
                return PrototypeAudit.loadProblem(id: id, content: file.content).map { (id, $0) }
            }
        }.value
        return ids.filter { entry in !reported.contains { $0.contains("screens/\(entry.id).js") } }.map(\.problem)
    }

    /// What follows every build and sync of a prototype from code: the preview fix round, the comparison with the source, and, when that
    /// repaired a screen, the preview fix round again, because a repair can break a screen. `only` limits the comparison to the screens a
    /// sync wrote again.
    private func settleFixAndCompare(language: String, only: Set<String>? = nil) async {
        await settleAndFix(language: language)
        guard await fixThinScreens(language: language, only: only) else { return }
        await settleAndFix(language: language)
    }

    /// BUG-059: a screen written from a large widget can show a small part of it. Compares the labels of each screen's source files with the
    /// screen's script (`PrototypeFidelity`, no assistant run) and gives the thinnest screens one repair pass each, with the list of what is
    /// absent. A screen is repaired at most once per run, whatever the second comparison says: the rest is named, and the reviewer can ask for
    /// a rebuild. True when a repair changed the prototype.
    private func fixThinScreens(language: String, only: Set<String>?) async -> Bool {
        guard manifest.mode == .code, !Task.isCancelled else { return false }
        stage = "Comparing the screens with their source"; log("Comparing the screens with their source")
        let reports = await sourceReports(only: only)
        let thin = reports.filter { $0.isThin && !failedScreens.contains($0.id) && !failedScreens.contains($0.name) }
            .sorted { $0.coverage < $1.coverage }
        log("Compared \(reports.count) screen\(reports.count == 1 ? "" : "s") with their source; \(thin.count) show much less than the source defines")
        guard !thin.isEmpty else { return false }
        let repaired = Array(thin.prefix(PrototypeFidelity.maxRepairs))
        var text = "Source check: \(thin.count) screen\(thin.count == 1 ? " shows" : "s show") much less than the source files define:\n" +
            thin.map { "• " + PrototypeFidelity.summary($0) }.joined(separator: "\n")
        text += thin.count > repaired.count
            ? "\nThe \(repaired.count) thinnest are repaired now; ask me to rebuild the others."
            : "\nAdding what is missing."
        messages.append(Message(role: .assistant, text: text))
        var changed = false
        for report in repaired {
            guard !Task.isCancelled else { return changed }
            stage = "Adding what \"\(report.name)\" is missing"; log("Adding what \"\(report.name)\" is missing")
            do {
                let outcome = try await PrototypeAI.revise(root: root, folder: folder, instruction: PrototypeFidelity.repairInstruction(report),
                                                           pick: nil, runtimeErrors: [], language: language, mode: manifest.mode,
                                                           sources: manifest.sources, sweep: false,
                                                           target: .screen(id: report.id, name: report.name),
                                                           record: record, stage: stageReporter())
                guard !outcome.written.isEmpty else {
                    messages.append(Message(role: .assistant, text: "\"\(report.name)\": " + outcome.summary))
                    continue
                }
                try accept(instruction: "Source check: \(report.name)", summary: outcome.summary)
                changed = true
                messages.append(Message(role: .assistant, text: outcome.summary))
                if let after = await sourceReports(only: [report.id]).first {
                    messages.append(Message(role: .assistant, text: after.isThin
                        ? "Still thin: " + PrototypeFidelity.summary(after) + ". Ask me to rebuild this screen."
                        : "Now " + PrototypeFidelity.summary(after) + "."))
                }
            } catch is CancellationError {
                return changed
            } catch {
                messages.append(Message(role: .error, text: error.localizedDescription))
                return changed
            }
        }
        return changed
    }

    /// The comparison of every screen (or of `only`) of the live version with its source files. The files are read off the main actor, and
    /// a source file is read only when it is a regular file under the project root and not larger than `maxSourceFile`.
    private func sourceReports(only: Set<String>?) async -> [PrototypeFidelity.Report] {
        let root = self.root, folder = self.folder, site = siteFolder, version = manifest.version, sizeLimit = Self.maxSourceFile
        return await Task.detached { () -> [PrototypeFidelity.Report] in
            guard let record = PrototypeBaseline.load(folder: folder, version: version) else { return [] }
            let screens = record.units.filter { $0.kind == .screen && !$0.sources.isEmpty }
            func read(_ path: String) -> String? {
                guard PrototypeFiles.isSourceFile(root: root, path: path) else { return nil }
                let url = root.appendingPathComponent(path)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                guard let size = attributes?[.size] as? Int, size <= sizeLimit else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            }
            return screens.filter { only?.contains($0.id) ?? true }.compactMap { unit in
                let others = Set(screens.filter { $0.id != unit.id }.flatMap(\.sources))
                let script = (try? String(contentsOf: site.appendingPathComponent(PrototypeBaseline.screenFile(unit.id)), encoding: .utf8)) ?? ""
                return PrototypeFidelity.report(id: unit.id, name: unit.name, evidence: unit.sources, otherEvidence: others,
                                                screen: script, read: read)
            }
        }.value
    }
    private static let maxSourceFile = 300_000

    /// At most this many problems go to one fix round.
    private static let fixLimit = 12
    /// The preview must start the audit within this time, or there is no preview to ask.
    private static let auditAcknowledgeLimit: TimeInterval = 8
    private static let auditLimit: TimeInterval = 240

    /// Opens every screen in the preview and describes the ones that are blank, stuck or placeholders, except the
    /// screens the build already reported as failed. Empty when no preview took the request.
    private func auditedProblems() async -> [String] {
        stage = "Checking every screen in the preview"; log("Checking every screen in the preview")
        guard let report = await audit() else {
            log("The preview did not check the screens")
            return []
        }
        let found = report.findings.filter { !failedScreens.contains($0.name) }
        log("Checked \(report.checked) screen\(report.checked == 1 ? "" : "s"); \(found.count) with a problem")
        return found.map(PrototypeAudit.message(for:))
    }

    /// Asks the preview to run the audit and waits for its report; nil when nobody answered.
    private func audit() async -> PrototypeAudit.Report? {
        auditReport = nil
        auditAcknowledged = false
        auditActive = true
        auditToken += 1
        let started = Date()
        while auditActive, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let waited = Date().timeIntervalSince(started)
            if (!auditAcknowledged && waited > Self.auditAcknowledgeLimit) || waited > Self.auditLimit { break }
        }
        auditActive = false
        return auditReport
    }

    // MARK: - Sync baseline

    /// Saves the baseline of the version a build or a sync just made: the fingerprints of the scope's source files, the source files and
    /// prototype files of every unit, and the plan (REQ-009). Hashing reads files, so it runs off the main actor.
    private func writeBaseline(_ built: PrototypeAI.Built) async {
        guard let input = built.baseline else { return }
        let root = self.root, site = siteFolder, folder = self.folder, version = manifest.version, components = manifest.components
        let record = await Task.detached { () -> PrototypeBaseline.Record in
            let named = input.scope + input.styles + input.screens.flatMap(\.sources) + components.map(\.path)
            return PrototypeBaseline.make(version: version, plan: input.plan, styles: input.styles, screens: input.screens,
                                          components: components, scope: PrototypeBaseline.fingerprints(root: root, paths: named),
                                          site: PrototypeBaseline.siteFingerprints(site: site),
                                          sourceExists: { PrototypeFiles.isSourceFile(root: root, path: $0) })
        }.value
        try? PrototypeBaseline.save(record, folder: folder, version: version)
        await refreshSyncStatus()
    }

    /// Compares the code and the prototype as they are now with the baseline of the live version: no assistant run, no network (REQ-014).
    /// Safe to call at any time.
    func refreshSyncStatus() async {
        guard manifest.mode == .code, manifest.version > 0 else { return }
        syncCheckGeneration += 1
        let generation = syncCheckGeneration
        checkingSync = true
        let root = self.root, site = siteFolder, folder = self.folder, version = manifest.version, sources = manifest.sources
        let status = await Task.detached { () -> PrototypeBaseline.Status in
            guard let record = PrototypeBaseline.load(folder: folder, version: version) else {
                return PrototypeBaseline.status(record: nil, scope: [:], site: [:])
            }
            let inventory = PrototypeFiles.inventory(root: root, sources: sources)
            let paths = Array(Set(record.scope.keys).union(inventory.entries.map(\.path)))
            return PrototypeBaseline.status(record: record, scope: PrototypeBaseline.fingerprints(root: root, paths: paths),
                                            site: PrototypeBaseline.siteFingerprints(site: site))
        }.value
        // The latest check wins: an older one that finishes late must not replace a newer answer.
        guard generation == syncCheckGeneration else { return }
        syncStatus = status
        checkingSync = false
    }
    private var syncCheckGeneration = 0

    // MARK: - Themes

    /// Finds the themes of the original in the copied stylesheets and records them in the manifest (REQ-001). `planned` are the ids
    /// the planner read from the source (nil keeps the earlier ones), `defaultID` the theme the application starts with. The scan
    /// reads files, so it runs off the main actor; `persist` is false when the caller saves the manifest itself.
    func refreshThemes(planned: [String]? = nil, defaultID: String? = nil, persist: Bool = true) async {
        guard manifest.mode == .code else { return }
        let site = siteFolder
        let found = await Task.detached { PrototypeThemes.scan(site: site) }.value
        let updated = PrototypeThemes.record(found: found, planned: planned ?? manifest.themes?.ids ?? [],
                                             defaultID: defaultID, previous: manifest.themes)
        guard updated != manifest.themes else { return }
        manifest.themes = updated
        if persist { try? PrototypeFiles.saveManifest(manifest, in: folder) }
    }

    /// The reviewer's theme for the preview: an id, nil for the default, "" for the original look without an attribute (REQ-002).
    func chooseTheme(_ id: String?) {
        guard var record = manifest.themes, record.chosen != id else { return }
        record.chosen = id
        manifest.themes = record
        try? PrototypeFiles.saveManifest(manifest, in: folder)
    }

    /// The preview began the audit.
    func auditStarted() { auditAcknowledged = true }

    /// The preview's answer: the report, or nil when the page could not be audited.
    func finishAudit(_ report: PrototypeAudit.Report?) {
        auditReport = report
        auditActive = false
    }
}

extension PrototypeAI.CodeScope {
    /// The reconstruction scope of `sources` under `root`, from the project's web-app discovery: the one call
    /// the creator sheet and "Sync from code" share, so a sync sees the hints creation saw (REQ-006). Reads
    /// the file system; the caller keeps it off the main thread.
    static func detect(root: URL, sources: [String]) -> PrototypeAI.CodeScope {
        let found = WebAppPreview.targets(root: root).map { ($0.folder, $0.label, $0.isElectron) as Detected }
        return PrototypeAI.CodeScope(root: root, sources: sources, detected: found)
    }
}
