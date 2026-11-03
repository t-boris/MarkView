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
    }

    /// An image waiting to be sent with the next request.
    struct Attachment: Identifiable {
        let id = UUID()
        let data: Data
        let image: NSImage
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
    @Published private(set) var archive: URL?
    @Published var pick: PrototypeAI.Pick? {
        didSet {
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
    @Published private(set) var attachments: [Attachment] = []
    @Published var pickMode = false

    /// Adds a finished run to the workspace's usage counter.
    var record: PrototypeAI.Record = { _ in }
    /// Appended to prompts when the output language differs from the documents' language.
    var languageNote = ""
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
                                                        language: languageNote, mode: manifest.mode, codeScope: codeScope,
                                                        record: record, stage: stageReporter())
                adopt(built)
                if !built.screens.isEmpty {
                    try accept(instruction: "", summary: "All screens: \(built.screens.joined(separator: ", ")).")
                }
                messages.append(Message(role: .assistant, text: reply(for: built, opening: "The prototype is ready.")))
                await settleAndFix(language: languageNote)
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

    /// Reconstructs a code-mode prototype again from the current sources and saves the result as a new version
    /// (REQ-006, DEC-005). The scope is found again from the project, as the creator sheet found it; the
    /// conversation stays and gets the summary; the earlier versions, with any edits, remain restorable. A
    /// failure or Stop restores the previous version and changes nothing.
    func syncFromCode() {
        guard !isBusy, canSyncFromCode else { return }
        beginRun("Reading the code")
        let before = manifest
        show(page: nil)
        task = Task { [self] in
            defer { endRun() }
            do {
                let root = self.root, sources = manifest.sources
                codeScope = await Task.detached { PrototypeAI.CodeScope.detect(root: root, sources: sources) }.value
                let built = try await PrototypeAI.sync(root: root, folder: folder, manifest: before, codeScope: codeScope,
                                                       language: languageNote, record: record, stage: stageReporter(milestones: false))
                adopt(built)
                let screens = built.screens.isEmpty ? "no screen could be written" : "screens: \(built.screens.joined(separator: ", "))"
                try accept(instruction: "Synced from code", summary: "Reconstructed again from the current code; \(screens).")
                messages.append(Message(role: .assistant, text: reply(for: built, opening: "Synced from the current code as v\(manifest.version).")))
                await settleAndFix(language: languageNote)
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
        let pick = self.pick
        var files: [(url: URL, note: String)] = []
        var thumbnails: [NSImage] = []
        do {
            for (index, attachment) in attachments.enumerated() {
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
        messages.append(Message(role: .user, text: (pick.map { "[\($0.selector)] " } ?? "") + instruction, images: thumbnails,
                                imageNames: files.map { $0.url.lastPathComponent }))
        self.pick = nil
        attachments = []
        pickMode = false
        run(Request(instruction: instruction, pick: pick, files: files))
    }

    /// Runs the request of a failed message again, without adding the question to the conversation twice.
    func retry(_ request: Request) {
        guard !isBusy else { return }
        run(request)
    }

    /// Puts the text of a failed request back into the input field.
    func edit(_ request: Request) { restoredDraft = request.instruction }

    private func run(_ request: Request) {
        let instruction = request.instruction, pick = request.pick, files = request.files
        beginRun("Working on your request")
        task = Task { [self] in
            defer { endRun() }
            do {
                let outcome = try await PrototypeAI.revise(root: root, folder: folder, instruction: instruction, pick: pick,
                                                           attachments: files, runtimeErrors: runtimeErrors, language: languageNote,
                                                           mode: manifest.mode, sources: manifest.sources,
                                                           record: record, stage: stageReporter())
                // An answer that changed nothing is shown as it is: no new version, no preview round (BUG-051).
                guard !outcome.written.isEmpty else {
                    messages.append(Message(role: .assistant, text: outcome.summary))
                    return
                }
                if !outcome.screens.isEmpty { manifest.screens = outcome.screens }
                try accept(instruction: instruction, summary: outcome.summary)
                messages.append(Message(role: .assistant, text: outcome.summary))
                await settleAndFix(language: languageNote)
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
            try accept(instruction: "Go back to v\(version)", summary: "Restored the prototype of v\(version).")
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

    // MARK: - Images

    func attach(_ images: [Data]) {
        for data in images {
            if let image = NSImage(data: data) { attachments.append(Attachment(data: data, image: image)) }
        }
    }

    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }

    /// Takes the images on the pasteboard; false when there were none (a text paste then goes on as usual).
    @discardableResult
    func attachFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let images = PrototypeImages.images(on: pasteboard)
        attach(images)
        return !images.isEmpty
    }

    /// Called by the preview for each JavaScript error the page raises.
    func report(error text: String) {
        guard runtimeErrors.count < 5, !runtimeErrors.contains(text) else { return }
        runtimeErrors.append(text)
    }

    // MARK: - Private

    /// Records a new accepted version: history, snapshot, manifest, preview reload.
    private func accept(instruction: String, summary: String) throws {
        manifest.version += 1
        manifest.approved = false
        manifest.history.append(PrototypeFiles.Entry(version: manifest.version, instruction: instruction,
                                                     summary: summary, date: Date()))
        try PrototypeFiles.snapshot(folder: folder, version: manifest.version)
        try PrototypeFiles.saveManifest(manifest, in: folder)
        archive = nil
        // An isolated page this version removed cannot stay on screen: the screens come back.
        if let page = shownPage, !FileManager.default.fileExists(atPath: siteFolder.appendingPathComponent(page).path) {
            shownPage = nil
        }
        reload()
    }

    private func reload() {
        runtimeErrors = []
        reloadToken += 1
    }

    /// A screen landed: show it, keeping the errors of the page for the fix round at the end.
    private func reloadPreview() { reloadToken += 1 }

    /// Lets the reloaded page run, and when it reported JavaScript errors, has the assistant fix them.
    private func settleAndFix(language: String) async {
        for _ in 0..<Self.autoFixRounds {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, !runtimeErrors.isEmpty else { return }
            let errors = runtimeErrors
            stage = "Fixing errors found in the preview"; log("Fixing errors found in the preview")
            messages.append(Message(role: .assistant, text: "The preview reported \(errors.count) error\(errors.count == 1 ? "" : "s"); fixing:\n" + errors.map { "• \($0)" }.joined(separator: "\n")))
            do {
                let outcome = try await PrototypeAI.revise(root: root, folder: folder,
                                                           instruction: "Fix the JavaScript errors reported by the preview. Change nothing else.",
                                                           pick: nil, runtimeErrors: errors, language: language,
                                                           mode: manifest.mode, sources: manifest.sources, sweep: false,
                                                           record: record, stage: stageReporter())
                guard !outcome.written.isEmpty else {
                    messages.append(Message(role: .assistant, text: outcome.summary))
                    return
                }
                try accept(instruction: "Fix preview errors", summary: outcome.summary)
                messages.append(Message(role: .assistant, text: outcome.summary))
            } catch {
                messages.append(Message(role: .error, text: error.localizedDescription))
                return
            }
        }
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
