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
    }

    let id = UUID()
    let root: URL
    let folder: URL
    /// The prototype's folder name; the tab bar reads it off the main actor.
    nonisolated let slug: String
    @Published private(set) var manifest: PrototypeFiles.Manifest
    @Published private(set) var messages: [Message] = []
    /// What the running assistant is doing; nil when idle.
    @Published private(set) var stage: String?
    @Published private(set) var reloadToken = 0
    @Published private(set) var runtimeErrors: [String] = []
    @Published private(set) var archive: URL?
    @Published var pick: PrototypeAI.Pick?
    @Published var pickMode = false

    /// Adds a finished run to the workspace's usage counter.
    var record: @MainActor (CLICompletion.Result) -> Void = { _ in }
    /// Appended to prompts when the output language differs from the documents' language.
    var languageNote = ""

    private var task: Task<Void, Never>?
    /// Runs of the assistant that fix reported errors by themselves, per request.
    private static let autoFixRounds = 1

    var isBusy: Bool { stage != nil }
    var siteIndex: URL { PrototypeFiles.site(of: folder).appendingPathComponent("index.html") }
    var siteFolder: URL { PrototypeFiles.site(of: folder) }
    var hasSite: Bool { FileManager.default.fileExists(atPath: siteIndex.path) }

    /// A prototype that does not exist yet; `generate()` builds it.
    init(root: URL, title: String, brief: String, sources: [String]) {
        self.root = root.standardizedFileURL
        let slug = PrototypeFiles.slug(for: title, existing: Set(PrototypeFiles.existingSlugs(root: root)))
        self.slug = slug
        folder = PrototypeFiles.folder(root: self.root, slug: slug)
        manifest = PrototypeFiles.Manifest(title: title, slug: slug, brief: brief, sources: sources)
        messages = [Message(role: .user, text: brief.isEmpty ? "Build a prototype of \(sources.isEmpty ? "the project" : sources.joined(separator: ", "))." : brief)]
    }

    /// A prototype saved earlier; nil when its manifest is missing.
    init?(root: URL, slug: String) {
        let folder = PrototypeFiles.folder(root: root.standardizedFileURL, slug: slug)
        guard let manifest = PrototypeFiles.loadManifest(folder) else { return nil }
        self.root = root.standardizedFileURL
        self.folder = folder
        self.slug = slug
        self.manifest = manifest
        for entry in manifest.history {
            if !entry.instruction.isEmpty { messages.append(Message(role: .user, text: entry.instruction)) }
            messages.append(Message(role: .assistant, text: "v\(entry.version): \(entry.summary)"))
        }
    }

    // MARK: - Runs

    private var stageReporter: PrototypeAI.Stage {
        { [weak self] text in Task { @MainActor in if self?.stage != nil { self?.stage = text } } }
    }

    /// Builds the first version from the sources and the brief.
    func generate() {
        guard !isBusy else { return }
        stage = "Starting"
        task = Task { [self] in
            defer { stage = nil; task = nil }
            do {
                try FileManager.default.createDirectory(at: PrototypeFiles.site(of: folder), withIntermediateDirectories: true)
                let built = try await PrototypeAI.generate(root: root, folder: folder, brief: manifest.brief, sources: manifest.sources,
                                                           language: languageNote, record: record, stage: stageReporter)
                if !built.title.isEmpty { manifest.title = built.title }
                manifest.screens = built.outcome.screens
                manifest.assumptions = built.outcome.assumptions
                try accept(instruction: "", summary: built.outcome.summary)
                var reply = built.outcome.summary
                if !built.outcome.assumptions.isEmpty {
                    reply += "\n\nAssumptions I made:\n" + built.outcome.assumptions.map { "• \($0)" }.joined(separator: "\n")
                }
                messages.append(Message(role: .assistant, text: reply))
                await settleAndFix(language: languageNote)
            } catch is CancellationError {
                messages.append(Message(role: .error, text: "Stopped."))
            } catch {
                messages.append(Message(role: .error, text: error.localizedDescription))
            }
        }
    }

    /// One reviewer request, with the element pointed at in the preview if there is one.
    func send(_ text: String) {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !isBusy, hasSite else { return }
        let pick = self.pick
        messages.append(Message(role: .user, text: (pick.map { "[\($0.selector)] " } ?? "") + instruction))
        self.pick = nil
        pickMode = false
        stage = "Starting"
        task = Task { [self] in
            defer { stage = nil; task = nil }
            do {
                let outcome = try await PrototypeAI.revise(root: root, folder: folder, instruction: instruction, pick: pick,
                                                           runtimeErrors: runtimeErrors, language: languageNote,
                                                           record: record, stage: stageReporter)
                if !outcome.screens.isEmpty { manifest.screens = outcome.screens }
                try accept(instruction: instruction, summary: outcome.summary)
                messages.append(Message(role: .assistant, text: outcome.summary))
                await settleAndFix(language: languageNote)
            } catch is CancellationError {
                messages.append(Message(role: .error, text: "Stopped. The prototype is unchanged."))
            } catch {
                messages.append(Message(role: .error, text: error.localizedDescription))
            }
        }
    }

    /// Makes `version` the live prototype again, as a new version so the history stays complete.
    func revert(to version: Int) {
        guard !isBusy else { return }
        do {
            try PrototypeFiles.restore(folder: folder, version: version)
            try accept(instruction: "Go back to v\(version)", summary: "Restored the prototype of v\(version).")
            messages.append(Message(role: .assistant, text: "Went back to v\(version) (saved as v\(manifest.version))."))
        } catch {
            messages.append(Message(role: .error, text: error.localizedDescription))
        }
    }

    /// Approves the current version: writes the specification and packs prototype, spec and history into a zip.
    func approveAndExport() {
        guard !isBusy, hasSite else { return }
        stage = "Writing the specification"
        task = Task { [self] in
            defer { stage = nil; task = nil }
            do {
                let spec = try await PrototypeAI.specification(root: root, folder: folder, manifest: manifest,
                                                               language: languageNote, record: record, stage: stageReporter)
                stage = "Packing the archive"
                let folder = self.folder, manifest = self.manifest
                let zip = try await Task.detached(priority: .userInitiated) {
                    try PrototypeAI.packageArchive(folder: folder, manifest: manifest, spec: spec)
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
        reload()
    }

    private func reload() {
        runtimeErrors = []
        reloadToken += 1
    }

    /// Lets the reloaded page run, and when it reported JavaScript errors, has the assistant fix them.
    private func settleAndFix(language: String) async {
        for _ in 0..<Self.autoFixRounds {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, !runtimeErrors.isEmpty else { return }
            let errors = runtimeErrors
            stage = "Fixing errors found in the preview"
            messages.append(Message(role: .assistant, text: "The preview reported \(errors.count) error\(errors.count == 1 ? "" : "s"); fixing:\n" + errors.map { "• \($0)" }.joined(separator: "\n")))
            do {
                let outcome = try await PrototypeAI.revise(root: root, folder: folder,
                                                           instruction: "Fix the JavaScript errors reported by the preview. Change nothing else.",
                                                           pick: nil, runtimeErrors: errors, language: language,
                                                           record: record, stage: stageReporter)
                try accept(instruction: "Fix preview errors", summary: outcome.summary)
                messages.append(Message(role: .assistant, text: outcome.summary))
            } catch {
                messages.append(Message(role: .error, text: error.localizedDescription))
                return
            }
        }
    }
}
